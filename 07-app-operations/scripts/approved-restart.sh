#!/usr/bin/env bash
# =============================================================================
# approved-restart.sh - Unit 4: Restart đã duyệt & thu thập log BEFORE/AFTER
#
# Trình tự bắt buộc (không bước nào được bỏ qua):
#   [0] KIỂM TRA PHÊ DUYỆT : Change Request tồn tại, status=APPROVED, người duyệt
#                            khác người thực hiện, target nằm trong CR, đang trong
#                            maintenance window  -> sai bất kỳ điều kiện nào = TỪ CHỐI
#   [1] XÁC NHẬN           : người thực hiện gõ lại Change ID
#   [2] BEFORE             : health-check + trạng thái service/process + log ứng dụng
#                            + DB session + system  -> evidence/<run>/before/
#   [3] RESTART            : docker restart / systemctl restart, ghi timestamp
#   [4] VERIFY             : xác nhận đã thực sự restart (StartedAt/PID đổi) và chờ healthy
#   [5] AFTER              : thu thập lại y hệt BEFORE  -> evidence/<run>/after/
#   [6] ĐÓNG GÓI           : so sánh BEFORE/AFTER, REPORT.md, SHA256SUMS, .tar.gz, audit.log
#
# Exit code: 0=SUCCESS  1=SUCCESS_WITH_WARNING  2=FAILED  3=REJECTED (không đủ điều kiện)
#
# Usage:
#   approved-restart.sh -c /approvals/CR-DEMO-001.env -t docker:hc-backend [-y] [--dry-run]
#     -c  file Change Request đã duyệt
#     -t  target: docker:<container> | systemd:<unit>
#     -y  bỏ qua bước gõ xác nhận (dùng cho automation)
#     --dry-run  chỉ chạy [0][1][2], không restart
# =============================================================================
set -uo pipefail

EVIDENCE_DIR="${EVIDENCE_DIR:-/evidence}"
HC_SCRIPT="${HC_SCRIPT:-$(dirname "$0")/healthcheck.sh}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-120}"   # giây chờ service healthy sau restart
STOP_TIMEOUT="${STOP_TIMEOUT:-30}"    # graceful stop timeout
LOG_TAIL="${LOG_TAIL:-200}"           # số dòng log BEFORE
WAIT_URL="${WAIT_URL:-}"              # URL phải trả 2xx thì mới coi là healthy
OPERATOR="${OPERATOR:-$(whoami)}"

CR_FILE=""; TARGET=""; ASSUME_YES=no; DRY_RUN=no
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) CR_FILE="$2"; shift 2 ;;
    -t) TARGET="$2"; shift 2 ;;
    -y) ASSUME_YES=yes; shift ;;
    --dry-run) DRY_RUN=yes; shift ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) echo "Tham số không hợp lệ: $1" >&2; exit 3 ;;
  esac
done
[[ -z "$CR_FILE" || -z "$TARGET" ]] && { sed -n '22,27p' "$0"; exit 3; }

if [[ "$TARGET" == *:* ]]; then TTYPE="${TARGET%%:*}"; TNAME="${TARGET#*:}"; else TTYPE=systemd; TNAME="$TARGET"; fi

# ----------------------------- Helpers ---------------------------------------
cr_get() { [[ -f "$CR_FILE" ]] && grep -E "^$1=" "$CR_FILE" | head -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' -e "s/\r$//"; }
now()    { date '+%Y-%m-%dT%H:%M:%S%z'; }

CHANGE_ID="$(cr_get CHANGE_ID)"; CHANGE_ID="${CHANGE_ID:-NO-CR}"
RUN_ID="${CHANGE_ID}_${TNAME}_$(date +%Y%m%d_%H%M%S)"
RUN_DIR="$EVIDENCE_DIR/$RUN_ID"
mkdir -p "$RUN_DIR/before" "$RUN_DIR/after"

# Toàn bộ output được ghi lại vào execution.log
exec > >(tee -a "$RUN_DIR/execution.log") 2>&1

log()   { printf '%s  %s\n' "$(now)" "$*"; }
step()  { printf '\n%s  ===== %s =====\n' "$(now)" "$*"; printf '%s|%s\n' "$(now)" "$*" >> "$RUN_DIR/timeline.txt"; }
pass()  { log "  [PASS] $*"; }
fail()  { log "  [FAIL] $*"; REJECT=yes; }
audit() { printf '%s | %s | operator=%s | target=%s | result=%s | evidence=%s\n' \
            "$(now)" "$CHANGE_ID" "$OPERATOR" "$TARGET" "$1" "$RUN_DIR" >> "$EVIDENCE_DIR/audit.log"; }

# Trạng thái ngắn gọn của target: state|health|pid|started_at|restart_count
target_state() {
  case "$TTYPE" in
    docker)  docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.State.Pid}}|{{.State.StartedAt}}|{{.RestartCount}}' "$TNAME" 2>/dev/null ;;
    systemd) printf '%s|none|%s|%s|%s\n' "$(systemctl is-active "$TNAME")" \
               "$(systemctl show -p MainPID --value "$TNAME")" \
               "$(systemctl show -p ActiveEnterTimestamp --value "$TNAME")" \
               "$(systemctl show -p NRestarts --value "$TNAME")" ;;
  esac
}

# ----------------------------- Thu thập evidence -----------------------------
# collect <before|after> <log_since>
collect() {
  local phase="$1" since="${2:-}" d="$RUN_DIR/$1"
  log "Thu thập evidence $phase -> $d"

  now > "$d/00_collected_at.txt"

  NO_COLOR=1 bash "$HC_SCRIPT" > "$d/01_healthcheck.txt" 2>&1
  echo "$?" > "$d/01_healthcheck.exitcode"
  log "  01_healthcheck.txt      : $(tail -1 "$d/01_healthcheck.txt")"

  target_state > "$d/02_service_state.txt"
  case "$TTYPE" in
    docker)
      docker inspect "$TNAME" > "$d/02_service_inspect.json" 2>&1
      docker top "$TNAME" -eo pid,user,pcpu,pmem,etime,args > "$d/03_process.txt" 2>&1
      if [[ -n "$since" ]]; then docker logs --timestamps --since "$since" "$TNAME" > "$d/04_app.log" 2>&1
      else docker logs --timestamps --tail "$LOG_TAIL" "$TNAME" > "$d/04_app.log" 2>&1; fi
      docker stats --no-stream "$TNAME" > "$d/06_resource.txt" 2>&1
      ;;
    systemd)
      systemctl status "$TNAME" --no-pager -l > "$d/02_service_inspect.txt" 2>&1
      local mpid; mpid=$(systemctl show -p MainPID --value "$TNAME")
      ps -o pid,user,pcpu,pmem,etime,args --ppid "$mpid" -p "$mpid" > "$d/03_process.txt" 2>&1
      if [[ -n "$since" ]]; then journalctl -u "$TNAME" --since "$since" --no-pager -o short-iso > "$d/04_app.log" 2>&1
      else journalctl -u "$TNAME" -n "$LOG_TAIL" --no-pager -o short-iso > "$d/04_app.log" 2>&1; fi
      ;;
  esac
  log "  02_service_state.txt    : $(cat "$d/02_service_state.txt")"
  log "  04_app.log              : $(wc -l < "$d/04_app.log") dòng"

  if command -v psql >/dev/null 2>&1 && [[ -n "${PGHOST:-}" ]]; then
    PGAPPNAME=approved-restart psql -X -P pager=off -c "
      select pid, usename, application_name, coalesce(host(client_addr),'local') client, state,
             date_trunc('second', now()-backend_start) conn_age, left(query,60) query
      from pg_stat_activity where backend_type='client backend' order by backend_start" \
      > "$d/05_db_sessions.txt" 2>&1
    log "  05_db_sessions.txt      : $(grep -c '|' "$d/05_db_sessions.txt") dòng"
  fi

  { echo "### uptime"; uptime; echo; echo "### memory"; free -m; echo; echo "### disk"; df -h; } \
    >> "$d/06_resource.txt" 2>&1
}

# ============================== [0] PHÊ DUYỆT ================================
echo "APPROVED RESTART  run=$RUN_ID  operator=$OPERATOR"
step "[0] KIỂM TRA PHÊ DUYỆT (Change Request)"
REJECT=no
if [[ ! -f "$CR_FILE" ]]; then
  fail "Không tìm thấy file Change Request: $CR_FILE"
else
  cp "$CR_FILE" "$RUN_DIR/change_request.env"
  for k in CHANGE_ID TITLE REQUESTED_BY APPROVED_BY APPROVAL_STATUS TARGETS WINDOW_START WINDOW_END ROLLBACK_PLAN; do
    v="$(cr_get "$k")"; [[ -z "$v" ]] && fail "Thiếu trường bắt buộc: $k" || log "  $k=$v"
  done

  STATUS_V="$(cr_get APPROVAL_STATUS)"
  [[ "$STATUS_V" == "APPROVED" ]] && pass "APPROVAL_STATUS=APPROVED" || fail "APPROVAL_STATUS=$STATUS_V (yêu cầu APPROVED)"

  APPROVER="$(cr_get APPROVED_BY)"
  if [[ -n "$APPROVER" && "$APPROVER" != "$OPERATOR" ]]; then pass "Người duyệt ($APPROVER) khác người thực hiện ($OPERATOR)"
  else fail "Người duyệt trùng người thực hiện hoặc trống (four-eyes principle)"; fi

  TARGETS_V=" $(cr_get TARGETS | tr ',' ' ') "
  [[ "$TARGETS_V" == *" $TARGET "* ]] && pass "Target $TARGET nằm trong CR" || fail "Target $TARGET KHÔNG nằm trong CR (CR cho phép:$TARGETS_V)"

  WS=$(date -d "$(cr_get WINDOW_START)" +%s 2>/dev/null || echo 0)
  WE=$(date -d "$(cr_get WINDOW_END)" +%s 2>/dev/null || echo 0)
  NOW_S=$(date +%s)
  if (( WS == 0 || WE == 0 )); then fail "WINDOW_START/WINDOW_END sai định dạng (ISO-8601)"
  elif (( NOW_S < WS )); then fail "Chưa tới maintenance window (bắt đầu $(cr_get WINDOW_START))"
  elif (( NOW_S > WE )); then fail "Đã hết maintenance window (kết thúc $(cr_get WINDOW_END))"
  else pass "Đang trong maintenance window ($(cr_get WINDOW_START) -> $(cr_get WINDOW_END))"; fi
fi

if [[ -z "$(target_state)" ]]; then fail "Target $TARGET không tồn tại / không đọc được trạng thái"; fi

if [[ "$REJECT" == "yes" ]]; then
  log "KẾT QUẢ: REJECTED - không thực hiện restart."
  audit REJECTED
  exit 3
fi

# ============================== [1] XÁC NHẬN =================================
step "[1] XÁC NHẬN CỦA NGƯỜI THỰC HIỆN"
if [[ "$ASSUME_YES" == "yes" ]]; then
  log "  -y: xác nhận tự động bởi $OPERATOR"
else
  read -r -p "  Gõ lại Change ID ($CHANGE_ID) để xác nhận restart $TARGET: " ANSWER
  if [[ "$ANSWER" != "$CHANGE_ID" ]]; then
    log "  Xác nhận sai ('$ANSWER') -> huỷ."
    audit ABORTED_BY_OPERATOR; exit 3
  fi
  log "  Đã xác nhận bởi $OPERATOR"
fi

# ============================== [2] BEFORE ===================================
step "[2] BEFORE - thu thập trạng thái & log trước restart"
collect before
BEFORE_STATE="$(cat "$RUN_DIR/before/02_service_state.txt")"
BEFORE_HC="$(tail -1 "$RUN_DIR/before/01_healthcheck.txt")"
[[ "$BEFORE_HC" != *"=OK "* ]] && log "  LƯU Ý: health-check trước restart không OK ($BEFORE_HC) - ghi nhận làm baseline."

if [[ "$DRY_RUN" == "yes" ]]; then
  step "DRY-RUN - dừng trước bước restart"
  audit DRY_RUN
  exit 0
fi

# ============================== [3] RESTART ==================================
step "[3] RESTART $TARGET"
RESTART_START_ISO="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; RS=$(date +%s)
case "$TTYPE" in
  docker)  docker restart -t "$STOP_TIMEOUT" "$TNAME"; RC=$? ;;
  systemd) systemctl restart "$TNAME"; RC=$? ;;
  *) log "Kiểu target không hỗ trợ: $TTYPE"; RC=99 ;;
esac
RE=$(date +%s)
log "  Lệnh restart rc=$RC, mất $((RE-RS))s"

# ============================== [4] VERIFY ===================================
step "[4] VERIFY - xác nhận đã restart & chờ healthy (timeout ${WAIT_TIMEOUT}s)"
HEALTHY=no
for (( i=0; i<WAIT_TIMEOUT; i+=3 )); do
  IFS='|' read -r st hl _ <<< "$(target_state)"
  url_ok=yes
  if [[ -n "$WAIT_URL" ]]; then curl -fsS -o /dev/null --max-time 3 "$WAIT_URL" || url_ok=no; fi
  log "  t+${i}s state=$st health=$hl url_ok=$url_ok"
  if [[ "$st" =~ ^(running|active)$ && "$hl" =~ ^(healthy|none)$ && "$url_ok" == yes ]]; then HEALTHY=yes; break; fi
  sleep 3
done
TTH=$(( $(date +%s) - RS ))
AFTER_STATE_NOW="$(target_state)"
IFS='|' read -r _ _ b_pid b_started _ <<< "$BEFORE_STATE"
IFS='|' read -r _ _ a_pid a_started _ <<< "$AFTER_STATE_NOW"
if [[ "$b_started" != "$a_started" || "$b_pid" != "$a_pid" ]]; then RESTARTED=yes; log "  [PASS] Đã restart thật: PID $b_pid -> $a_pid"
else RESTARTED=no; log "  [FAIL] StartedAt/PID không đổi - restart KHÔNG diễn ra"; fi
[[ "$HEALTHY" == yes ]] && log "  [PASS] Healthy sau ${TTH}s" || log "  [FAIL] Không healthy sau ${WAIT_TIMEOUT}s"

# ============================== [5] AFTER ====================================
step "[5] AFTER - thu thập trạng thái & log sau restart"
sleep 2
collect after "$RESTART_START_ISO"
AFTER_STATE="$(cat "$RUN_DIR/after/02_service_state.txt")"
AFTER_HC="$(tail -1 "$RUN_DIR/after/01_healthcheck.txt")"
AFTER_ERR=$(grep -Eic 'error|exception|traceback|fatal' "$RUN_DIR/after/04_app.log" || true)

# ============================== [6] ĐÓNG GÓI =================================
step "[6] SO SÁNH BEFORE/AFTER & ĐÓNG GÓI EVIDENCE"
if   [[ $RC -ne 0 || "$RESTARTED" != yes || "$HEALTHY" != yes || "$AFTER_HC" == *CRITICAL* ]]; then RESULT=FAILED; EXIT=2
elif [[ "$AFTER_HC" == *WARNING* || $AFTER_ERR -gt 0 ]]; then RESULT=SUCCESS_WITH_WARNING; EXIT=1
else RESULT=SUCCESS; EXIT=0; fi

diff -u "$RUN_DIR/before/01_healthcheck.txt" "$RUN_DIR/after/01_healthcheck.txt" > "$RUN_DIR/diff_healthcheck.txt"
diff -u "$RUN_DIR/before/03_process.txt" "$RUN_DIR/after/03_process.txt" > "$RUN_DIR/diff_process.txt"

IFS='|' read -r b_st b_hl b_pid b_started b_rc <<< "$BEFORE_STATE"
IFS='|' read -r a_st a_hl a_pid a_started a_rc <<< "$AFTER_STATE"
cat > "$RUN_DIR/REPORT.md" <<EOF
# Restart Report — $CHANGE_ID

| Mục | Giá trị |
|---|---|
| Change ID | $CHANGE_ID |
| Tiêu đề | $(cr_get TITLE) |
| Target | \`$TARGET\` |
| Người yêu cầu / duyệt / thực hiện | $(cr_get REQUESTED_BY) / $(cr_get APPROVED_BY) / $OPERATOR |
| Maintenance window | $(cr_get WINDOW_START) → $(cr_get WINDOW_END) |
| Lệnh restart | rc=$RC, thời gian $((RE-RS))s (bắt đầu $RESTART_START_ISO) |
| Thời gian tới healthy | ${TTH}s |
| **KẾT QUẢ** | **$RESULT** |

## Timeline
| Thời điểm | Bước |
|---|---|
$(sed 's/|/ | /; s/^/| /; s/$/ |/' "$RUN_DIR/timeline.txt")

## BEFORE vs AFTER
| Chỉ số | BEFORE | AFTER |
|---|---|---|
| State | $b_st | $a_st |
| Health | $b_hl | $a_hl |
| PID | $b_pid | $a_pid |
| StartedAt | $b_started | $a_started |
| RestartCount | $b_rc | $a_rc |
| Health-check | \`$BEFORE_HC\` | \`$AFTER_HC\` |
| Dòng log | $(wc -l < "$RUN_DIR/before/04_app.log") (tail $LOG_TAIL) | $(wc -l < "$RUN_DIR/after/04_app.log") (từ lúc restart) |
| Dòng log có error/exception | $(grep -Eic 'error|exception|traceback|fatal' "$RUN_DIR/before/04_app.log" || true) | $AFTER_ERR |

## Rollback plan (theo CR)
$(cr_get ROLLBACK_PLAN)

## Evidence
\`\`\`
$(cd "$RUN_DIR" && find . -type f | sort)
\`\`\`
EOF

step "KẾT THÚC: $RESULT"
( cd "$RUN_DIR" && find . -type f ! -name SHA256SUMS ! -name execution.log -exec sha256sum {} + | sort -k2 > SHA256SUMS )
tar -czf "$RUN_DIR.tar.gz" -C "$EVIDENCE_DIR" "$RUN_ID"
audit "$RESULT"

log "Report  : $RUN_DIR/REPORT.md"
log "Archive : $RUN_DIR.tar.gz"
if [[ "$RESULT" == FAILED ]]; then
  log "!!! RESTART FAILED - thực hiện rollback plan & escalate: $(cr_get ROLLBACK_PLAN)"
fi
exit $EXIT
