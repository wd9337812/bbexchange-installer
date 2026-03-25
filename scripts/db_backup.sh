#!/bin/sh
set -eu

COMPOSE_FILE="${1:-deploy/docker-compose.prod.yml}"
ENV_FILE="${2:-.env.prod}"
BACKUP_ROOT="${BACKUP_ROOT:-apps/backend/data/backups}"
KEEP_COUNT="${BACKUP_KEEP_COUNT:-10}"
POSTGRES_SERVICE="${POSTGRES_SERVICE:-postgres}"

if [ ! -f "$ENV_FILE" ]; then
  echo "env file not found: $ENV_FILE"
  exit 1
fi

set -a
. "./$ENV_FILE"
set +a

SERVICES="$(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config --services 2>/dev/null || true)"
if ! printf '%s\n' "$SERVICES" | grep -qx "$POSTGRES_SERVICE"; then
  if printf '%s\n' "$SERVICES" | grep -qx "postgres_admin"; then
    POSTGRES_SERVICE="postgres_admin"
  fi
fi

mkdir -p "$BACKUP_ROOT/postgres" "$BACKUP_ROOT/files"
TS="$(date +%Y%m%d_%H%M%S)"

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

  echo "db_backup: app db credential mismatch detected, repairing role/db mapping..."
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T "$POSTGRES_SERVICE" \
    psql -v ON_ERROR_STOP=1 -U postgres -d postgres <<EOF >/dev/null
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
}

if [ "${STORAGE_MODE:-postgres}" = "postgres" ]; then
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d "$POSTGRES_SERVICE" >/dev/null
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
    echo "db_backup: postgres is not ready"
    exit 1
  fi
  ensure_app_identity
  echo "db_backup: postgres dump..."
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T "$POSTGRES_SERVICE" \
    sh -lc "PGPASSWORD='${POSTGRES_PASSWORD:-bb_change_me}' pg_dump -h 127.0.0.1 -U '${POSTGRES_USER:-bb}' -d '${POSTGRES_DB:-bbexchange}' -Fc" \
    > "$BACKUP_ROOT/postgres/pg_${TS}.dump"
fi

echo "db_backup: file snapshot..."
tar -czf "$BACKUP_ROOT/files/data_${TS}.tar.gz" \
  --exclude='apps/backend/data/backups' \
  apps/backend/data >/dev/null 2>&1 || true

trim_keep() {
  dir="$1"
  pattern="$2"
  ls -1t "$dir"/$pattern 2>/dev/null | awk "NR>${KEEP_COUNT}" | while read -r x; do
    rm -f "$x"
  done
}

trim_keep "$BACKUP_ROOT/postgres" "pg_*.dump"
trim_keep "$BACKUP_ROOT/files" "data_*.tar.gz"

echo "db_backup: done"
