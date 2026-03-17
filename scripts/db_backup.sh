#!/bin/sh
set -eu

COMPOSE_FILE="${1:-deploy/docker-compose.prod.yml}"
ENV_FILE="${2:-.env.prod}"
BACKUP_ROOT="${BACKUP_ROOT:-apps/backend/data/backups}"
KEEP_COUNT="${BACKUP_KEEP_COUNT:-10}"

if [ ! -f "$ENV_FILE" ]; then
  echo "env file not found: $ENV_FILE"
  exit 1
fi

set -a
. "./$ENV_FILE"
set +a

mkdir -p "$BACKUP_ROOT/postgres" "$BACKUP_ROOT/files"
TS="$(date +%Y%m%d_%H%M%S)"

if [ "${STORAGE_MODE:-postgres}" = "postgres" ]; then
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d postgres >/dev/null
  READY=false
  i=0
  while [ $i -lt 60 ]; do
    if docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T postgres \
      pg_isready -U "${POSTGRES_USER:-bb}" -d "${POSTGRES_DB:-bbexchange}" >/dev/null 2>&1; then
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
  echo "db_backup: postgres dump..."
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T postgres \
    sh -lc "pg_dump -U '${POSTGRES_USER:-bb}' -d '${POSTGRES_DB:-bbexchange}' -Fc" \
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
