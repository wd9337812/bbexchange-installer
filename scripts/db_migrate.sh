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
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T "$POSTGRES_SERVICE" \
    psql -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null
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

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d "$POSTGRES_SERVICE"

echo "db_migrate: waiting postgres..."
READY=false
i=0
while [ $i -lt 60 ]; do
  if docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T "$POSTGRES_SERVICE" \
    pg_isready -U postgres -d postgres >/dev/null 2>&1; then
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
run_psql_cmd "create table if not exists schema_migrations (version varchar(255) primary key, applied_at timestamptz not null default now());"

TASK_EXISTS="$(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T "$POSTGRES_SERVICE" \
  sh -lc "PGPASSWORD='${POSTGRES_PASSWORD:-bb_change_me}' psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U '${POSTGRES_USER:-bb}' -d '${POSTGRES_DB:-bbexchange}' -tAc \"select 1 from pg_tables where schemaname='public' and tablename='tasks' limit 1;\"" | tr -d '[:space:]')"

if [ "$TASK_EXISTS" != "1" ]; then
  echo "db_migrate: applying baseline schema..."
  load_baseline_sql | run_psql_stdin
  run_psql_cmd "insert into schema_migrations(version) values('0000_phase1_schema') on conflict do nothing;"
fi

for v in $(list_migration_files); do
    applied="$(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T "$POSTGRES_SERVICE" \
      sh -lc "PGPASSWORD='${POSTGRES_PASSWORD:-bb_change_me}' psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U '${POSTGRES_USER:-bb}' -d '${POSTGRES_DB:-bbexchange}' -tAc \"select 1 from schema_migrations where version='${v}' limit 1;\"" | tr -d '[:space:]')"
    if [ "$applied" = "1" ]; then
      echo "db_migrate: skip $v"
      continue
    fi
    echo "db_migrate: apply $v"
    load_migration_sql "$v" | run_psql_stdin
    run_psql_cmd "insert into schema_migrations(version) values('${v}');"
done

echo "db_migrate: done"
