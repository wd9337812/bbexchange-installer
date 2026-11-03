#!/bin/sh
set -eu

COMPOSE_FILE="${1:-deploy/docker-compose.prod.yml}"
ENV_FILE="${2:-.env.prod}"
MIGRATIONS_DIR="${MIGRATIONS_DIR:-apps/backend/sql/migrations}"
BASELINE_SCHEMA="${BASELINE_SCHEMA:-apps/backend/sql/phase1_schema.sql}"
SOURCE_IMAGE="${SOURCE_IMAGE:-}"
SOURCE_BASELINE_SCHEMA="${SOURCE_BASELINE_SCHEMA:-/app/apps/backend/sql/phase1_schema.sql}"
SOURCE_MIGRATIONS_DIR="${SOURCE_MIGRATIONS_DIR:-/app/apps/backend/sql/migrations}"
POSTGRES_SERVICE="${POSTGRES_SERVICE:-postgres}"

if [ ! -f "$ENV_FILE" ]; then
  echo "env file not found: $ENV_FILE"
  exit 1
fi

set -a
. "./$ENV_FILE"
set +a

if [ "${STORAGE_MODE:-postgres}" != "postgres" ]; then
  echo "db_migrate: STORAGE_MODE=${STORAGE_MODE:-} skip"
  exit 0
fi

SERVICES="$(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config --services 2>/dev/null || true)"
if ! printf '%s\n' "$SERVICES" | grep -qx "$POSTGRES_SERVICE"; then
  if printf '%s\n' "$SERVICES" | grep -qx "postgres_admin"; then
    POSTGRES_SERVICE="postgres_admin"
  fi
fi

run_psql_stdin() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T "$POSTGRES_SERVICE" \
    sh -lc "PGPASSWORD='${POSTGRES_PASSWORD:-bb_change_me}' psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U '${POSTGRES_USER:-bb}' -d '${POSTGRES_DB:-bbexchange}'" >/dev/null
}

run_super_psql_stdin() {
  SUPERUSER_ROLE="${POSTGRES_SUPERUSER:-${POSTGRES_USER:-bb}}"
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T "$POSTGRES_SERVICE" \
    psql -v ON_ERROR_STOP=1 -U "${SUPERUSER_ROLE}" -d postgres >/dev/null
}

run_psql_cmd() {
  sql="$1"
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T "$POSTGRES_SERVICE" \
    sh -lc "PGPASSWORD='${POSTGRES_PASSWORD:-bb_change_me}' psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U '${POSTGRES_USER:-bb}' -d '${POSTGRES_DB:-bbexchange}' -c \"$sql\"" >/dev/null
}

sql_escape_literal() {
  printf "%s" "$1" | sed "s/'/''/g"
}

ensure_app_identity() {
  APP_USER="${POSTGRES_USER:-bb}"
  APP_DB="${POSTGRES_DB:-bbexchange}"
  APP_PASS="${POSTGRES_PASSWORD:-bb_change_me}"
  APP_USER_ESC="$(sql_escape_literal "$APP_USER")"
  APP_DB_ESC="$(sql_escape_literal "$APP_DB")"
  APP_PASS_ESC="$(sql_escape_literal "$APP_PASS")"

  if docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T "$POSTGRES_SERVICE" \
    sh -lc "PGPASSWORD='${APP_PASS}' psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U '${APP_USER}' -d '${APP_DB}' -c 'select 1;' >/dev/null" >/dev/null 2>&1; then
    return
  fi

  echo "db_migrate: app db credential mismatch detected, repairing role/db mapping..."
  cat <<EOF | run_super_psql_stdin
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='${APP_USER_ESC}') THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', '${APP_USER_ESC}', '${APP_PASS_ESC}');
  ELSE
    EXECUTE format('ALTER ROLE %I WITH LOGIN PASSWORD %L', '${APP_USER_ESC}', '${APP_PASS_ESC}');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='${APP_DB_ESC}') THEN
    EXECUTE format('CREATE DATABASE %I OWNER %I', '${APP_DB_ESC}', '${APP_USER_ESC}');
  END IF;
  EXECUTE format('GRANT ALL PRIVILEGES ON DATABASE %I TO %I', '${APP_DB_ESC}', '${APP_USER_ESC}');
END
\$\$;
EOF

  if ! docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T "$POSTGRES_SERVICE" \
    sh -lc "PGPASSWORD='${APP_PASS}' psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U '${APP_USER}' -d '${APP_DB}' -c 'select 1;' >/dev/null" >/dev/null 2>&1; then
    echo "db_migrate: failed to repair app db credential"
    exit 1
  fi
}

load_baseline_sql() {
  if [ -n "$SOURCE_IMAGE" ]; then
    docker run --rm --entrypoint sh "$SOURCE_IMAGE" -lc "cat '$SOURCE_BASELINE_SCHEMA'"
    return
  fi
  cat "$BASELINE_SCHEMA"
}

list_migration_files() {
  if [ -n "$SOURCE_IMAGE" ]; then
    docker run --rm --entrypoint sh "$SOURCE_IMAGE" -lc \
      "for f in '$SOURCE_MIGRATIONS_DIR'/*.sql; do [ -f \"\$f\" ] && basename \"\$f\"; done" | sort
    return
  fi
  if [ -d "$MIGRATIONS_DIR" ]; then
    find "$MIGRATIONS_DIR" -maxdepth 1 -type f -name '*.sql' -printf '%f\n' | sort
  fi
}

load_migration_sql() {
  file="$1"
  if [ -n "$SOURCE_IMAGE" ]; then
    docker run --rm --entrypoint sh "$SOURCE_IMAGE" -lc "cat '$SOURCE_MIGRATIONS_DIR/$file'"
    return
  fi
  cat "$MIGRATIONS_DIR/$file"
}

ensure_required_schema() {
  echo "db_migrate: validating required schema..."
  cat <<'EOF' | run_psql_stdin
alter table if exists tasks
  add column if not exists delivery_status varchar(32) not null default '测试中';
create index if not exists idx_tasks_delivery_status on tasks(delivery_status);
EOF
}

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d "$POSTGRES_SERVICE"

echo "db_migrate: waiting postgres..."
READY=false
i=0
while [ $i -lt 60 ]; do
  if docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T "$POSTGRES_SERVICE" \
    pg_isready -U "${POSTGRES_SUPERUSER:-${POSTGRES_USER:-bb}}" -d postgres >/dev/null 2>&1; then
    READY=true
    break
  fi
  i=$((i+1))
  sleep 2
done

if [ "$READY" != "true" ]; then
  echo "db_migrate: postgres is not ready"
  exit 1
fi

ensure_app_identity
# One psql session owns the upgrade lock. SQL and its marker commit together.
# Historical migration files are not edited or marked applied speculatively.
PLAN_FILE="$(mktemp)"
SQL_DIR=""
EXTRACT_CONTAINER=""
cleanup_plan(){
  rm -f "$PLAN_FILE" "$PLAN_FILE.part"
  if [ -n "$EXTRACT_CONTAINER" ];then docker rm "$EXTRACT_CONTAINER" >/dev/null 2>&1 || true;fi
  case "$SQL_DIR" in /tmp/bb-migrate.*) rm -rf -- "$SQL_DIR";; esac
}
trap cleanup_plan EXIT
if [ -n "$SOURCE_IMAGE" ];then
  SQL_DIR="$(mktemp -d /tmp/bb-migrate.XXXXXX)"
  EXTRACT_CONTAINER="$(docker create --entrypoint sh "$SOURCE_IMAGE")"
  SQL_COPY_DIR="$SQL_DIR"
  if command -v cygpath >/dev/null 2>&1;then SQL_COPY_DIR="$(cygpath -w "$SQL_DIR")";fi
  docker cp "$EXTRACT_CONTAINER:/app/apps/backend/sql/." "$SQL_COPY_DIR" >/dev/null
  docker rm "$EXTRACT_CONTAINER" >/dev/null
  EXTRACT_CONTAINER=""
  BASELINE_SCHEMA="$SQL_DIR/phase1_schema.sql"
  MIGRATIONS_DIR="$SQL_DIR/migrations"
  SOURCE_IMAGE=""
fi
migration_files="$(list_migration_files)"
{
  printf '%s\n' "set lock_timeout='30s';" "set statement_timeout='300s';" "select pg_advisory_lock(2740082);" \
    "create table if not exists schema_migrations(version varchar(255) primary key,applied_at timestamptz not null default now());"
  printf '%s\n' "select to_regclass('tasks') is not null as baseline_exists \\gset" '\if :baseline_exists' '\else' 'begin;'
  load_baseline_sql > "$PLAN_FILE.part"
  LC_ALL=C sed '1s/^\xEF\xBB\xBF//' "$PLAN_FILE.part"
  printf '%s\n' "insert into schema_migrations(version) values('0000_phase1_schema') on conflict do nothing;" 'commit;' '\endif'
  for v in $migration_files; do
    case "$v" in *[!A-Za-z0-9_.-]*) echo 'Invalid migration filename' >&2;exit 1;; esac
    printf '%s\n' "select exists(select 1 from schema_migrations where version='$v') as migration_applied \\gset" '\if :migration_applied' '\else' 'begin;' "set local lock_timeout='5s';" "set local statement_timeout='300s';"
    printf '%s\n' "\echo db_migrate: apply $v"
    # All current migrations use ordinary transactional DDL. A future concurrent
    # index migration requires a separate explicit, validity-checked runner.
    load_migration_sql "$v" > "$PLAN_FILE.part"
    LC_ALL=C sed '1s/^\xEF\xBB\xBF//' "$PLAN_FILE.part"
    printf '\n%s\n' "insert into schema_migrations(version) values('$v');" 'commit;' '\endif'
  done
  printf '%s\n' 'select pg_advisory_unlock(2740082);'
} > "$PLAN_FILE"
run_psql_stdin < "$PLAN_FILE"
echo "db_migrate: done"
