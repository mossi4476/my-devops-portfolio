#!/usr/bin/env bash
# =============================================================================
# healthcheck.sh - Unit 3: Health-check ứng dụng
#
#   1. SERVICE    : systemd unit hoặc Docker container (state, health, restart count)
#   2. PROCESS    : process có đang chạy không (pgrep) + PID / CPU / MEM / uptime
#   3. URL        : HTTP status code, nội dung trả về, response time
#   4. PORT       : TCP port có mở / kết nối được không
#   5. DB SESSION : tổng session / max_connections, theo state, long query,
#                   idle-in-transaction, session bị block
#   6. TABLESPACE : dung lượng tablespace, database, top table, % disk
#
# Exit code (chuẩn Nagios): 0 = OK, 1 = WARNING, 2 = CRITICAL
# Dòng cuối cùng luôn là: HC_RESULT=<OK|WARNING|CRITICAL> ok=N warn=N crit=N skip=N
#
# Usage:
#   healthcheck.sh [--only service,process,url,port,db,tablespace] [--no-color]
# =============================================================================
set -uo pipefail

# ----------------------------- Cấu hình (override bằng env) ------------------
SERVICES="${SERVICES:-}"            # "docker:hc-backend systemd:nginx nginx"  (không prefix = systemd)
PROCESSES="${PROCESSES:-}"          # phân cách bằng dấu phẩy: "python app.py,postgres -c"
URLS="${URLS:-}"                    # phân cách bằng space: "url|expected_code|expected_text"
PORTS="${PORTS:-}"                  # phân cách bằng space: "host:port host2:port2"
URL_TIMEOUT="${URL_TIMEOUT:-5}"
URL_SLOW_MS="${URL_SLOW_MS:-1000}"
PORT_TIMEOUT="${PORT_TIMEOUT:-3}"

DB_CHECK="${DB_CHECK:-yes}"         # dùng PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE chuẩn của psql
DB_SESSION_WARN_PCT="${DB_SESSION_WARN_PCT:-70}"
DB_SESSION_CRIT_PCT="${DB_SESSION_CRIT_PCT:-90}"
DB_LONG_QUERY_SEC="${DB_LONG_QUERY_SEC:-60}"
DB_IDLE_TX_SEC="${DB_IDLE_TX_SEC:-60}"
TS_SIZE_WARN_MB="${TS_SIZE_WARN_MB:-1024}"
TS_SIZE_CRIT_MB="${TS_SIZE_CRIT_MB:-2048}"
DISK_PATH="${DISK_PATH:-}"          # thư mục data của DB để đo % disk (vd /var/lib/postgresql/data)
DISK_WARN_PCT="${DISK_WARN_PCT:-80}"
DISK_CRIT_PCT="${DISK_CRIT_PCT:-90}"

export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-5}"
export PGAPPNAME="${PGAPPNAME:-healthcheck}"

ONLY="all"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)     ONLY="$2"; shift 2 ;;
    --no-color) NO_COLOR=1; shift ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Tham số không hợp lệ: $1" >&2; exit 2 ;;
  esac
done

# ----------------------------- Output helpers --------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
else
  R=""; G=""; Y=""; B=""; D=""; N=""
fi

STATUS=0; OK_N=0; WARN_N=0; CRIT_N=0; SKIP_N=0; DB_OK=no

ok()      { printf '  %s[  OK  ]%s %s\n' "$G" "$N" "$*"; OK_N=$((OK_N+1)); }
warn()    { printf '  %s[ WARN ]%s %s\n' "$Y" "$N" "$*"; WARN_N=$((WARN_N+1)); (( STATUS < 1 )) && STATUS=1; }
crit()    { printf '  %s[ CRIT ]%s %s\n' "$R" "$N" "$*"; CRIT_N=$((CRIT_N+1)); STATUS=2; }
skip()    { printf '  %s[ SKIP ]%s %s\n' "$D" "$N" "$*"; SKIP_N=$((SKIP_N+1)); }
info()    { printf '           %s%s%s\n' "$D" "$*" "$N"; }
section() { printf '\n%s== %s ==%s\n' "$B" "$1" "$N"; }
enabled() { [[ "$ONLY" == "all" || ",$ONLY," == *",$1,"* ]]; }
trim()    { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }
psqlq()   { psql -X -A -t -q -F '|' -v ON_ERROR_STOP=1 -c "$1" 2>&1; }

# Đánh giá ngưỡng: level <value> <warn> <crit> <message>
threshold() {
  local v="$1" w="$2" c="$3"; shift 3
  if   (( v >= c )); then crit "$* (>= CRIT ${c})"
  elif (( v >= w )); then warn "$* (>= WARN ${w})"
  else ok "$*"; fi
}

# ----------------------------- 1. SERVICE ------------------------------------
check_service() {
  section "1. SERVICE"
  [[ -z "$SERVICES" ]] && { skip "SERVICES chưa cấu hình"; return; }
  local entry type name
  for entry in $SERVICES; do
    if [[ "$entry" == *:* ]]; then type="${entry%%:*}"; name="${entry#*:}"; else type="systemd"; name="$entry"; fi
    case "$type" in
      systemd)
        if ! command -v systemctl >/dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
          skip "systemd/$name: host này không chạy systemd"; continue
        fi
        local active enabled since
        active=$(systemctl is-active "$name" 2>/dev/null)
        enabled=$(systemctl is-enabled "$name" 2>/dev/null)
        since=$(systemctl show -p ActiveEnterTimestamp --value "$name" 2>/dev/null)
        if [[ "$active" == "active" ]]; then
          ok "systemd/$name: active (enabled=${enabled:-?}, since ${since:-?})"
        else
          crit "systemd/$name: ${active:-unknown} (enabled=${enabled:-?})"
        fi
        ;;
      docker)
        if ! command -v docker >/dev/null 2>&1; then skip "docker/$name: không có docker CLI"; continue; fi
        local out st hl rc started
        if ! out=$(docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.RestartCount}}|{{.State.StartedAt}}' "$name" 2>/dev/null); then
          crit "docker/$name: KHÔNG tìm thấy container"; continue
        fi
        IFS='|' read -r st hl rc started <<< "$out"
        if   [[ "$st" != "running" ]];  then crit "docker/$name: state=$st"
        elif [[ "$hl" == "unhealthy" ]]; then crit "docker/$name: running nhưng health=unhealthy"
        elif [[ "$hl" == "starting" ]];  then warn "docker/$name: running, health=starting"
        else ok "docker/$name: running, health=$hl, restarts=$rc, started=${started%.*}"; fi
        ;;
      *) warn "Kiểu service không hỗ trợ: $type ($entry)" ;;
    esac
  done
}

# ----------------------------- 2. PROCESS ------------------------------------
check_process() {
  section "2. PROCESS"
  [[ -z "$PROCESSES" ]] && { skip "PROCESSES chưa cấu hình"; return; }
  local plist p pids count
  IFS=',' read -ra plist <<< "$PROCESSES"
  for p in "${plist[@]}"; do
    p=$(trim "$p"); [[ -z "$p" ]] && continue
    pids=$(pgrep -d, -f -- "$p" || true)
    if [[ -z "$pids" ]]; then crit "process '$p': KHÔNG chạy"; continue; fi
    count=$(tr ',' '\n' <<< "$pids" | wc -l)
    ok "process '$p': $count process đang chạy"
    while IFS= read -r line; do info "${line:0:110}"; done \
      < <(ps -o pid,user,%cpu,%mem,etime,args -p "$pids" 2>/dev/null | head -6)
  done
}

# ----------------------------- 3. URL ----------------------------------------
check_url() {
  section "3. URL"
  [[ -z "$URLS" ]] && { skip "URLS chưa cấu hình"; return; }
  local entry url exp_code exp_text body errf out rc code t ms
  for entry in $URLS; do
    IFS='|' read -r url exp_code exp_text <<< "$entry"
    exp_code="${exp_code:-200}"
    body=$(mktemp); errf=$(mktemp)
    out=$(curl -sS -o "$body" -w '%{http_code} %{time_total}' --max-time "$URL_TIMEOUT" "$url" 2>"$errf"); rc=$?
    code="${out%% *}"; t="${out##* }"
    ms=$(awk -v t="${t:-0}" 'BEGIN{printf "%d", t*1000}')
    if (( rc != 0 )); then
      crit "$url: lỗi kết nối (curl rc=$rc: $(head -c 120 "$errf"))"
    elif [[ "$code" != "$exp_code" ]]; then
      crit "$url: HTTP $code (mong đợi $exp_code), ${ms}ms"
      info "body: $(head -c 150 "$body")"
    elif [[ -n "$exp_text" ]] && ! grep -q -- "$exp_text" "$body"; then
      crit "$url: HTTP $code nhưng body không chứa '$exp_text'"
    elif (( ms >= URL_SLOW_MS )); then
      warn "$url: HTTP $code nhưng chậm ${ms}ms (>= ${URL_SLOW_MS}ms)"
    else
      ok "$url: HTTP $code, ${ms}ms${exp_text:+, có '$exp_text'}"
    fi
    rm -f "$body" "$errf"
  done
}

# ----------------------------- 4. PORT ---------------------------------------
check_port() {
  section "4. PORT"
  [[ -z "$PORTS" ]] && { skip "PORTS chưa cấu hình"; return; }
  local entry host port start ms
  for entry in $PORTS; do
    host="${entry%:*}"; port="${entry##*:}"
    start=$(date +%s%N)
    if timeout "$PORT_TIMEOUT" bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
      ms=$(( ($(date +%s%N) - start) / 1000000 ))
      ok "$host:$port: OPEN (connect ${ms}ms)"
    else
      crit "$host:$port: CLOSED / không kết nối được (timeout ${PORT_TIMEOUT}s)"
    fi
  done
}

# ----------------------------- 5. DB SESSION ---------------------------------
check_db() {
  section "5. DATABASE SESSION"
  [[ "$DB_CHECK" != "yes" ]] && { skip "DB_CHECK=no"; return; }
  command -v psql >/dev/null 2>&1 || { skip "Không có psql client"; return; }

  local out ver up total maxc pct rows
  if ! out=$(psqlq "select split_part(version(),' on ',1), date_trunc('second', now()-pg_postmaster_start_time())"); then
    crit "Không kết nối được DB ${PGHOST:-localhost}:${PGPORT:-5432}/${PGDATABASE:-?}: ${out:0:150}"
    return
  fi
  DB_OK=yes
  IFS='|' read -r ver up <<< "$out"
  ok "Kết nối DB OK: $ver, uptime $up"

  # Tổng session so với max_connections
  IFS='|' read -r total maxc <<< "$(psqlq "select count(*), current_setting('max_connections') from pg_stat_activity where backend_type='client backend'")"
  pct=$(( total * 100 / maxc ))
  threshold "$pct" "$DB_SESSION_WARN_PCT" "$DB_SESSION_CRIT_PCT" "Sessions: $total/$maxc max_connections (${pct}%)"

  info "Theo state:"
  while IFS='|' read -r s c; do info "  - $s: $c"; done < <(psqlq "
    select coalesce(state,'-'), count(*) from pg_stat_activity
    where backend_type='client backend' group by 1 order by 2 desc")
  info "Top user / application / client:"
  while IFS='|' read -r u a h c; do info "  - $u / ${a:--} / $h: $c"; done < <(psqlq "
    select usename, application_name, coalesce(host(client_addr),'local'), count(*)
    from pg_stat_activity where backend_type='client backend'
    group by 1,2,3 order by 4 desc limit 5")

  # Long-running query
  rows=$(psqlq "
    select pid, usename, date_trunc('second', now()-query_start), left(regexp_replace(query,'\s+',' ','g'),60)
    from pg_stat_activity
    where state='active' and backend_type='client backend' and pid<>pg_backend_pid()
      and now()-query_start > interval '${DB_LONG_QUERY_SEC} seconds'
    order by 3 desc")
  if [[ -n "$rows" ]]; then
    warn "Long-running query > ${DB_LONG_QUERY_SEC}s: $(wc -l <<< "$rows") session"
    while IFS='|' read -r pid u d q; do info "  pid=$pid user=$u dur=$d sql=$q"; done <<< "$rows"
  else
    ok "Không có query chạy quá ${DB_LONG_QUERY_SEC}s"
  fi

  # Idle in transaction (giữ lock, chặn vacuum)
  rows=$(psqlq "
    select pid, usename, date_trunc('second', now()-state_change)
    from pg_stat_activity
    where state like 'idle in transaction%' and now()-state_change > interval '${DB_IDLE_TX_SEC} seconds'")
  if [[ -n "$rows" ]]; then
    warn "Idle in transaction > ${DB_IDLE_TX_SEC}s: $(wc -l <<< "$rows") session"
    while IFS='|' read -r pid u d; do info "  pid=$pid user=$u idle=$d"; done <<< "$rows"
  else
    ok "Không có session idle-in-transaction quá ${DB_IDLE_TX_SEC}s"
  fi

  # Session bị block bởi lock
  rows=$(psqlq "
    select pid, pg_blocking_pids(pid)::text, usename, date_trunc('second', now()-query_start), left(query,50)
    from pg_stat_activity where cardinality(pg_blocking_pids(pid)) > 0")
  if [[ -n "$rows" ]]; then
    crit "Session bị BLOCK: $(wc -l <<< "$rows")"
    while IFS='|' read -r pid by u d q; do info "  pid=$pid blocked_by=$by user=$u wait=$d sql=$q"; done <<< "$rows"
  else
    ok "Không có session bị block"
  fi
}

# ----------------------------- 6. TABLESPACE ---------------------------------
check_tablespace() {
  section "6. TABLESPACE / STORAGE"
  if [[ "$DB_OK" != "yes" ]]; then
    skip "Bỏ qua tablespace vì DB không kết nối được / chưa check"
  else
    local name mb pretty loc
    while IFS='|' read -r name mb pretty loc; do
      threshold "$mb" "$TS_SIZE_WARN_MB" "$TS_SIZE_CRIT_MB" "Tablespace $name: $pretty (location: $loc)"
    done < <(psqlq "
      select spcname, pg_tablespace_size(oid)/1048576, pg_size_pretty(pg_tablespace_size(oid)),
             coalesce(nullif(pg_tablespace_location(oid),''),'PGDATA')
      from pg_tablespace order by 2 desc")

    info "Database size:"
    while IFS='|' read -r d s; do info "  - $d: $s"; done < <(psqlq "
      select datname, pg_size_pretty(pg_database_size(datname))
      from pg_database where not datistemplate order by pg_database_size(datname) desc")
    info "Top 5 table (current DB):"
    while IFS='|' read -r t s live dead; do info "  - $t: $s (live=$live, dead=$dead)"; done < <(psqlq "
      select schemaname||'.'||relname, pg_size_pretty(pg_total_relation_size(relid)), n_live_tup, n_dead_tup
      from pg_stat_user_tables order by pg_total_relation_size(relid) desc limit 5")
  fi

  if [[ -n "$DISK_PATH" ]]; then
    if [[ -d "$DISK_PATH" ]]; then
      local size used avail pct
      read -r size used avail pct < <(df -Ph "$DISK_PATH" | awk 'NR==2{print $2,$3,$4,$5}')
      threshold "${pct%\%}" "$DISK_WARN_PCT" "$DISK_CRIT_PCT" "Disk $DISK_PATH: dùng $used/$size ($pct), còn trống $avail"
    else
      warn "DISK_PATH=$DISK_PATH không tồn tại"
    fi
  fi
}

# ----------------------------- MAIN ------------------------------------------
printf '%sAPPLICATION HEALTH-CHECK%s  host=%s  time=%s\n' "$B" "$N" "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S %z')"

enabled service    && check_service
enabled process    && check_process
enabled url        && check_url
enabled port       && check_port
enabled db         && check_db
enabled tablespace && check_tablespace

case $STATUS in 0) RESULT=OK; C=$G ;; 1) RESULT=WARNING; C=$Y ;; *) RESULT=CRITICAL; C=$R ;; esac
section "SUMMARY"
printf '  OK=%d  WARNING=%d  CRITICAL=%d  SKIP=%d\n' "$OK_N" "$WARN_N" "$CRIT_N" "$SKIP_N"
printf '  OVERALL: %s%s%s%s\n' "$B" "$C" "$RESULT" "$N"
echo "HC_RESULT=$RESULT ok=$OK_N warn=$WARN_N crit=$CRIT_N skip=$SKIP_N"
exit $STATUS
