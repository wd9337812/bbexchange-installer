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
IMAGE_TAG="${IMAGE_TAG:-}"
UPDATE_CHANNEL_TAG="${UPDATE_CHANNEL_TAG:-}"
UPDATE_CHANNEL_NAME="${UPDATE_CHANNEL_NAME:-stable}"
UPDATE_CHANNEL_BASE="${UPDATE_CHANNEL_BASE:-https://raw.githubusercontent.com/wd9337812/bbexchange-installer/main/release-channel}"
SSL_MODE="${SSL_MODE:-auto}"
DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
ENABLE_BROWSER="${ENABLE_BROWSER:-true}"
STORAGE_MODE="${STORAGE_MODE:-postgres}"
REGISTRY_USER="${REGISTRY_USER:-}"
REGISTRY_TOKEN="${REGISTRY_TOKEN:-}"
CONTROL_PLANE_BASE_URL="${CONTROL_PLANE_BASE_URL:-https://license.bbauto.top}"
# Default shared key for user-side installer. Can still be overridden by --control-plane-key.
CONTROL_PLANE_SHARED_KEY="${CONTROL_PLANE_SHARED_KEY:-${BBAUTO_CONTROL_PLANE_SHARED_KEY:-5854108fc0c998e0eb08ddca706036bb91e289986abd055d300871582f41f014}}"

to_lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

extract_host_from_url() {
  local url="${1:-}"
  printf '%s' "${url}" | sed -E 's#^[A-Za-z]+://([^/:]+).*#\1#'
}

resolve_ipv4_for_host() {
  local host="${1:-}"
  local ip=""
  if command -v getent >/dev/null 2>&1; then
    ip="$(getent ahostsv4 "${host}" 2>/dev/null | awk 'NR==1{print $1}')"
  fi
  if [[ -z "${ip}" && -x /usr/bin/getent ]]; then
    ip="$(/usr/bin/getent ahostsv4 "${host}" 2>/dev/null | awk 'NR==1{print $1}')"
  fi
  if [[ -z "${ip}" && "$(command -v dig >/dev/null 2>&1; echo $?)" -eq 0 ]]; then
    ip="$(dig +short "${host}" A | head -n 1)"
  fi
  printf '%s' "${ip}"
}

usage() {
  cat <<EOF
Usage:
  bash install_vps.sh [options]

Options:
  --install-dir <path>         Install directory (default: ${INSTALL_DIR})
  --image-registry <value>     Image registry/repo prefix (default: ${IMAGE_REGISTRY})
  --api-image <name>           API image name (default: ${API_IMAGE})
  --worker-image <name>        Worker image name (default: ${WORKER_IMAGE})
  --image-tag <tag>            Deploy image tag (default: from stable channel pointer)
  --update-channel-tag <tag>   Update check channel tag (default: auto from channel)
  --update-channel-name <name>  Update channel name (default: ${UPDATE_CHANNEL_NAME})
  --update-channel-base <url>   Update channel base url (default: ${UPDATE_CHANNEL_BASE})
  --ssl <on|off|auto>          SSL mode (default: ${SSL_MODE})
  --domain <domain>            Domain for SSL mode
  --email <email>              Let's Encrypt email
  --enable-browser <true|false> Enable browser execution (default: ${ENABLE_BROWSER})
  --storage <postgres|file>    Storage mode (default: ${STORAGE_MODE})
  --control-plane-url <url>    Control-plane base url (default: built-in)
  --control-plane-key <key>    Control-plane shared key (default: built-in)
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
    --update-channel-name) UPDATE_CHANNEL_NAME="$2"; shift 2 ;;
    --update-channel-base) UPDATE_CHANNEL_BASE="$2"; shift 2 ;;
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

resolve_update_channel_tag() {
  local channel_base channel_name json_url text_url raw_json parsed raw_text
  channel_base="${UPDATE_CHANNEL_BASE%/}"
  channel_name="${UPDATE_CHANNEL_NAME}"
  json_url="${channel_base}/${channel_name}.json"
  text_url="${channel_base}/${channel_name}"
  raw_json="$(curl -fsSL --max-time 10 "${json_url}" 2>/dev/null || true)"
  if [[ -n "${raw_json}" ]]; then
    parsed="$(printf '%s' "${raw_json}" | sed -n 's/.*"tag"[[:space:]]*:[[:space:]]*"\([^"]\+\)".*/\1/p' | head -n 1)"
    if [[ "${parsed}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
      echo "${parsed}"
      return 0
    fi
  fi
  raw_text="$(curl -fsSL --max-time 10 "${text_url}" 2>/dev/null | sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r//g' | head -n 1 || true)"
  if [[ "${raw_text}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    echo "${raw_text}"
    return 0
  fi
  return 1
}

if [[ -z "${UPDATE_CHANNEL_TAG}" ]]; then
  UPDATE_CHANNEL_TAG="$(resolve_update_channel_tag || true)"
fi
if [[ -z "${UPDATE_CHANNEL_TAG}" ]]; then
  UPDATE_CHANNEL_TAG="latest"
fi
if [[ -z "${IMAGE_TAG}" ]]; then
  IMAGE_TAG="${UPDATE_CHANNEL_TAG}"
fi
if [[ -z "${IMAGE_TAG}" ]]; then
  IMAGE_TAG="latest"
fi
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

MCP_ORIGIN_VALUE=""
if [[ "${SSL_MODE}" == "on" || "${SSL_MODE}" == "auto" ]]; then
  MCP_ORIGIN_VALUE="https://${DOMAIN}"
fi

if [[ -z "${CONTROL_PLANE_BASE_URL}" || -z "${CONTROL_PLANE_SHARED_KEY}" ]]; then
  echo "CONTROL_PLANE_BASE_URL and CONTROL_PLANE_SHARED_KEY are required (missing built-in defaults)."
  exit 1
fi

DOCKER_DNS_1="${DOCKER_DNS_1:-1.1.1.1}"
DOCKER_DNS_2="${DOCKER_DNS_2:-8.8.8.8}"
CONTROL_PLANE_DNS_HOST="$(extract_host_from_url "${CONTROL_PLANE_BASE_URL}")"
CONTROL_PLANE_DNS_IP="$(resolve_ipv4_for_host "${CONTROL_PLANE_DNS_HOST}")"
if [[ -z "${CONTROL_PLANE_DNS_HOST}" || "${CONTROL_PLANE_DNS_HOST}" == "${CONTROL_PLANE_BASE_URL}" ]]; then
  echo "Failed to parse host from CONTROL_PLANE_BASE_URL: ${CONTROL_PLANE_BASE_URL}"
  exit 1
fi
if [[ -z "${CONTROL_PLANE_DNS_IP}" ]]; then
  echo "Failed to resolve control-plane host: ${CONTROL_PLANE_DNS_HOST}"
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
    dns:
      - ${DOCKER_DNS_1:-1.1.1.1}
      - ${DOCKER_DNS_2:-8.8.8.8}
    extra_hosts:
      - "${CONTROL_PLANE_DNS_HOST:-license.invalid}:${CONTROL_PLANE_DNS_IP:-127.0.0.1}"
    environment:
      - NODE_ENV=${NODE_ENV:-production}
      - PORT=3000
      - TZ=${TZ:-Asia/Shanghai}
      - APP_TIMEZONE=${APP_TIMEZONE:-Asia/Shanghai}
      - GOOGLE_ADS_API_VERSION=${GOOGLE_ADS_API_VERSION:-v25}
      - REDIS_URL=redis://redis:6379
      - STORAGE_MODE=${STORAGE_MODE:-postgres}
      - DATABASE_URL=postgres://${POSTGRES_USER:-bb}:${POSTGRES_PASSWORD:-bb_change_me}@postgres:5432/${POSTGRES_DB:-bbexchange}
      - ENABLE_BROWSER_EXECUTION=${ENABLE_BROWSER_EXECUTION:-false}
      - TENANT_CODE=${TENANT_CODE:-local}
      - AUTH_SECRET=${AUTH_SECRET}
      - CREDENTIAL_SECRET=${CREDENTIAL_SECRET}
      - APP_SERVER_MODE=${APP_SERVER_MODE:-user}
      - MCP_PUBLIC_ORIGIN=${MCP_PUBLIC_ORIGIN:-}
      - MCP_ENABLED=${MCP_ENABLED:-true}
      - MCP_WRITE_ENABLED=${MCP_WRITE_ENABLED:-true}
      - CONTROL_PLANE_BASE_URL=${CONTROL_PLANE_BASE_URL}
      - CONTROL_PLANE_SHARED_KEY=${CONTROL_PLANE_SHARED_KEY}
      - CONTROL_PLANE_TIMEOUT_MS=${CONTROL_PLANE_TIMEOUT_MS:-8000}
      - SELF_UPDATE_ENABLED=${SELF_UPDATE_ENABLED:-false}
      - SELF_UPDATE_MODE=${SELF_UPDATE_MODE:-manual_image_ops}
      - SELF_UPDATE_REPO_DIR=${SELF_UPDATE_REPO_DIR:-/workspace}
      - SELF_UPDATE_HOST_REPO_DIR=${SELF_UPDATE_HOST_REPO_DIR:-/opt/brandbidding}
      - SELF_UPDATE_IMAGE_COMPOSE_FILE=${SELF_UPDATE_IMAGE_COMPOSE_FILE:-deploy/docker-compose.image.yml}
      - SELF_UPDATE_CHANNEL_BASE=${SELF_UPDATE_CHANNEL_BASE:-https://raw.githubusercontent.com/wd9337812/bbexchange-installer/main/release-channel}
      - SELF_UPDATE_IMAGE_CHANNEL=${SELF_UPDATE_IMAGE_CHANNEL:-stable}
      - SELF_UPDATE_IMAGE_CHANNEL_TAG=${SELF_UPDATE_IMAGE_CHANNEL_TAG:-latest}
      - SELF_UPDATE_IMAGE_CHANNEL_URL=${SELF_UPDATE_IMAGE_CHANNEL_URL:-}
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
    init: true
    restart: unless-stopped
    dns:
      - ${DOCKER_DNS_1:-1.1.1.1}
      - ${DOCKER_DNS_2:-8.8.8.8}
    extra_hosts:
      - "${CONTROL_PLANE_DNS_HOST:-license.invalid}:${CONTROL_PLANE_DNS_IP:-127.0.0.1}"
    environment:
      - NODE_ENV=${NODE_ENV:-production}
      - TZ=${TZ:-Asia/Shanghai}
      - APP_TIMEZONE=${APP_TIMEZONE:-Asia/Shanghai}
      - REDIS_URL=redis://redis:6379
      - STORAGE_MODE=${STORAGE_MODE:-postgres}
      - DATABASE_URL=postgres://${POSTGRES_USER:-bb}:${POSTGRES_PASSWORD:-bb_change_me}@postgres:5432/${POSTGRES_DB:-bbexchange}
      - ENABLE_BROWSER_EXECUTION=${ENABLE_BROWSER_EXECUTION:-false}
      - TENANT_CODE=${TENANT_CODE:-local}
      - BROWSER_POOL_SIZE=${BROWSER_POOL_SIZE:-}
      - BROWSER_CONCURRENCY_MODE=${BROWSER_CONCURRENCY_MODE:-}
      - WORKER_CONCURRENCY=${WORKER_CONCURRENCY:-30}
      - BROWSER_POOL_MAX_RSS_MB=${BROWSER_POOL_MAX_RSS_MB:-}
      - BROWSER_HOST_RESERVE_MB=${BROWSER_HOST_RESERVE_MB:-}
      - BROWSER_POOL_WAIT_TIMEOUT_MS=${BROWSER_POOL_WAIT_TIMEOUT_MS:-15000}
      - BROWSER_POOL_CLOSE_TIMEOUT_MS=${BROWSER_POOL_CLOSE_TIMEOUT_MS:-5000}
      - BROWSER_POOL_GUARD_INTERVAL_MS=${BROWSER_POOL_GUARD_INTERVAL_MS:-15000}
      - BROWSER_POOL_MAX_AGE_MS=${BROWSER_POOL_MAX_AGE_MS:-2700000}
      - BROWSER_POOL_CONTEXT_MAX_USES=${BROWSER_POOL_CONTEXT_MAX_USES:-40}
      - GOOGLE_ADS_API_VERSION=${GOOGLE_ADS_API_VERSION:-v25}
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
set -Eeuo pipefail

TARGET_TAG="${1:-}"
COMPOSE_FILE="${COMPOSE_FILE:-deploy/docker-compose.image.yml}"
ENV_FILE="${ENV_FILE:-.env.prod}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAST_TAG_FILE="${REPO_DIR}/apps/backend/data/last_good_image_tag.txt"
INSTALLER_RAW_BASE_DEFAULT="https://raw.githubusercontent.com/wd9337812/bbexchange-installer/main"
CHANNEL_BASE_DEFAULT="https://raw.githubusercontent.com/wd9337812/bbexchange-installer/main/release-channel"
REQUIRED_FREE_GB="${REQUIRED_FREE_GB:-6}"
REQUIRED_FREE_INODE_PERCENT="${REQUIRED_FREE_INODE_PERCENT:-10}"
AUTO_CLEANUP="${AUTO_CLEANUP:-true}"
DRY_RUN="${DRY_RUN:-false}"
REQUIRE_NEW_IMAGE="${REQUIRE_NEW_IMAGE:-false}"
CHANNEL_NAME_OVERRIDE=""
ALLOW_STALE_CHANNEL_FALLBACK="${ALLOW_STALE_CHANNEL_FALLBACK:-false}"

cd "${REPO_DIR}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "env file not found: ${ENV_FILE}"
  exit 1
fi

get_env_var() {
  local key="$1"
  sed -n "s/^${key}=//p" "${ENV_FILE}" | head -n 1
}

set_env_var() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" "${ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}"
  else
    echo "${key}=${value}" >> "${ENV_FILE}"
  fi
}

safe_tenant_name() {
  local raw="${1:-}"
  local cleaned
  cleaned="$(printf '%s' "${raw}" | tr -cd 'A-Za-z0-9._-')"
  cleaned="${cleaned#[-_.]}"
  cleaned="${cleaned%% }"
  if [[ -z "${cleaned}" ]]; then
    cleaned="tenant-host"
  fi
  printf '%s' "${cleaned}"
}

extract_host_from_url() {
  local url="${1:-}"
  printf '%s' "${url}" | sed -E 's#^[A-Za-z]+://([^/:]+).*#\1#'
}

resolve_ipv4_for_host() {
  local host="${1:-}"
  local ip=""
  if command -v getent >/dev/null 2>&1; then
    ip="$(getent ahostsv4 "${host}" 2>/dev/null | awk 'NR==1{print $1}')"
  fi
  if [[ -z "${ip}" && -x /usr/bin/getent ]]; then
    ip="$(/usr/bin/getent ahostsv4 "${host}" 2>/dev/null | awk 'NR==1{print $1}')"
  fi
  if [[ -z "${ip}" && "$(command -v dig >/dev/null 2>&1; echo $?)" -eq 0 ]]; then
    ip="$(dig +short "${host}" A | head -n 1)"
  fi
  printf '%s' "${ip}"
}

ensure_control_plane_dns_defaults() {
  local cp_url cp_host cp_ip
  cp_url="$(get_env_var CONTROL_PLANE_BASE_URL)"
  cp_url="${cp_url:-}"

  set_env_var "DOCKER_DNS_1" "${DOCKER_DNS_1:-1.1.1.1}"
  set_env_var "DOCKER_DNS_2" "${DOCKER_DNS_2:-8.8.8.8}"
  if [[ -z "${cp_url}" ]]; then
    return 0
  fi

  cp_host="$(extract_host_from_url "${cp_url}")"
  if [[ -z "${cp_host}" || "${cp_host}" == "${cp_url}" ]]; then
    return 0
  fi

  cp_ip="$(resolve_ipv4_for_host "${cp_host}")"
  if [[ -n "${cp_ip}" ]]; then
    set_env_var "CONTROL_PLANE_DNS_HOST" "${cp_host}"
    set_env_var "CONTROL_PLANE_DNS_IP" "${cp_ip}"
    echo "[update] control-plane mapping: ${cp_host} -> ${cp_ip}"
  else
    echo "[update] WARN: failed to resolve ${cp_host}, keep existing CONTROL_PLANE_DNS_IP"
    if [[ -z "$(get_env_var CONTROL_PLANE_DNS_HOST)" ]]; then
      set_env_var "CONTROL_PLANE_DNS_HOST" "${cp_host}"
    fi
  fi
}

require_control_plane_for_user_mode() {
  local mode cp_url cp_key tenant_code body code host_hint cp_host cp_ip
  mode="$(get_env_var APP_SERVER_MODE)"
  mode="${mode:-user}"
  if [[ "${mode}" != "user" ]]; then
    return 0
  fi
  cp_url="$(get_env_var CONTROL_PLANE_BASE_URL)"
  cp_key="$(get_env_var CONTROL_PLANE_SHARED_KEY)"
  tenant_code="$(get_env_var TENANT_CODE)"

  if [[ -z "${cp_url}" || -z "${cp_key}" ]]; then
    echo "[update] ERROR: user mode requires CONTROL_PLANE_BASE_URL and CONTROL_PLANE_SHARED_KEY in ${ENV_FILE}"
    exit 31
  fi

  if [[ -z "${tenant_code}" ]]; then
    host_hint="$(safe_tenant_name "$(hostname 2>/dev/null || echo tenant)")"
    body="$(curl -sS -m 15 -X POST "${cp_url%/}/api/internal/tenant/register" \
      -H "Content-Type: application/json" \
      -H "X-Control-Plane-Key: ${cp_key}" \
      -H "X-Tenant-Code: bootstrap" \
      -d "{\"tenantName\":\"${host_hint}\"}" || true)"
    tenant_code="$(printf '%s' "${body}" | sed -n 's/.*"tenantCode":"\([^"]*\)".*/\1/p' | head -n 1)"
    if [[ -z "${tenant_code}" ]]; then
      echo "[update] ERROR: auto register tenant failed: ${body}"
      exit 31
    fi
    set_env_var "TENANT_CODE" "${tenant_code}"
    echo "[update] auto registered tenant code: ${tenant_code}"
  fi

  if [[ "${SKIP_CONTROL_PLANE_CHECK:-false}" == "true" ]]; then
    echo "[update] WARN: skip control-plane connectivity check (SKIP_CONTROL_PLANE_CHECK=true)"
    return 0
  fi

  local probe_url
  probe_url="${cp_url%/}/api/internal/subscription/current?tenantCode=${tenant_code}"
  body="$(mktemp)"
  code="$(curl -sS -m 12 -o "${body}" -w "%{http_code}" \
    -H "X-Control-Plane-Key: ${cp_key}" \
    -H "X-Tenant-Code: ${tenant_code}" \
    "${probe_url}" || true)"
  if [[ "${code}" != "200" ]]; then
    cp_host="$(get_env_var CONTROL_PLANE_DNS_HOST)"
    cp_host="${cp_host:-$(extract_host_from_url "${cp_url}")}"
    cp_ip="$(get_env_var CONTROL_PLANE_DNS_IP)"
    if [[ -n "${cp_host}" && -n "${cp_ip}" ]]; then
      echo "[update] probe retry with pinned resolve: ${cp_host} -> ${cp_ip}"
      code="$(curl -sS -m 12 -o "${body}" -w "%{http_code}" \
        --resolve "${cp_host}:443:${cp_ip}" \
        -H "X-Control-Plane-Key: ${cp_key}" \
        -H "X-Tenant-Code: ${tenant_code}" \
        "${probe_url}" || true)"
    fi
  fi
  if [[ "${code}" != "200" ]]; then
    echo "[update] ERROR: control plane probe failed, code=${code}, url=${probe_url}"
    echo "[update] response: $(head -c 300 "${body}" 2>/dev/null || true)"
    rm -f "${body}" >/dev/null 2>&1 || true
    exit 32
  fi
  rm -f "${body}" >/dev/null 2>&1 || true
}

bool_true() {
  local v="${1:-}"
  v="$(echo "${v}" | tr '[:upper:]' '[:lower:]')"
  [[ "${v}" == "1" || "${v}" == "true" || "${v}" == "yes" || "${v}" == "on" ]]
}

in_keep_tags() {
  local tag="$1"
  shift
  local keep
  for keep in "$@"; do
    [[ "${tag}" == "${keep}" ]] && return 0
  done
  return 1
}

cleanup_old_app_images() {
  local rollback_tag="$1"
  local image_repo="$2"
  local image_name="$3"
  local keep_tags=("${TARGET_TAG}")
  local tag
  local refs=()
  local removed=0

  if [[ -n "${rollback_tag}" && "${rollback_tag}" != "${TARGET_TAG}" ]]; then
    keep_tags+=("${rollback_tag}")
  fi

  while IFS= read -r tag; do
    [[ -z "${tag}" || "${tag}" == "<none>" ]] && continue
    if in_keep_tags "${tag}" "${keep_tags[@]}"; then
      continue
    fi
    refs+=("${image_repo}/${image_name}:${tag}")
  done < <(docker images "${image_repo}/${image_name}" --format '{{.Tag}}' | sort -u)

  if [[ "${#refs[@]}" -eq 0 ]]; then
    echo "[cleanup] ${image_name}: no old tag to remove (kept: ${keep_tags[*]})"
    return 0
  fi

  echo "[cleanup] ${image_name}: keep tags ${keep_tags[*]}, remove old tags ${#refs[@]}"
  for tag in "${refs[@]}"; do
    if docker image rm "${tag}" >/dev/null 2>&1; then
      removed=$((removed + 1))
      echo "[cleanup] removed ${tag}"
    else
      echo "[cleanup] skip ${tag} (possibly in use)"
    fi
  done
  echo "[cleanup] ${image_name}: removed ${removed}/${#refs[@]} old tags"
}

check_path_capacity() {
  local path="$1"
  local required_kb="$2"
  local required_inode_percent="$3"
  local label="$4"
  local df_line
  local dfi_line
  local avail_kb
  local inode_total
  local inode_avail
  local inode_free_percent
  df_line="$(df -Pk "${path}" | awk 'NR==2 {print $4}')"
  dfi_line="$(df -Pi "${path}" | awk 'NR==2 {print $2" "$4}')"
  avail_kb="${df_line:-0}"
  inode_total="$(echo "${dfi_line}" | awk '{print $1}')"
  inode_avail="$(echo "${dfi_line}" | awk '{print $2}')"
  inode_total="${inode_total:-0}"
  inode_avail="${inode_avail:-0}"
  if [[ "${inode_total}" -gt 0 ]]; then
    inode_free_percent=$(( inode_avail * 100 / inode_total ))
  else
    inode_free_percent=100
  fi
  echo "[preflight] ${label}: free=$((avail_kb / 1024 / 1024))GB inode_free=${inode_free_percent}%"
  if [[ "${avail_kb}" -lt "${required_kb}" ]]; then
    echo "[preflight] insufficient disk on ${label}"
    return 1
  fi
  if [[ "${inode_free_percent}" -lt "${required_inode_percent}" ]]; then
    echo "[preflight] insufficient inode on ${label}"
    return 1
  fi
  return 0
}

run_preflight_upgrade() {
  local required_kb
  local docker_root
  local risk=0
  required_kb=$(( REQUIRED_FREE_GB * 1024 * 1024 ))
  docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  docker_root="${docker_root:-/var/lib/docker}"

  echo "[preflight] required free disk >= ${REQUIRED_FREE_GB}GB, inode free >= ${REQUIRED_FREE_INODE_PERCENT}%"
  docker system df || true
  df -h / "${docker_root}" 2>/dev/null || true
  df -ih / "${docker_root}" 2>/dev/null || true

  check_path_capacity "/" "${required_kb}" "${REQUIRED_FREE_INODE_PERCENT}" "rootfs(/)" || risk=1
  check_path_capacity "${docker_root}" "${required_kb}" "${REQUIRED_FREE_INODE_PERCENT}" "docker(${docker_root})" || risk=1
  if [[ "${risk}" -eq 0 ]]; then
    echo "[preflight] capacity check passed."
    return 0
  fi

  if bool_true "${DRY_RUN}"; then
    echo "[preflight] DRY_RUN=true and capacity check failed."
    return 31
  fi

  if ! bool_true "${AUTO_CLEANUP}"; then
    echo "[preflight] AUTO_CLEANUP=false and capacity check failed."
    return 32
  fi

  echo "[preflight] insufficient capacity; refusing host-wide cleanup. Free disk space explicitly before retrying."
  docker system df || true
  df -h / "${docker_root}" 2>/dev/null || true
  df -ih / "${docker_root}" 2>/dev/null || true

  risk=0
  check_path_capacity "/" "${required_kb}" "${REQUIRED_FREE_INODE_PERCENT}" "rootfs(/)" || risk=1
  check_path_capacity "${docker_root}" "${required_kb}" "${REQUIRED_FREE_INODE_PERCENT}" "docker(${docker_root})" || risk=1
  if [[ "${risk}" -ne 0 ]]; then
    echo "[preflight] still insufficient after cleanup."
    return 32
  fi
  echo "[preflight] capacity recovered."
  return 0
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

ensure_secret_var() {
  local key="$1"
  local current
  current="$(sed -n "s/^${key}=//p" "${ENV_FILE}" | head -n 1)"
  if [[ -z "${current}" ]]; then
    if grep -q "^${key}=" "${ENV_FILE}"; then
      sed -i "s/^${key}=.*/${key}=$(openssl rand -hex 32)/" "${ENV_FILE}"
    else
      echo "${key}=$(openssl rand -hex 32)" >> "${ENV_FILE}"
    fi
  fi
}

ensure_env_var "TZ" "Asia/Shanghai"
ensure_env_var "APP_TIMEZONE" "Asia/Shanghai"
ensure_env_var "NODE_ENV" "production"
ads_api_version="$(get_env_var GOOGLE_ADS_API_VERSION)"
ads_api_version="${ads_api_version%$'\r'}"
if [[ "${ads_api_version}" == \"*\" || "${ads_api_version}" == \'*\' ]]; then
  ads_api_version="${ads_api_version:1:${#ads_api_version}-2}"
fi
if [[ -z "${ads_api_version}" || "${ads_api_version}" =~ ^v([1-9]|1[0-9]|2[0-4])$ ]]; then
  if [[ -n "${ads_api_version}" ]]; then
    cp -p -- "${ENV_FILE}" "${ENV_FILE}.before-google-ads-v25.$(date -u +%Y%m%dT%H%M%SZ).bak"
  fi
  ensure_env_var "GOOGLE_ADS_API_VERSION" "v25"
  echo "[update] Google Ads API -> v25 (API and Worker; old Google Ads scripts must be recopied)."
elif [[ ! "${ads_api_version}" =~ ^v[1-9][0-9]*$ ]]; then
  echo "[update] invalid GOOGLE_ADS_API_VERSION; expected a major version such as v25." >&2
  exit 33
fi
ensure_control_plane_dns_defaults
require_control_plane_for_user_mode
ensure_secret_var "AUTH_SECRET"
ensure_secret_var "CREDENTIAL_SECRET"

INSTALLER_RAW_BASE="$(sed -n 's/^SELF_UPDATE_INSTALLER_RAW_BASE=//p' "${ENV_FILE}" | head -n 1)"
INSTALLER_RAW_BASE="${INSTALLER_RAW_BASE:-${INSTALLER_RAW_BASE_DEFAULT}}"

self_update_ops_assets() {
  if ! command -v curl >/dev/null 2>&1; then
    echo "[update] curl not found, skip ops-assets self-update."
    return 0
  fi
  echo "[update] sync ops assets from public installer: ${INSTALLER_RAW_BASE}"
  mkdir -p deploy scripts
  local tmp
  tmp="$(mktemp)"

  fetch_one() {
    local rel="$1"
    local dst="${REPO_DIR}/${rel}"
    local dir
    dir="$(dirname "${dst}")"
    mkdir -p "${dir}"
    if curl -fsSL "${INSTALLER_RAW_BASE}/${rel}" -o "${tmp}"; then
      mv "${tmp}" "${dst}"
      echo "[update] ${rel} sync ok"
    else
      echo "[update] ${rel} keep local"
    fi
  }

  fetch_one "deploy/docker-compose.image.yml"
  fetch_one "scripts/db_migrate.sh"
  fetch_one "scripts/db_backup.sh"
  fetch_one "scripts/rollback_image.sh"
  fetch_one "scripts/update_image.sh"
  fetch_one "scripts/configure_runtime_resources.sh"

  rm -f "${tmp}" >/dev/null 2>&1 || true
  chmod +x scripts/db_migrate.sh scripts/db_backup.sh scripts/rollback_image.sh scripts/update_image.sh >/dev/null 2>&1 || true
}

self_update_ops_assets

if [[ -n "${TARGET_TAG}" && "${TARGET_TAG}" =~ ^[A-Za-z][A-Za-z0-9._-]*$ ]]; then
  case "${TARGET_TAG}" in
    stable|beta|nightly)
      CHANNEL_NAME_OVERRIDE="${TARGET_TAG}"
      TARGET_TAG=""
      ;;
  esac
fi

resolve_target_tag_from_channel() {
  local channel_base channel_name channel_url channel_json_url resolved raw_json parsed_tag cache_buster sep
  local api_url api_json api_b64 api_resolved
  channel_base="$(sed -n 's/^SELF_UPDATE_CHANNEL_BASE=//p' "${ENV_FILE}" | head -n 1)"
  channel_name="$(sed -n 's/^SELF_UPDATE_IMAGE_CHANNEL=//p' "${ENV_FILE}" | head -n 1)"
  channel_url="$(sed -n 's/^SELF_UPDATE_IMAGE_CHANNEL_URL=//p' "${ENV_FILE}" | head -n 1)"
  channel_base="${channel_base:-${CHANNEL_BASE_DEFAULT}}"
  channel_name="${CHANNEL_NAME_OVERRIDE:-${channel_name:-stable}}"
  cache_buster="$(date +%s)"
  if [[ "${channel_base}" == *"/BBexchange/"* ]]; then
    echo "[update] WARN: SELF_UPDATE_CHANNEL_BASE points to BBexchange (${channel_base})."
    echo "[update] WARN: if BBexchange is private, other users may not fetch release channel."
  fi
  if [[ -z "${channel_url}" ]]; then
    channel_url="${channel_base%/}/${channel_name}"
  fi
  if [[ "${channel_url}" =~ \.json$ ]]; then
    channel_json_url="${channel_url}"
    channel_url="${channel_url%.json}"
  else
    channel_json_url="${channel_url}.json"
  fi

  if [[ "${channel_url}" == "https://raw.githubusercontent.com/wd9337812/bbexchange-installer/main/release-channel/"* ]]; then
    api_url="https://api.github.com/repos/wd9337812/bbexchange-installer/contents/release-channel/${channel_name}?ref=main"
    echo "[update] resolving channel via GitHub contents API: ${api_url}"
    api_json="$(curl -fsSL -H 'Cache-Control: no-cache' -H 'Accept: application/vnd.github+json' --max-time 10 "${api_url}" 2>/dev/null || true)"
    api_b64="$(printf '%s\n' "${api_json}" | sed -n 's/^[[:space:]]*"content":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 | tr -d '\r\n ')"
    if [[ -n "${api_b64}" ]] && command -v base64 >/dev/null 2>&1; then
      api_resolved="$(printf '%s' "${api_b64}" | base64 -d 2>/dev/null | sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r//g' | head -n 1 || true)"
      if [[ "${api_resolved}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
        TARGET_TAG="${api_resolved}"
        echo "[update] resolved image tag from GitHub contents API (${channel_name}): ${TARGET_TAG}"
        return 0
      fi
    fi
  fi

  sep="?"
  [[ "${channel_url}" == *\?* ]] && sep="&"
  echo "[update] resolving channel url: ${channel_url}"
  resolved="$(curl -fsSL -H 'Cache-Control: no-cache' --max-time 10 "${channel_url}${sep}t=${cache_buster}" 2>/dev/null | sed -e '1s/^\xEF\xBB\xBF//' -e 's/\r//g' | head -n 1 || true)"
  if [[ "${resolved}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    TARGET_TAG="${resolved}"
    echo "[update] resolved image tag from channel (${channel_name}): ${TARGET_TAG}"
    return 0
  fi

  sep="?"
  [[ "${channel_json_url}" == *\?* ]] && sep="&"
  echo "[update] resolving channel json url: ${channel_json_url}"
  raw_json="$(curl -fsSL -H 'Cache-Control: no-cache' --max-time 10 "${channel_json_url}${sep}t=${cache_buster}" 2>/dev/null || true)"
  if [[ -n "${raw_json}" ]]; then
    parsed_tag="$(printf '%s' "${raw_json}" | sed -n 's/.*"tag"[[:space:]]*:[[:space:]]*"\([^"]\+\)".*/\1/p' | head -n 1)"
    if [[ "${parsed_tag}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
      TARGET_TAG="${parsed_tag}"
      echo "[update] resolved image tag from channel json (${channel_name}): ${TARGET_TAG}"
      return 0
    fi
  fi
  echo "[update] ERROR: failed to resolve channel tag from ${channel_url}"
  return 1
}

if [[ -z "${TARGET_TAG}" ]]; then
  if ! resolve_target_tag_from_channel; then
    fallback_tag="$(sed -n 's/^SELF_UPDATE_IMAGE_CHANNEL_TAG=//p' "${ENV_FILE}" | head -n 1)"
    if bool_true "${ALLOW_STALE_CHANNEL_FALLBACK}" && [[ -n "${fallback_tag}" ]]; then
      TARGET_TAG="${fallback_tag}"
      echo "[update] WARN: using stale fallback tag from SELF_UPDATE_IMAGE_CHANNEL_TAG=${TARGET_TAG}"
    else
      echo "[update] ERROR: channel resolve failed; refuse to use stale fallback."
      echo "[update] hint: set ALLOW_STALE_CHANNEL_FALLBACK=true to force fallback, or pass explicit tag."
      exit 12
    fi
  fi
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

if ! run_preflight_upgrade; then
  code=$?
  echo "[update] preflight failed with code=${code}"
  exit "${code}"
fi

mkdir -p apps/backend/data
CURRENT_TAG="$(sed -n 's/^IMAGE_TAG=//p' "${ENV_FILE}" | head -n 1)"
ROLLBACK_TAG="${CURRENT_TAG:-}"
ENV_TAG_WRITTEN=false
SERVICES_SWITCHED=false
RESOURCE_BACKUP="${REPO_DIR}/apps/backend/data/last_good_resource_env.txt"
if [[ -f scripts/configure_runtime_resources.sh ]]; then
  source scripts/configure_runtime_resources.sh
  capture_runtime_resource_env "${ENV_FILE}" "${RESOURCE_BACKUP}"
fi
restore_image_tag_on_error() {
  local code=$?
  trap - ERR
  if [[ "${SERVICES_SWITCHED}" == "true" ]]; then
    echo '[update] ERROR: services may already use the new image; keep its matching environment.'
    echo '[update] Inspect service logs. To roll back, use rollback_image.sh; it first drains captured task results.'
    exit "${code}"
  fi
  if [[ -f "${RESOURCE_BACKUP}" ]] && declare -F restore_runtime_resource_env >/dev/null; then
    restore_runtime_resource_env "${ENV_FILE}" "${RESOURCE_BACKUP}" || true
  fi
  if [[ "${ENV_TAG_WRITTEN}" == "true" && "${TARGET_TAG}" != "${ROLLBACK_TAG}" ]]; then
    echo "[update] ERROR: update failed before success; restore IMAGE_TAG=${ROLLBACK_TAG:-<empty>}"
    if [[ -n "${ROLLBACK_TAG}" ]]; then
      set_env_var "IMAGE_TAG" "${ROLLBACK_TAG}" || true
    else
      sed -i '/^IMAGE_TAG=/d' "${ENV_FILE}" || true
    fi
  fi
  exit "${code}"
}
trap restore_image_tag_on_error ERR
if [[ -n "${CURRENT_TAG}" ]]; then
  echo "${CURRENT_TAG}" > "${LAST_TAG_FILE}"
fi

before_api_id="$(docker image inspect "${API_IMAGE_REF}" --format '{{.Id}}' 2>/dev/null || true)"
before_worker_id="$(docker image inspect "${WORKER_IMAGE_REF}" --format '{{.Id}}' 2>/dev/null || true)"

echo "[update] backup database/files..."
bash scripts/db_backup.sh "${COMPOSE_FILE}" "${ENV_FILE}"
if [[ -f scripts/configure_runtime_resources.sh ]]; then
  bash scripts/configure_runtime_resources.sh "${ENV_FILE}"
fi

if grep -q '^IMAGE_TAG=' "${ENV_FILE}"; then
  sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=${TARGET_TAG}/" "${ENV_FILE}"
else
  echo "IMAGE_TAG=${TARGET_TAG}" >> "${ENV_FILE}"
fi
ENV_TAG_WRITTEN=true
write_env_stamp="${TARGET_TAG}-$(date +%s)"
if grep -q '^FRONTEND_BUILD_ID=' "${ENV_FILE}"; then
  sed -i "s/^FRONTEND_BUILD_ID=.*/FRONTEND_BUILD_ID=${write_env_stamp}/" "${ENV_FILE}"
else
  echo "FRONTEND_BUILD_ID=${write_env_stamp}" >> "${ENV_FILE}"
fi

echo "[update] pull images: ${TARGET_TAG}"
IMAGE_TAG="${TARGET_TAG}" docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" pull api worker

after_api_id="$(docker image inspect "${API_IMAGE_REF}" --format '{{.Id}}' 2>/dev/null || true)"
after_worker_id="$(docker image inspect "${WORKER_IMAGE_REF}" --format '{{.Id}}' 2>/dev/null || true)"

if [[ "${TARGET_TAG}" == "latest" && -n "${before_api_id}" && -n "${after_api_id}" && "${before_api_id}" == "${after_api_id}" && -n "${before_worker_id}" && -n "${after_worker_id}" && "${before_worker_id}" == "${after_worker_id}" ]]; then
  echo "[update] no new image pulled for tag 'latest'. Build may still be running or latest has not changed."
  echo "[update] current api image id: ${after_api_id}"
  echo "[update] current worker image id: ${after_worker_id}"
  if bool_true "${REQUIRE_NEW_IMAGE}"; then
    exit 2
  fi
  echo "[update] REQUIRE_NEW_IMAGE=false, continue with current images."
fi

echo "[update] migrate schema from image: ${API_IMAGE_REF}"
SOURCE_IMAGE="${API_IMAGE_REF}" bash scripts/db_migrate.sh "${COMPOSE_FILE}" "${ENV_FILE}"

echo "[update] restart services"
SERVICES_SWITCHED=true
IMAGE_TAG="${TARGET_TAG}" docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" up -d --force-recreate api worker caddy

echo "[update] health check"
health_ok=0
for i in 1 2 3 4 5; do
  if curl -fsS --max-time 10 http://127.0.0.1/api/health >/dev/null 2>&1; then
    health_ok=1
    break
  fi
  if curl -fsS --max-time 10 http://127.0.0.1:8080/api/health >/dev/null 2>&1; then
    health_ok=1
    break
  fi
  sleep 2
done
if [[ "${health_ok}" -ne 1 ]]; then
  echo "[update] ERROR: health check failed after retries."
  exit 33
fi

echo "[update] success: IMAGE_TAG=${TARGET_TAG}"
trap - ERR
ENV_TAG_WRITTEN=false

if bool_true "${AUTO_CLEANUP}"; then
  echo "[cleanup] start image retention (keep current + previous rollback)"
  cleanup_old_app_images "${ROLLBACK_TAG}" "${IMAGE_REGISTRY}" "${API_IMAGE_NAME}"
  cleanup_old_app_images "${ROLLBACK_TAG}" "${IMAGE_REGISTRY}" "${WORKER_IMAGE_NAME}"
fi

api_cid="$(docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" ps -q api 2>/dev/null || true)"
worker_cid="$(docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" ps -q worker 2>/dev/null || true)"
api_started="$(docker inspect -f '{{.State.StartedAt}}' "${api_cid}" 2>/dev/null || true)"
worker_started="$(docker inspect -f '{{.State.StartedAt}}' "${worker_cid}" 2>/dev/null || true)"
api_digest="$(docker inspect --format='{{index .RepoDigests 0}}' "${API_IMAGE_REF}" 2>/dev/null || true)"
worker_digest="$(docker inspect --format='{{index .RepoDigests 0}}' "${WORKER_IMAGE_REF}" 2>/dev/null || true)"
echo "[summary] api image id=${after_api_id} started_at=${api_started} digest=${api_digest:-unknown}"
echo "[summary] worker image id=${after_worker_id} started_at=${worker_started} digest=${worker_digest:-unknown}"
EOF

cat > scripts/rollback_image.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

TARGET_TAG="${1:-}"
COMPOSE_FILE="${COMPOSE_FILE:-deploy/docker-compose.image.yml}"
ENV_FILE="${ENV_FILE:-.env.prod}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAST_TAG_FILE="${REPO_DIR}/apps/backend/data/last_good_image_tag.txt"
RESOURCE_BACKUP="${REPO_DIR}/apps/backend/data/last_good_resource_env.txt"

cd "${REPO_DIR}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "env file not found: ${ENV_FILE}"
  exit 1
fi

if [[ -z "${TARGET_TAG}" ]]; then
  if [[ -f "${LAST_TAG_FILE}" ]]; then
    TARGET_TAG="$(cat "${LAST_TAG_FILE}")"
  fi
fi

if [[ -z "${TARGET_TAG}" ]]; then
  echo "Usage: bash scripts/rollback_image.sh <last_good_tag>"
  echo "No fallback tag found in ${LAST_TAG_FILE}"
  exit 1
fi

echo "[rollback] target tag: ${TARGET_TAG}"
echo "[rollback] note: rollback only switches app image; DB schema is forward-only."

CURRENT_TAG="$(sed -n 's/^IMAGE_TAG=//p' "${ENV_FILE}" | head -n 1)"
HTTP_PAUSED=false
API_STOPPED=false
WORKER_STOPPED=false
SWITCHED=false
compose() { docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" "$@"; }
rollback_failed() {
  local code=$?
  trap - ERR
  if [[ "${SWITCHED}" != true ]]; then
    if [[ "${WORKER_STOPPED}" == true ]]; then compose up -d worker || true; fi
    if [[ "${API_STOPPED}" == true ]]; then compose up -d api || true; fi
    if [[ "${HTTP_PAUSED}" == true ]]; then compose exec -T worker node apps/backend/scripts/drain_task_execution.js --resume || true; fi
  else
    echo '[rollback] ERROR: image switch started; inspect services before resuming tasks. No captured results were erased.'
  fi
  exit "$code"
}
trap rollback_failed ERR

# Pull first, without changing the running stack or its environment.
IMAGE_TAG="${TARGET_TAG}" compose pull api worker
worker_cid="$(compose ps -q worker)"
if [[ -z "${worker_cid}" || "$(docker inspect -f '{{.State.Running}}' "${worker_cid}")" != true ]]; then
  echo '[rollback] ERROR: current worker is not running; restore it first so captured cycles can be checked.' >&2
  exit 35
fi
if compose exec -T worker sh -c 'test -f apps/backend/scripts/drain_task_execution.js'; then
  echo '[rollback] pause new visits and drain browser/Ads continuations (up to 300 seconds).'
  compose stop api
  API_STOPPED=true
  HTTP_PAUSED=true
  compose exec -T worker node apps/backend/scripts/drain_task_execution.js --drain
  # Completion can schedule a future visit while draining. Stop the producer, then
  # remove future cadence jobs once more without starting another worker process.
  compose stop worker
  WORKER_STOPPED=true
  compose run --rm --no-deps worker node apps/backend/scripts/drain_task_execution.js --drain
else
  # An older image has no helper. It may not consume new durable continuations.
  compose exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <<'SQL'
DO $$ DECLARE n bigint; BEGIN
  IF to_regclass('task_execution_runtime') IS NOT NULL THEN
    EXECUTE 'select count(*) from task_execution_runtime where cycle_id is not null' INTO n;
    IF n>0 THEN RAISE EXCEPTION 'Captured task cycles remain; refuse incompatible rollback'; END IF;
  END IF;
END $$;
SQL
fi

if [[ -f scripts/configure_runtime_resources.sh && -f "${RESOURCE_BACKUP}" ]]; then
  source scripts/configure_runtime_resources.sh
  restore_runtime_resource_env "${ENV_FILE}" "${RESOURCE_BACKUP}"
fi

if grep -q '^IMAGE_TAG=' "${ENV_FILE}"; then
  sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=${TARGET_TAG}/" "${ENV_FILE}"
else
  echo "IMAGE_TAG=${TARGET_TAG}" >> "${ENV_FILE}"
fi

SWITCHED=true
compose up -d api worker caddy
if [[ "${HTTP_PAUSED}" == true ]]; then
  # All previous images expose the original main queue; no new-only helper is required.
  compose exec -T worker node -e 'const q=require("./apps/backend/src/queue").createTaskQueue();q.queue.resume().then(()=>q.queue.close()).then(()=>q.connection.quit()).catch(e=>{console.error(e.message);process.exitCode=1;});'
fi

curl -fsS --max-time 10 http://127.0.0.1/api/health >/dev/null
echo "[rollback] success: IMAGE_TAG=${TARGET_TAG}"
trap - ERR
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
GOOGLE_ADS_API_VERSION=v25
NODE_ENV=production
AUTH_SECRET=$(openssl rand -hex 32)
CREDENTIAL_SECRET=$(openssl rand -hex 32)
TENANT_CODE=${TENANT_CODE_VALUE}
APP_SERVER_MODE=user
MCP_PUBLIC_ORIGIN=${MCP_ORIGIN_VALUE}
CONTROL_PLANE_BASE_URL=${CONTROL_PLANE_BASE_URL}
CONTROL_PLANE_SHARED_KEY=${CONTROL_PLANE_SHARED_KEY}
CONTROL_PLANE_TIMEOUT_MS=8000
CONTROL_PLANE_DNS_HOST=${CONTROL_PLANE_DNS_HOST}
CONTROL_PLANE_DNS_IP=${CONTROL_PLANE_DNS_IP}
DOCKER_DNS_1=${DOCKER_DNS_1}
DOCKER_DNS_2=${DOCKER_DNS_2}
IMAGE_REGISTRY=${IMAGE_REGISTRY}
API_IMAGE=${API_IMAGE}
WORKER_IMAGE=${WORKER_IMAGE}
IMAGE_TAG=${IMAGE_TAG}
SELF_UPDATE_ENABLED=false
SELF_UPDATE_MODE=manual_image_ops
SELF_UPDATE_REPO_DIR=/workspace
SELF_UPDATE_HOST_REPO_DIR=${INSTALL_DIR}
SELF_UPDATE_IMAGE_COMPOSE_FILE=deploy/docker-compose.image.yml
SELF_UPDATE_CHANNEL_BASE=${UPDATE_CHANNEL_BASE}
SELF_UPDATE_IMAGE_CHANNEL=${UPDATE_CHANNEL_NAME}
SELF_UPDATE_IMAGE_CHANNEL_TAG=${UPDATE_CHANNEL_TAG}
SELF_UPDATE_IMAGE_CHANNEL_URL=
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
if curl -fsSL --max-time 30 https://raw.githubusercontent.com/wd9337812/bbexchange-installer/main/scripts/configure_runtime_resources.sh -o scripts/configure_runtime_resources.sh; then
  bash scripts/configure_runtime_resources.sh .env.prod
else
  echo 'Resource helper unavailable; worker will conservatively detect resources at startup.'
fi
ensure_env_var "TZ" "Asia/Shanghai"
ensure_env_var "APP_TIMEZONE" "Asia/Shanghai"
ensure_env_var "NODE_ENV" "production"
ensure_env_var_if_missing "TENANT_CODE" "tenant-$(openssl rand -hex 6)"
ensure_env_var "APP_SERVER_MODE" "user"
ensure_env_var "CONTROL_PLANE_BASE_URL" "${CONTROL_PLANE_BASE_URL}"
ensure_env_var "CONTROL_PLANE_SHARED_KEY" "${CONTROL_PLANE_SHARED_KEY}"
ensure_env_var "CONTROL_PLANE_TIMEOUT_MS" "8000"
ensure_env_var "CONTROL_PLANE_DNS_HOST" "${CONTROL_PLANE_DNS_HOST}"
ensure_env_var "CONTROL_PLANE_DNS_IP" "${CONTROL_PLANE_DNS_IP}"
ensure_env_var "DOCKER_DNS_1" "${DOCKER_DNS_1}"
ensure_env_var "DOCKER_DNS_2" "${DOCKER_DNS_2}"
ensure_env_var "SELF_UPDATE_ENABLED" "false"
ensure_env_var "SELF_UPDATE_MODE" "manual_image_ops"
ensure_env_var "SELF_UPDATE_REPO_DIR" "/workspace"
ensure_env_var "SELF_UPDATE_HOST_REPO_DIR" "${INSTALL_DIR}"
ensure_env_var "SELF_UPDATE_IMAGE_COMPOSE_FILE" "deploy/docker-compose.image.yml"
ensure_env_var "SELF_UPDATE_CHANNEL_BASE" "${UPDATE_CHANNEL_BASE}"
ensure_env_var "SELF_UPDATE_IMAGE_CHANNEL" "${UPDATE_CHANNEL_NAME}"
ensure_env_var "SELF_UPDATE_IMAGE_CHANNEL_TAG" "${UPDATE_CHANNEL_TAG}"
ensure_env_var "SELF_UPDATE_IMAGE_CHANNEL_URL" ""
ensure_env_var "SELF_UPDATE_HELPER_IMAGE" "docker:27-cli"
ensure_env_var "SELF_UPDATE_INSTALLER_RAW_BASE" "https://raw.githubusercontent.com/wd9337812/bbexchange-installer/main"
ensure_env_var "MCP_PUBLIC_ORIGIN" "${MCP_ORIGIN_VALUE}"
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
  echo "[install] probe retry with pinned resolve: ${CONTROL_PLANE_DNS_HOST} -> ${CONTROL_PLANE_DNS_IP}"
  PROBE_CODE="$(curl -sS -m 12 -o "${PROBE_BODY}" -w "%{http_code}" \
    --resolve "${CONTROL_PLANE_DNS_HOST}:443:${CONTROL_PLANE_DNS_IP}" \
    -H "X-Control-Plane-Key: ${CONTROL_PLANE_SHARED_KEY}" \
    -H "X-Tenant-Code: ${TENANT_CODE_VALUE}" \
    "${PROBE_URL}" || true)"
fi
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
