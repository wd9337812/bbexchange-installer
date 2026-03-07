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
    volumes:
      - redis_data:/data

  postgres:
    image: postgres:16-alpine
    container_name: bbexchange-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=${POSTGRES_USER:-bb}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-bb_change_me}
      - POSTGRES_DB=${POSTGRES_DB:-bbexchange}
    volumes:
      - pg_data:/var/lib/postgresql/data

  api:
    image: ${IMAGE_REGISTRY:-ghcr.io/wd9337812}/${API_IMAGE:-bbexchange-api}:${IMAGE_TAG:-latest}
    container_name: bbexchange-api
    restart: unless-stopped
    environment:
      - PORT=3000
      - REDIS_URL=redis://redis:6379
      - STORAGE_MODE=${STORAGE_MODE:-postgres}
      - DATABASE_URL=postgres://${POSTGRES_USER:-bb}:${POSTGRES_PASSWORD:-bb_change_me}@postgres:5432/${POSTGRES_DB:-bbexchange}
      - ENABLE_BROWSER_EXECUTION=${ENABLE_BROWSER_EXECUTION:-false}
      - AUTH_SECRET=${AUTH_SECRET}
      - CREDENTIAL_SECRET=${CREDENTIAL_SECRET}
      - ENABLE_GOOGLE_ADS_MUTATION=${ENABLE_GOOGLE_ADS_MUTATION:-false}
      - SELF_UPDATE_ENABLED=${SELF_UPDATE_ENABLED:-true}
      - SELF_UPDATE_MODE=${SELF_UPDATE_MODE:-image}
      - SELF_UPDATE_REPO_DIR=${SELF_UPDATE_REPO_DIR:-/workspace}
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
      - REDIS_URL=redis://redis:6379
      - STORAGE_MODE=${STORAGE_MODE:-postgres}
      - DATABASE_URL=postgres://${POSTGRES_USER:-bb}:${POSTGRES_PASSWORD:-bb_change_me}@postgres:5432/${POSTGRES_DB:-bbexchange}
      - ENABLE_BROWSER_EXECUTION=${ENABLE_BROWSER_EXECUTION:-false}
      - BROWSER_POOL_SIZE=${BROWSER_POOL_SIZE:-4}
      - OFFER_NAV_TIMEOUT_MS=${OFFER_NAV_TIMEOUT_MS:-20000}
      - CHROMIUM_EXECUTABLE_PATH=${CHROMIUM_EXECUTABLE_PATH:-/usr/bin/chromium-browser}
      - AUTH_SECRET=${AUTH_SECRET}
      - CREDENTIAL_SECRET=${CREDENTIAL_SECRET}
      - ENABLE_GOOGLE_ADS_MUTATION=${ENABLE_GOOGLE_ADS_MUTATION:-false}
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
  cat "$BASELINE_SCHEMA" | docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T postgres \
    psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-bb}" -d "${POSTGRES_DB:-bbexchange}" >/dev/null
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T postgres \
    psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-bb}" -d "${POSTGRES_DB:-bbexchange}" \
    -c "insert into schema_migrations(version) values('0000_phase1_schema') on conflict do nothing;" >/dev/null
fi

if [ -d "$MIGRATIONS_DIR" ]; then
  for f in $(find "$MIGRATIONS_DIR" -maxdepth 1 -type f -name '*.sql' | sort); do
    v="$(basename "$f")"
    applied="$(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T postgres \
      psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-bb}" -d "${POSTGRES_DB:-bbexchange}" -tAc \
      "select 1 from schema_migrations where version='${v}' limit 1;" | tr -d '[:space:]')"
    if [ "$applied" = "1" ]; then
      echo "db_migrate: skip $v"
      continue
    fi
    echo "db_migrate: apply $v"
    cat "$f" | docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T postgres \
      psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-bb}" -d "${POSTGRES_DB:-bbexchange}" >/dev/null
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T postgres \
      psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-bb}" -d "${POSTGRES_DB:-bbexchange}" \
      -c "insert into schema_migrations(version) values('${v}');" >/dev/null
  done
fi

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

chmod +x scripts/db_migrate.sh scripts/db_backup.sh

if [[ ! -f ".env.prod" ]]; then
  cat > .env.prod <<EOF
POSTGRES_USER=bb
POSTGRES_PASSWORD=$(openssl rand -hex 16)
POSTGRES_DB=bbexchange
STORAGE_MODE=${STORAGE_MODE}
ENABLE_BROWSER_EXECUTION=${ENABLE_BROWSER}
ENABLE_GOOGLE_ADS_MUTATION=false
AUTH_SECRET=$(openssl rand -hex 32)
CREDENTIAL_SECRET=$(openssl rand -hex 32)
IMAGE_REGISTRY=${IMAGE_REGISTRY}
API_IMAGE=${API_IMAGE}
WORKER_IMAGE=${WORKER_IMAGE}
IMAGE_TAG=${IMAGE_TAG}
SELF_UPDATE_ENABLED=true
SELF_UPDATE_MODE=image
SELF_UPDATE_REPO_DIR=/workspace
SELF_UPDATE_IMAGE_COMPOSE_FILE=deploy/docker-compose.image.yml
SELF_UPDATE_IMAGE_CHANNEL_TAG=${UPDATE_CHANNEL_TAG}
SELF_UPDATE_HELPER_IMAGE=docker:27-cli
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

ensure_env_var "IMAGE_REGISTRY" "${IMAGE_REGISTRY}"
ensure_env_var "API_IMAGE" "${API_IMAGE}"
ensure_env_var "WORKER_IMAGE" "${WORKER_IMAGE}"
ensure_env_var "IMAGE_TAG" "${IMAGE_TAG}"
ensure_env_var "STORAGE_MODE" "${STORAGE_MODE}"
ensure_env_var "ENABLE_BROWSER_EXECUTION" "${ENABLE_BROWSER}"
ensure_env_var "SELF_UPDATE_ENABLED" "true"
ensure_env_var "SELF_UPDATE_MODE" "image"
ensure_env_var "SELF_UPDATE_REPO_DIR" "/workspace"
ensure_env_var "SELF_UPDATE_IMAGE_COMPOSE_FILE" "deploy/docker-compose.image.yml"
ensure_env_var "SELF_UPDATE_IMAGE_CHANNEL_TAG" "${UPDATE_CHANNEL_TAG}"
ensure_env_var "SELF_UPDATE_HELPER_IMAGE" "docker:27-cli"

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

echo ""
echo "Install complete."
echo "Status: docker compose --env-file .env.prod -f deploy/docker-compose.image.yml ps"
if [[ "${SSL_MODE}" == "on" || "${SSL_MODE}" == "auto" ]]; then
  echo "URL: https://${DOMAIN}"
else
  echo "URL: http://<YOUR_VPS_PUBLIC_IP>"
fi




