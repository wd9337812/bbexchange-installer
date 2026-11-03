#!/usr/bin/env bash
set -Eeuo pipefail
compose=${1:-deploy/docker-compose.image.yml}
env_file=${2:-.env.prod}
# Called only after the old producers have drained. Never terminate backends,
# cancel arbitrary long transactions, or clear execution/advertising locks.
for role in api worker;do
  id=$(docker compose --env-file "$env_file" -f "$compose" ps --all -q "$role")
  if [[ ! "$id" =~ ^[a-f0-9]{12,64}$ ]];then echo "[update] cannot uniquely identify stopped $role; no database query was cancelled";exit 36;fi
  running=$(docker inspect "$id" --format '{{.State.Running}}')
  if [[ "$running" != false ]];then echo "[update] $role is not stopped; no database query was cancelled";exit 36;fi
done
docker compose --env-file "$env_file" -f "$compose" exec -T postgres sh -lc \
 'exec psql -X -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-bb}" -d "${POSTGRES_DB:-bbexchange}"' <<'SQL'
set statement_timeout='5s';
-- This is the exact 1 KiB prefix fingerprint observed on the affected VPS.
-- The text/type/age checks additionally fence cancellation to the known SELECT.
select pid,pg_cancel_backend(pid) as cancelled_known_read
from pg_stat_activity
where datname=current_database() and pid<>pg_backend_pid()
 and backend_type='client backend' and state='active'
 and query_start<clock_timestamp()-interval '5 seconds'
 and md5(left(query,1023))='d9527ba3ba913e41b36cd211195181fe'
 and query ~* '^select q.id,q.task_id,lineage.id problem_id,';
select pid,state,wait_event_type,clock_timestamp()-query_start as age,
 pg_blocking_pids(pid) as blocked_by,md5(left(query,1023)) as fingerprint
from pg_stat_activity where datname=current_database() and pid<>pg_backend_pid()
 and state<>'idle' order by query_start limit 10;
SQL
