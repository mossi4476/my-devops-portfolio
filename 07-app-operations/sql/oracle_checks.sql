-- =============================================================================
-- Tham chiếu: câu lệnh tương đương khi DB là ORACLE (healthcheck.sh dùng PostgreSQL)
-- Chạy: sqlplus -s user/pass@db @oracle_checks.sql
-- =============================================================================
set lines 200 pages 100

-- 1. Session usage so với giới hạn
select r.resource_name, r.current_utilization, r.max_utilization, r.limit_value,
       round(r.current_utilization * 100 / to_number(r.limit_value), 1) pct
from v$resource_limit r where r.resource_name in ('sessions', 'processes');

-- 2. Session theo trạng thái / user / máy
select status, username, machine, program, count(*) cnt
from v$session where type = 'USER'
group by status, username, machine, program order by cnt desc;

-- 3. Long-running (active > 60s) & session bị block
select sid, serial#, username, last_call_et sec, sql_id, event
from v$session where status = 'ACTIVE' and type = 'USER' and last_call_et > 60;

select sid, serial#, username, blocking_session, event, seconds_in_wait
from v$session where blocking_session is not null;

-- 4. Tablespace usage (có tính autoextend)
select df.tablespace_name,
       round(df.bytes / 1024 / 1024)                          size_mb,
       round((df.bytes - nvl(fs.bytes, 0)) / 1024 / 1024)     used_mb,
       round(df.maxbytes / 1024 / 1024)                       max_mb,
       round((df.bytes - nvl(fs.bytes, 0)) * 100 / df.maxbytes, 1) pct_of_max
from (select tablespace_name, sum(bytes) bytes,
             sum(greatest(bytes, decode(autoextensible, 'YES', maxbytes, bytes))) maxbytes
      from dba_data_files group by tablespace_name) df
left join (select tablespace_name, sum(bytes) bytes from dba_free_space group by tablespace_name) fs
       on fs.tablespace_name = df.tablespace_name
order by pct_of_max desc;

-- 5. TEMP tablespace
select tablespace_name, round(tablespace_size/1024/1024) size_mb,
       round((tablespace_size - free_space)/1024/1024) used_mb, round(free_space/1024/1024) free_mb
from dba_temp_free_space;
