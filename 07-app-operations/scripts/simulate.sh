#!/usr/bin/env bash
# =============================================================================
# simulate.sh - tạo sự cố để demo health-check phát hiện đúng
#
#   sessions [N]   mở N session idle         -> DB SESSION WARN/CRIT (% max_connections)
#   longquery [N]  chạy N query pg_sleep     -> "Long-running query" WARN
#   lock           1 transaction giữ lock + 1 session bị chặn -> idle-in-tx WARN + BLOCK CRIT
#   bloat [ROWS]   ghi dữ liệu không nén      -> TABLESPACE pg_default WARN/CRIT
#   cleanup        kill toàn bộ session giả lập + drop bảng hc_bloat
#
# Biến HOLD = số giây giữ session (mặc định 600).
# =============================================================================
set -euo pipefail
export PGAPPNAME=hc-simulator
HOLD="${HOLD:-600}"

case "${1:-}" in
  sessions)
    n="${2:-20}"
    for _ in $(seq "$n"); do { echo "select 1;"; sleep "$HOLD"; } | psql -X -q >/dev/null & done
    echo "Đã mở $n session idle (giữ ${HOLD}s)."; wait ;;
  longquery)
    n="${2:-1}"
    for _ in $(seq "$n"); do psql -X -q -c "select pg_sleep($HOLD)" >/dev/null & done
    echo "Đang chạy $n query pg_sleep($HOLD)."; wait ;;
  lock)
    { echo "begin; update items set name = name where id = 1;"; sleep "$HOLD"; } | psql -X -q >/dev/null &
    sleep 1
    psql -X -q -c "update items set name = name where id = 1" >/dev/null &
    echo "Session A giữ lock row items.id=1 (idle in transaction), session B đang bị block."; wait ;;
  bloat)
    rows="${2:-150000}"
    psql -X -v ON_ERROR_STOP=1 <<SQL
create table if not exists hc_bloat(id bigserial primary key, payload text);
alter table hc_bloat alter column payload set storage plain;  -- tắt nén để dung lượng tăng thật
insert into hc_bloat(payload) select repeat(md5(g::text), 30) from generate_series(1, $rows) g;
select pg_size_pretty(pg_total_relation_size('hc_bloat')) as hc_bloat_size,
       pg_size_pretty(pg_tablespace_size('pg_default'))    as pg_default_size;
SQL
    ;;
  cleanup)
    psql -X -c "select count(pg_terminate_backend(pid)) as killed from pg_stat_activity
                where application_name = 'hc-simulator' and pid <> pg_backend_pid()"
    psql -X -c "drop table if exists hc_bloat" ;;
  *) sed -n '2,13p' "$0"; exit 1 ;;
esac
