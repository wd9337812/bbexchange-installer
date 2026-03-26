#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root (use: sudo bash install_vps.sh ...)"
  exit 1
fi

INSTALL_DIR="${INSTALL_DIR:-/opt/brandbidding}"
IMAGE_REGISTRY="${IMAGE_REGISTRY:-ghcr.io/wd9337812}"
API_IMAGE="${API_IMAGE:-bbexchange-api}"
WORKER_IMAGE="${WORKER_IMAGE:-bbexchange-worker}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
UPDATE_CHANNEL_TAG="${UPDATE_CHANNEL_TAG:-latest}"
SSL_MODE="${SSL_MODE:-auto}"
DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
ENABLE_BROWSER="${ENABLE_BROWSER:-true}"
STORAGE_MODE="${STORAGE_MODE:-postgres}"
REGISTRY_USER="${REGISTRY_USER:-}"
REGISTRY_TOKEN="${REGISTRY_TOKEN:-}"
CONTROL_PLANE_BASE_URL="${CONTROL_PLANE_BASE_URL:-}"
CONTROL_PLANE_SHARED_KEY="${CONTROL_PLANE_SHARED_KEY:-}"

to_lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

usage() {
  cat <<EOF
Usage:
  bash install_vps.sh [options]

Options:
  --install-dir <path>         Install directory (default: ${INSTALL_DIR})
  --image-registry <value>     Image registry/repo prefix (default: ${IMAGE_REGISTRY})
  --api-image <name>           API image name (default: ${API_IMAGE})
  --worker-image <name>        Worker image name (default: ${WORKER_IMAGE})
  --image-tag <tag>            Deploy image tag (default: ${IMAGE_TAG})
  --update-channel-tag <tag>   Update check channel tag (default: ${UPDATE_CHANNEL_TAG})
  --ssl <on|off|auto>          SSL mode (default: ${SSL_MODE})
  --domain <domain>            Domain for SSL mode
  --email <email>              Let's Encrypt email
  --enable-browser <true|false> Enable browser execution (default: ${ENABLE_BROWSER})
  --storage <postgres|file>    Storage mode (default: ${STORAGE_MODE})
  --control-plane-url <url>    Control-plane base url (default: ${CONTROL_PLANE_BASE_URL})
  --control-plane-key <key>    Control-plane shared key
  --registry-user <username>   Optional registry username
  --registry-token <token>     Optional registry token/password
  -h, --help                   Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --image-registry) IMAGE_REGISTRY="$2"; shift 2 ;;
    --api-image) API_IMAGE="$2"; shift 2 ;;
    --worker-image) WORKER_IMAGE="$2"; shift 2 ;;
    --image-tag) IMAGE_TAG="$2"; shift 2 ;;
    --update-channel-tag) UPDATE_CHANNEL_TAG="$2"; shift 2 ;;
    --ssl) SSL_MODE="$2"; shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --enable-browser) ENABLE_BROWSER="$2"; shift 2 ;;
    --storage) STORAGE_MODE="$2"; shift 2 ;;
    --control-plane-url) CONTROL_PLANE_BASE_URL="$2"; shift 2 ;;
    --control-plane-key) CONTROL_PLANE_SHARED_KEY="$2"; shift 2 ;;
    --registry-user) REGISTRY_USER="$2"; shift 2 ;;
    --registry-token) REGISTRY_TOKEN="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

SSL_MODE="$(to_lower "${SSL_MODE}")"
ENABLE_BROWSER="$(to_lower "${ENABLE_BROWSER}")"
STORAGE_MODE="$(to_lower "${STORAGE_MODE}")"

if [[ "${SSL_MODE}" != "on" && "${SSL_MODE}" != "off" && "${SSL_MODE}" != "auto" ]]; then
  echo "Invalid --ssl value: ${SSL_MODE}. Use on|off|auto."
  exit 1
fi
if [[ "${ENABLE_BROWSER}" != "true" && "${ENABLE_BROWSER}" != "false" ]]; then
  echo "Invalid --enable-browser value: ${ENABLE_BROWSER}. Use true|false."
  exit 1
fi
if [[ "${STORAGE_MODE}" != "postgres" && "${STORAGE_MODE}" != "file" ]]; then
  echo "Invalid --storage value: ${STORAGE_MODE}. Use postgres|file."
  exit 1
fi

if [[ -z "${DOMAIN}" && "${SSL_MODE}" == "auto" ]]; then
  echo "Deploy mode:"
  echo "  1) Domain + Auto SSL (Let's Encrypt, recommended)"
  echo "  2) HTTP only (no domain / no SSL)"
  read -rp "Choose [1/2] (default 1): " MODE_CHOICE
  MODE_CHOICE="${MODE_CHOICE:-1}"
  if [[ "${MODE_CHOICE}" == "2" ]]; then
    SSL_MODE="off"
  else
    SSL_MODE="on"
  fi
fi

if [[ "${SSL_MODE}" == "on" || "${SSL_MODE}" == "auto" ]]; then
  if [[ -z "${DOMAIN}" ]]; then
    read -rp "Input domain (e.g. app.example.com): " DOMAIN
  fi
  if [[ ! "${DOMAIN}" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    echo "Invalid domain: ${DOMAIN}"
    exit 1
  fi
  if [[ -z "${EMAIL}" ]]; then
    read -rp "Input email for Let's Encrypt (Enter to auto-generate): " EMAIL
  fi
  if [[ -z "${EMAIL}" ]]; then
    EMAIL="admin@${DOMAIN}"
  fi
else
  EMAIL=""
fi

if [[ -z "${CONTROL_PLANE_BASE_URL}" ]]; then
  read -rp "Input control-plane license URL (e.g. https://license.bbauto.top): " CONTROL_PLANE_BASE_URL
fi
if [[ -z "${CONTROL_PLANE_SHARED_KEY}" ]]; then
  read -rp "Input control-plane shared key: " CONTROL_PLANE_SHARED_KEY
fi
if [[ -z "${CONTROL_PLANE_BASE_URL}" || -z "${CONTROL_PLANE_SHARED_KEY}" ]]; then
  echo "CONTROL_PLANE_BASE_URL and CONTROL_PLANE_SHARED_KEY are required."
  exit 1
fi

echo "[1/7] Installing runtime dependencies..."
apt-get update -y
apt-get install -y ca-certificates curl openssl tar

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
fi

if ! docker compose version >/dev/null 2>&1; then
  if apt-get install -y docker-compose-plugin; then
    :
  fi
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose plugin is not available after installation."
  exit 1
fi

echo "[2/7] Preparing deployment directory..."
mkdir -p "${INSTALL_DIR}/deploy" "${INSTALL_DIR}/scripts" "${INSTALL_DIR}/apps/backend/data" "${INSTALL_DIR}/apps/backend/sql/migrations"
cd "${INSTALL_DIR}"

echo "[3/7] Writing compose and helper scripts..."
cat > deploy/docker-compose.image.yml <<'EOF'
services:
  redis:
    image: redis:7-alpine
    container_name: bbexchange-redis
    restart: unless-stopped
    environment:
      - TZ=${TZ:-Asia/Shanghai}
    volumes:
      - redis_data:/data

  postgres:
    image: postgres:16-alpine
    container_name: bbexchange-postgres
    restart: unless-stopped
    command: ["postgres", "-c", "timezone=Asia/Shanghai"]
    environment:
      - POSTGRES_USER=${POSTGRES_USER:-bb}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-bb_change_me}
      - POSTGRES_DB=${POSTGRES_DB:-bbexchange}
      - TZ=${TZ:-Asia/Shanghai}
      - PGTZ=${TZ:-Asia/Shanghai}
    volumes:
      - pg_data:/var/lib/postgresql/data

  api:
    image: ${IMAGE_REGISTRY:-ghcr.io/wd9337812}/${API_IMAGE:-bbexchange-api}:${IMAGE_TAG:-latest}
    container_name: bbexchange-api
    restart: unless-stopped
    environment:
      - NODE_ENV=${NODE_ENV:-production}
      - PORT=3000
      - TZ=${TZ:-Asia/Shanghai}
      - APP_TIMEZONE=${APP_TIMEZONE:-Asia/Shanghai}
      - REDIS_URL=redis://redis:6379
      - STORAGE_MODE=${STORAGE_MODE:-postgres}
      - DATABASE_URL=postgres://${POSTGRES_USER:-bb}:${POSTGRES_PASSWORD:-bb_change_me}@postgres:5432/${POSTGRES_DB:-bbexchange}
      - ENABLE_BROWSER_EXECUTION=${ENABLE_BROWSER_EXECUTION:-false}
      - TENANT_CODE=${TENANT_CODE:-local}
      - AUTH_SECRET=${AUTH_SECRET}
      - CREDENTIAL_SECRET=${CREDENTIAL_SECRET}
      - APP_SERVER_MODE=${APP_SERVER_MODE:-user}
      - CONTROL_PLANE_BASE_URL=${CONTROL_PLANE_BASE_URL}
      - CONTROL_PLANE_SHARED_KEY=${CONTROL_PLANE_SHARED_KEY}
      - CONTROL_PLANE_TIMEOUT_MS=${CONTROL_PLANE_TIMEOUT_MS:-8000}
      - SELF_UPDATE_ENABLED=${SELF_UPDATE_ENABLED:-false}
      - SELF_UPDATE_MODE=${SELF_UPDATE_MODE:-manual_image_ops}
      - SELF_UPDATE_REPO_DIR=${SELF_UPDATE_REPO_DIR:-/workspace}
      - SELF_UPDATE_HOST_REPO_DIR=${SELF_UPDATE_HOST_REPO_DIR:-/opt/brandbidding}
      - SELF_UPDATE_IMAGE_COMPOSE_FILE=${SELF_UPDATE_IMAGE_COMPOSE_FILE:-deploy/docker-compose.image.yml}
      - SELF_UPDATE_IMAGE_CHANNEL_TAG=${SELF_UPDATE_IMAGE_CHANNEL_TAG:-latest}
      - SELF_UPDATE_HELPER_IMAGE=${SELF_UPDATE_HELPER_IMAGE:-docker:27-cli}
    volumes:
      - ../apps/backend/data:/app/apps/backend/data
      - ..:/workspace
      - /var/run/docker.sock:/var/run/docker.sock
    depends_on:
      - redis
      - postgres

  worker:
    image: ${IMAGE_REGISTRY:-ghcr.io/wd9337812}/${WORKER_IMAGE:-bbexchange-worker}:${IMAGE_TAG:-latest}
    container_name: bbexchange-worker
    restart: unless-stopped
    environment:
      - NODE_ENV=${NODE_ENV:-production}
      - TZ=${TZ:-Asia/Shanghai}
      - APP_TIMEZONE=${APP_TIMEZONE:-Asia/Shanghai}
      - REDIS_URL=redis://redis:6379
      - STORAGE_MODE=${STORAGE_MODE:-postgres}
      - DATABASE_URL=postgres://${POSTGRES_USER:-bb}:${POSTGRES_PASSWORD:-bb_change_me}@postgres:5432/${POSTGRES_DB:-bbexchange}
      - ENABLE_BROWSER_EXECUTION=${ENABLE_BROWSER_EXECUTION:-false}
      - TENANT_CODE=${TENANT_CODE:-local}
      - BROWSER_POOL_SIZE=${BROWSER_POOL_SIZE:-4}
      - OFFER_NAV_TIMEOUT_MS=${OFFER_NAV_TIMEOUT_MS:-20000}
      - CHROMIUM_EXECUTABLE_PATH=${CHROMIUM_EXECUTABLE_PATH:-/usr/bin/chromium-browser}
      - AUTH_SECRET=${AUTH_SECRET}
      - CREDENTIAL_SECRET=${CREDENTIAL_SECRET}
    volumes:
      - ../apps/backend/data:/app/apps/backend/data
    depends_on:
      - redis
      - postgres

  caddy:
    image: caddy:2
    container_name: bbexchange-caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - api

volumes:
  redis_data:
  pg_data:
  caddy_data:
  caddy_config:
EOF

cat > scripts/db_migrate.sh <<'EOF'
#!/bin/sh
set -eu

COMPOSE_FILE="${1:-deploy/docker-compose.image.yml}"
ENV_FILE="${2:-.env.prod}"
MIGRATIONS_DIR="${MIGRATIONS_DIR:-apps/backend/sql/migrations}"
BASELINE_SCHEMA="${BASELINE_SCHEMA:-apps/backend/sql/phase1_schema.sql}"
SOURCE_IMAGE="${SOURCE_IMAGE:-}"
SOURCE_BASELINE_SCHEMA="${SOURCE_BASELINE_SCHEMA:-/app/apps/backend/sql/phase1_schema.sql}"
SOURCE_MIGRATIONS_DIR="${SOURCE_MIGRATIONS_DIR:-/app/apps/backend/sql/migrations}"

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

run_psql_stdin() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T postgres \
    psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-bb}" -d "${POSTGRES_DB:-bbexchange}" >/dev/null
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

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d postgres

echo "db_migrate: waiting postgres..."
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
  echo "db_migrate: postgres is not ready"
  exit 1
fi

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T postgres \
  psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-bb}" -d "${POSTGRES_DB:-bbexchange}" \
  -c "create table if not exists schema_migrations (version varchar(255) primary key, applied_at timestamptz not null default now());" >/dev/null

TASK_EXISTS="$(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T postgres \
  psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-bb}" -d "${POSTGRES_DB:-bbexchange}" -tAc \
  "select 1 from pg_tables where schemaname='public' and tablename='tasks' limit 1;" | tr -d '[:space:]')"

if [ "$TASK_EXISTS" != "1" ]; then
  echo "db_migrate: applying baseline schema..."
  load_baseline_sql | run_psql_stdin
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T postgres \
    psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-bb}" -d "${POSTGRES_DB:-bbexchange}" \
    -c "insert into schema_migrations(version) values('0000_phase1_schema') on conflict do nothing;" >/dev/null
fi

for v in $(list_migration_files); do
  applied="$(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T postgres \
    psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-bb}" -d "${POSTGRES_DB:-bbexchange}" -tAc \
    "select 1 from schema_migrations where version='${v}' limit 1;" | tr -d '[:space:]')"
  if [ "$applied" = "1" ]; then
    echo "db_migrate: skip $v"
    continue
  fi
  echo "db_migrate: apply $v"
  load_migration_sql "$v" | run_psql_stdin
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T postgres \
    psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-bb}" -d "${POSTGRES_DB:-bbexchange}" \
    -c "insert into schema_migrations(version) values('${v}');" >/dev/null
done

echo "db_migrate: done"
EOF

cat > scripts/db_backup.sh <<'EOF'
#!/bin/sh
set -eu

COMPOSE_FILE="${1:-deploy/docker-compose.image.yml}"
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
EOF

cat > scripts/update_image.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

TARGET_TAG="${1:-}"
COMPOSE_FILE="${COMPOSE_FILE:-deploy/docker-compose.image.yml}"
ENV_FILE="${ENV_FILE:-.env.prod}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAST_TAG_FILE="${REPO_DIR}/apps/backend/data/last_good_image_tag.txt"

cd "${REPO_DIR}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "env file not found: ${ENV_FILE}"
  exit 1
fi

get_env_var() {
  local key="$1"
  sed -n "s/^${key}=//p" "${ENV_FILE}" | head -n 1
}

require_control_plane_for_user_mode() {
  local mode cp_url cp_key tenant_code
  mode="$(get_env_var APP_SERVER_MODE)"
  mode="${mode:-user}"
  if [[ "${mode}" != "user" ]]; then
    return 0
  fi
  cp_url="$(get_env_var CONTROL_PLANE_BASE_URL)"
  cp_key="$(get_env_var CONTROL_PLANE_SHARED_KEY)"
  tenant_code="$(get_env_var TENANT_CODE)"
  tenant_code="${tenant_code:-local}"

  if [[ -z "${cp_url}" || -z "${cp_key}" ]]; then
    echo "[update] ERROR: user mode requires CONTROL_PLANE_BASE_URL and CONTROL_PLANE_SHARED_KEY in ${ENV_FILE}"
    exit 31
  fi

  if [[ "${SKIP_CONTROL_PLANE_CHECK:-false}" == "true" ]]; then
    echo "[update] WARN: skip control-plane connectivity check (SKIP_CONTROL_PLANE_CHECK=true)"
    return 0
  fi

  local probe_url code body
  probe_url="${cp_url%/}/api/internal/subscription/current?tenantCode=${tenant_code}"
  body="$(mktemp)"
  code="$(curl -sS -m 12 -o "${body}" -w "%{http_code}" \
    -H "X-Control-Plane-Key: ${cp_key}" \
    -H "X-Tenant-Code: ${tenant_code}" \
    "${probe_url}" || true)"
  if [[ "${code}" != "200" ]]; then
    echo "[update] ERROR: control plane probe failed, code=${code}, url=${probe_url}"
    echo "[update] response: $(head -c 300 "${body}" 2>/dev/null || true)"
    rm -f "${body}" >/dev/null 2>&1 || true
    exit 32
  fi
  rm -f "${body}" >/dev/null 2>&1 || true
}

ensure_env_var() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" "${ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}"
  else
    echo "${key}=${value}" >> "${ENV_FILE}"
  fi
}

ensure_env_var "TZ" "Asia/Shanghai"
ensure_env_var "APP_TIMEZONE" "Asia/Shanghai"
ensure_env_var "NODE_ENV" "production"
require_control_plane_for_user_mode

if [[ -z "${TARGET_TAG}" ]]; then
  TARGET_TAG="$(sed -n 's/^SELF_UPDATE_IMAGE_CHANNEL_TAG=//p' "${ENV_FILE}" | head -n 1)"
  TARGET_TAG="${TARGET_TAG:-latest}"
fi

IMAGE_REGISTRY="$(sed -n 's/^IMAGE_REGISTRY=//p' "${ENV_FILE}" | head -n 1)"
API_IMAGE_NAME="$(sed -n 's/^API_IMAGE=//p' "${ENV_FILE}" | head -n 1)"
WORKER_IMAGE_NAME="$(sed -n 's/^WORKER_IMAGE=//p' "${ENV_FILE}" | head -n 1)"
IMAGE_REGISTRY="${IMAGE_REGISTRY:-ghcr.io/wd9337812}"
API_IMAGE_NAME="${API_IMAGE_NAME:-bbexchange-api}"
WORKER_IMAGE_NAME="${WORKER_IMAGE_NAME:-bbexchange-worker}"
API_IMAGE_REF="${IMAGE_REGISTRY}/${API_IMAGE_NAME}:${TARGET_TAG}"
WORKER_IMAGE_REF="${IMAGE_REGISTRY}/${WORKER_IMAGE_NAME}:${TARGET_TAG}"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is not installed"
  exit 1
fi

mkdir -p apps/backend/data
CURRENT_TAG="$(sed -n 's/^IMAGE_TAG=//p' "${ENV_FILE}" | head -n 1)"
if [[ -n "${CURRENT_TAG}" ]]; then
  echo "${CURRENT_TAG}" > "${LAST_TAG_FILE}"
fi

before_api_id="$(docker image inspect "${API_IMAGE_REF}" --format '{{.Id}}' 2>/dev/null || true)"
before_worker_id="$(docker image inspect "${WORKER_IMAGE_REF}" --format '{{.Id}}' 2>/dev/null || true)"

echo "[update] backup database/files..."
bash scripts/db_backup.sh "${COMPOSE_FILE}" "${ENV_FILE}"

if grep -q '^IMAGE_TAG=' "${ENV_FILE}"; then
  sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=${TARGET_TAG}/" "${ENV_FILE}"
else
  echo "IMAGE_TAG=${TARGET_TAG}" >> "${ENV_FILE}"
fi

echo "[update] pull images: ${TARGET_TAG}"
docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" pull api worker

after_api_id="$(docker image inspect "${API_IMAGE_REF}" --format '{{.Id}}' 2>/dev/null || true)"
after_worker_id="$(docker image inspect "${WORKER_IMAGE_REF}" --format '{{.Id}}' 2>/dev/null || true)"

if [[ "${TARGET_TAG}" == "latest" && -n "${before_api_id}" && -n "${after_api_id}" && "${before_api_id}" == "${after_api_id}" && -n "${before_worker_id}" && -n "${after_worker_id}" && "${before_worker_id}" == "${after_worker_id}" ]]; then
  echo "[update] no new image pulled for tag 'latest'. Build may still be running or latest has not changed."
  echo "[update] current api image id: ${after_api_id}"
  echo "[update] current worker image id: ${after_worker_id}"
  exit 2
fi

echo "[update] migrate schema from image: ${API_IMAGE_REF}"
SOURCE_IMAGE="${API_IMAGE_REF}" bash scripts/db_migrate.sh "${COMPOSE_FILE}" "${ENV_FILE}"

echo "[update] restart services"
docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" up -d api worker caddy

echo "[update] health check"
curl -fsS --max-time 10 http://127.0.0.1/api/health >/dev/null

echo "[update] success: IMAGE_TAG=${TARGET_TAG}"
EOF

cat > scripts/rollback_image.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

TARGET_TAG="${1:-}"
COMPOSE_FILE="${COMPOSE_FILE:-deploy/docker-compose.image.yml}"
ENV_FILE="${ENV_FILE:-.env.prod}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAST_TAG_FILE="${REPO_DIR}/apps/backend/data/last_good_image_tag.txt"

cd "${REPO_DIR}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "env file not found: ${ENV_FILE}"
  exit 1
fi

if [[ -z "${TARGET_TAG}" && -f "${LAST_TAG_FILE}" ]]; then
  TARGET_TAG="$(cat "${LAST_TAG_FILE}")"
fi

if [[ -z "${TARGET_TAG}" ]]; then
  echo "Usage: bash scripts/rollback_image.sh <last_good_tag>"
  echo "No fallback tag found in ${LAST_TAG_FILE}"
  exit 1
fi

if grep -q '^IMAGE_TAG=' "${ENV_FILE}"; then
  sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=${TARGET_TAG}/" "${ENV_FILE}"
else
  echo "IMAGE_TAG=${TARGET_TAG}" >> "${ENV_FILE}"
fi

docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" pull api worker
docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" up -d api worker caddy
curl -fsS --max-time 10 http://127.0.0.1/api/health >/dev/null
echo "[rollback] success: IMAGE_TAG=${TARGET_TAG}"
EOF

chmod +x scripts/db_migrate.sh scripts/db_backup.sh scripts/update_image.sh scripts/rollback_image.sh

if [[ ! -f ".env.prod" ]]; then
  TENANT_CODE_VALUE="tenant-$(openssl rand -hex 6)"
  cat > .env.prod <<EOF
POSTGRES_USER=bb
POSTGRES_PASSWORD=$(openssl rand -hex 16)
POSTGRES_DB=bbexchange
STORAGE_MODE=${STORAGE_MODE}
ENABLE_BROWSER_EXECUTION=${ENABLE_BROWSER}
TZ=Asia/Shanghai
APP_TIMEZONE=Asia/Shanghai
NODE_ENV=production
AUTH_SECRET=$(openssl rand -hex 32)
CREDENTIAL_SECRET=$(openssl rand -hex 32)
TENANT_CODE=${TENANT_CODE_VALUE}
APP_SERVER_MODE=user
CONTROL_PLANE_BASE_URL=${CONTROL_PLANE_BASE_URL}
CONTROL_PLANE_SHARED_KEY=${CONTROL_PLANE_SHARED_KEY}
CONTROL_PLANE_TIMEOUT_MS=8000
IMAGE_REGISTRY=${IMAGE_REGISTRY}
API_IMAGE=${API_IMAGE}
WORKER_IMAGE=${WORKER_IMAGE}
IMAGE_TAG=${IMAGE_TAG}
SELF_UPDATE_ENABLED=false
SELF_UPDATE_MODE=manual_image_ops
SELF_UPDATE_REPO_DIR=/workspace
SELF_UPDATE_HOST_REPO_DIR=${TARGET_DIR}
SELF_UPDATE_IMAGE_COMPOSE_FILE=deploy/docker-compose.image.yml
SELF_UPDATE_IMAGE_CHANNEL_TAG=${UPDATE_CHANNEL_TAG}
SELF_UPDATE_HELPER_IMAGE=docker:27-cli
SELF_UPDATE_INSTALLER_RAW_BASE=https://raw.githubusercontent.com/wd9337812/bbexchange-installer/main
EOF
fi

ensure_env_var() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" .env.prod; then
    sed -i "s|^${key}=.*|${key}=${value}|" .env.prod
  else
    echo "${key}=${value}" >> .env.prod
  fi
}

ensure_env_var_if_missing() {
  local key="$1"
  local value="$2"
  local current
  current="$(sed -n "s/^${key}=//p" .env.prod | head -n 1)"
  if [[ -z "${current}" ]]; then
    ensure_env_var "${key}" "${value}"
  fi
}

ensure_secret_var() {
  local key="$1"
  local current
  current="$(sed -n "s/^${key}=//p" .env.prod | head -n 1)"
  if [[ -z "${current}" ]]; then
    if grep -q "^${key}=" .env.prod; then
      sed -i "s/^${key}=.*/${key}=$(openssl rand -hex 32)/" .env.prod
    else
      echo "${key}=$(openssl rand -hex 32)" >> .env.prod
    fi
  fi
}

ensure_env_var "IMAGE_REGISTRY" "${IMAGE_REGISTRY}"
ensure_env_var "API_IMAGE" "${API_IMAGE}"
ensure_env_var "WORKER_IMAGE" "${WORKER_IMAGE}"
ensure_env_var "IMAGE_TAG" "${IMAGE_TAG}"
ensure_env_var "STORAGE_MODE" "${STORAGE_MODE}"
ensure_env_var "ENABLE_BROWSER_EXECUTION" "${ENABLE_BROWSER}"
ensure_env_var "TZ" "Asia/Shanghai"
ensure_env_var "APP_TIMEZONE" "Asia/Shanghai"
ensure_env_var "NODE_ENV" "production"
ensure_env_var_if_missing "TENANT_CODE" "tenant-$(openssl rand -hex 6)"
ensure_env_var "APP_SERVER_MODE" "user"
ensure_env_var "CONTROL_PLANE_BASE_URL" "${CONTROL_PLANE_BASE_URL}"
ensure_env_var "CONTROL_PLANE_SHARED_KEY" "${CONTROL_PLANE_SHARED_KEY}"
ensure_env_var "CONTROL_PLANE_TIMEOUT_MS" "8000"
ensure_env_var "SELF_UPDATE_ENABLED" "false"
ensure_env_var "SELF_UPDATE_MODE" "manual_image_ops"
ensure_env_var "SELF_UPDATE_REPO_DIR" "/workspace"
ensure_env_var "SELF_UPDATE_HOST_REPO_DIR" "${TARGET_DIR}"
ensure_env_var "SELF_UPDATE_IMAGE_COMPOSE_FILE" "deploy/docker-compose.image.yml"
ensure_env_var "SELF_UPDATE_IMAGE_CHANNEL_TAG" "${UPDATE_CHANNEL_TAG}"
ensure_env_var "SELF_UPDATE_HELPER_IMAGE" "docker:27-cli"
ensure_env_var "SELF_UPDATE_INSTALLER_RAW_BASE" "https://raw.githubusercontent.com/wd9337812/bbexchange-installer/main"
ensure_secret_var "AUTH_SECRET"
ensure_secret_var "CREDENTIAL_SECRET"

echo "[4/7] Writing Caddy config..."
if [[ "${SSL_MODE}" == "on" || "${SSL_MODE}" == "auto" ]]; then
  cat > deploy/Caddyfile <<EOF
{
  email ${EMAIL}
}

${DOMAIN} {
  encode gzip
  reverse_proxy api:3000
}
EOF
else
  cat > deploy/Caddyfile <<'EOF'
:80 {
  encode gzip
  reverse_proxy api:3000
}
EOF
fi

echo "[5/7] Optional registry login..."
if [[ -n "${REGISTRY_USER}" && -n "${REGISTRY_TOKEN}" ]]; then
  REGISTRY_HOST="$(echo "${IMAGE_REGISTRY}" | cut -d'/' -f1)"
  echo "${REGISTRY_TOKEN}" | docker login "${REGISTRY_HOST}" -u "${REGISTRY_USER}" --password-stdin
fi

echo "[6/7] Pulling images and applying DB schema..."
docker compose --env-file .env.prod -f deploy/docker-compose.image.yml up -d redis postgres

docker compose --env-file .env.prod -f deploy/docker-compose.image.yml pull api worker
API_REF="${IMAGE_REGISTRY}/${API_IMAGE}:${IMAGE_TAG}"
TMP_CID="$(docker create "${API_REF}" sh -lc 'sleep 10')"
docker cp "${TMP_CID}:/app/apps/backend/sql/." "${INSTALL_DIR}/apps/backend/sql/"
docker rm -f "${TMP_CID}" >/dev/null

sh scripts/db_migrate.sh deploy/docker-compose.image.yml .env.prod

echo "[7/7] Starting services and health check..."
docker compose --env-file .env.prod -f deploy/docker-compose.image.yml up -d api worker caddy
sleep 3
curl -fsS http://127.0.0.1/api/health

TENANT_CODE_VALUE="$(sed -n 's/^TENANT_CODE=//p' .env.prod | head -n 1)"
PROBE_URL="${CONTROL_PLANE_BASE_URL%/}/api/internal/subscription/current?tenantCode=${TENANT_CODE_VALUE}"
PROBE_BODY="$(mktemp)"
PROBE_CODE="$(curl -sS -m 12 -o "${PROBE_BODY}" -w "%{http_code}" \
  -H "X-Control-Plane-Key: ${CONTROL_PLANE_SHARED_KEY}" \
  -H "X-Tenant-Code: ${TENANT_CODE_VALUE}" \
  "${PROBE_URL}" || true)"
if [[ "${PROBE_CODE}" != "200" ]]; then
  echo "Control-plane probe failed (code=${PROBE_CODE}): ${PROBE_URL}"
  echo "Response: $(head -c 300 "${PROBE_BODY}" 2>/dev/null || true)"
  rm -f "${PROBE_BODY}" >/dev/null 2>&1 || true
  exit 1
fi
rm -f "${PROBE_BODY}" >/dev/null 2>&1 || true

echo ""
echo "Install complete."
echo "Status: docker compose --env-file .env.prod -f deploy/docker-compose.image.yml ps"
if [[ "${SSL_MODE}" == "on" || "${SSL_MODE}" == "auto" ]]; then
  echo "URL: https://${DOMAIN}"
else
  echo "URL: http://<YOUR_VPS_PUBLIC_IP>"
fi
