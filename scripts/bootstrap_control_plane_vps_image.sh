#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root (use: sudo bash scripts/bootstrap_control_plane_vps_image.sh)"
  exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

INSTALL_DIR="${INSTALL_DIR:-/opt/bbauto-control-plane}"
IMAGE_REGISTRY="${IMAGE_REGISTRY:-ghcr.io/wd9337812}"
API_IMAGE="${API_IMAGE:-bbexchange-api}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
TZ_VALUE="${TZ_VALUE:-Asia/Shanghai}"
APP_TIMEZONE_VALUE="${APP_TIMEZONE_VALUE:-Asia/Shanghai}"
SSL_MODE="${SSL_MODE:-auto}"
PUBLIC_DOMAIN="${PUBLIC_DOMAIN:-}"
ADMIN_DOMAIN="${ADMIN_DOMAIN:-}"
LICENSE_DOMAIN="${LICENSE_DOMAIN:-}"
EMAIL="${EMAIL:-}"
ADMIN_DEFAULT_PASSWORD="${ADMIN_DEFAULT_PASSWORD:-}"
ENV_FILE="${INSTALL_DIR}/.env.admin.prod"

to_lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
existing_env_value() {
  local key="$1"
  local file="$2"
  if [[ -f "$file" ]]; then
    sed -n "s/^${key}=//p" "$file" | head -n 1
  fi
}
random_hex() {
  local len="${1:-32}"
  openssl rand -hex "$len"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --image-registry) IMAGE_REGISTRY="$2"; shift 2 ;;
    --api-image) API_IMAGE="$2"; shift 2 ;;
    --image-tag) IMAGE_TAG="$2"; shift 2 ;;
    --ssl) SSL_MODE="$2"; shift 2 ;;
    --public-domain) PUBLIC_DOMAIN="$2"; shift 2 ;;
    --admin-domain) ADMIN_DOMAIN="$2"; shift 2 ;;
    --license-domain) LICENSE_DOMAIN="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --admin-password) ADMIN_DEFAULT_PASSWORD="$2"; shift 2 ;;
    *) shift ;;
  esac
done

SSL_MODE="$(to_lower "${SSL_MODE}")"
if [[ "${SSL_MODE}" != "on" && "${SSL_MODE}" != "off" && "${SSL_MODE}" != "auto" ]]; then
  echo "Invalid --ssl value: ${SSL_MODE}. Use on|off|auto."
  exit 1
fi

if [[ "${SSL_MODE}" == "auto" ]]; then
  echo "Control-plane deploy mode:"
  echo "  1) Domain + Auto SSL (Let's Encrypt)"
  echo "  2) HTTP only (IP mode)"
  read -rp "Choose [1/2] (default 1): " MODE_CHOICE
  MODE_CHOICE="${MODE_CHOICE:-1}"
  if [[ "${MODE_CHOICE}" == "2" ]]; then
    SSL_MODE="off"
  else
    SSL_MODE="on"
  fi
fi

if [[ "${SSL_MODE}" == "on" ]]; then
  if [[ -z "${PUBLIC_DOMAIN}" ]]; then
    read -rp "Input public website domain (e.g. bbauto.top): " PUBLIC_DOMAIN
  fi
  if [[ -z "${ADMIN_DOMAIN}" ]]; then
    read -rp "Input admin domain (e.g. admin.bbauto.top): " ADMIN_DOMAIN
  fi
  if [[ -z "${LICENSE_DOMAIN}" ]]; then
    read -rp "Input license domain (e.g. license.bbauto.top): " LICENSE_DOMAIN
  fi
  if [[ ! "${PUBLIC_DOMAIN}" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    echo "Invalid public domain: ${PUBLIC_DOMAIN}"
    exit 1
  fi
  if [[ ! "${ADMIN_DOMAIN}" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    echo "Invalid admin domain: ${ADMIN_DOMAIN}"
    exit 1
  fi
  if [[ ! "${LICENSE_DOMAIN}" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    echo "Invalid license domain: ${LICENSE_DOMAIN}"
    exit 1
  fi
  if [[ -z "${EMAIL}" ]]; then
    read -rp "Input email for Let's Encrypt (Enter to auto-generate): " EMAIL
  fi
  if [[ -z "${EMAIL}" ]]; then
    EMAIL="admin@${PUBLIC_DOMAIN}"
  fi
fi

if [[ -z "${ADMIN_DEFAULT_PASSWORD}" ]]; then
  ADMIN_DEFAULT_PASSWORD="$(existing_env_value "ADMIN_DEFAULT_PASSWORD" "$ENV_FILE")"
fi
if [[ -z "${ADMIN_DEFAULT_PASSWORD}" ]]; then
  ADMIN_DEFAULT_PASSWORD="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 14)"
fi
read -rp "Admin initial password [default: ${ADMIN_DEFAULT_PASSWORD}]: " ADMIN_PWD_INPUT
if [[ -n "${ADMIN_PWD_INPUT}" ]]; then
  ADMIN_DEFAULT_PASSWORD="${ADMIN_PWD_INPUT}"
fi

POSTGRES_PASSWORD_VALUE="$(existing_env_value "POSTGRES_PASSWORD" "$ENV_FILE")"
AUTH_SECRET_VALUE="$(existing_env_value "AUTH_SECRET" "$ENV_FILE")"
CREDENTIAL_SECRET_VALUE="$(existing_env_value "CREDENTIAL_SECRET" "$ENV_FILE")"
CONTROL_PLANE_SHARED_KEY_VALUE="$(existing_env_value "CONTROL_PLANE_SHARED_KEY" "$ENV_FILE")"
if [[ -z "${POSTGRES_PASSWORD_VALUE}" ]]; then POSTGRES_PASSWORD_VALUE="$(random_hex 16)"; fi
if [[ -z "${AUTH_SECRET_VALUE}" ]]; then AUTH_SECRET_VALUE="$(random_hex 32)"; fi
if [[ -z "${CREDENTIAL_SECRET_VALUE}" ]]; then CREDENTIAL_SECRET_VALUE="$(random_hex 32)"; fi
if [[ -z "${CONTROL_PLANE_SHARED_KEY_VALUE}" ]]; then CONTROL_PLANE_SHARED_KEY_VALUE="$(random_hex 32)"; fi

echo "[1/7] Installing runtime dependencies..."
apt-get update -y
apt-get install -y ca-certificates curl openssl

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
fi

if ! docker compose version >/dev/null 2>&1; then
  apt-get install -y docker-compose-plugin
fi

echo "[2/7] Preparing deployment directory..."
mkdir -p "${INSTALL_DIR}/deploy" "${INSTALL_DIR}/scripts" "${INSTALL_DIR}/apps/backend/data" "${INSTALL_DIR}/apps/backend/sql/migrations"

echo "[3/7] Copying deployment assets..."
cp -f "${REPO_DIR}/deploy/docker-compose.admin.image.yml" "${INSTALL_DIR}/deploy/docker-compose.admin.image.yml"
cp -f "${REPO_DIR}/scripts/db_migrate.sh" "${INSTALL_DIR}/scripts/db_migrate.sh"
cp -f "${REPO_DIR}/scripts/db_backup.sh" "${INSTALL_DIR}/scripts/db_backup.sh"
cp -rf "${REPO_DIR}/apps/backend/sql/migrations" "${INSTALL_DIR}/apps/backend/sql/" 2>/dev/null || true
cp -f "${REPO_DIR}/apps/backend/sql/phase1_schema.sql" "${INSTALL_DIR}/apps/backend/sql/phase1_schema.sql"
chmod +x "${INSTALL_DIR}/scripts/db_migrate.sh" "${INSTALL_DIR}/scripts/db_backup.sh"

echo "[4/7] Writing env file..."
cat > "${INSTALL_DIR}/.env.admin.prod" <<EOF
POSTGRES_USER=bb
POSTGRES_PASSWORD=${POSTGRES_PASSWORD_VALUE}
POSTGRES_DB=bbexchange
STORAGE_MODE=postgres
NODE_ENV=production
TZ=${TZ_VALUE}
APP_TIMEZONE=${APP_TIMEZONE_VALUE}
AUTH_SECRET=${AUTH_SECRET_VALUE}
CREDENTIAL_SECRET=${CREDENTIAL_SECRET_VALUE}
TENANT_CODE=admin-console
IMAGE_REGISTRY=${IMAGE_REGISTRY}
API_IMAGE=${API_IMAGE}
IMAGE_TAG=${IMAGE_TAG}
ADMIN_DEFAULT_PASSWORD=${ADMIN_DEFAULT_PASSWORD}
APP_SERVER_MODE=control
CONTROL_PLANE_SHARED_KEY=${CONTROL_PLANE_SHARED_KEY_VALUE}
EOF

echo "[5/7] Writing Caddy config..."
if [[ "${SSL_MODE}" == "on" ]]; then
  cat > "${INSTALL_DIR}/deploy/Caddyfile.admin" <<EOF
{
  email ${EMAIL}
}

${PUBLIC_DOMAIN} {
  encode gzip
  @deny_admin path /admin* /admin.html /admin-app.js /admin-styles.css
  respond @deny_admin 404
  reverse_proxy api_admin:3000
}

${ADMIN_DOMAIN} {
  encode gzip
  reverse_proxy api_admin:3000
}

${LICENSE_DOMAIN} {
  encode gzip
  reverse_proxy api_admin:3000
}
EOF
  ufw allow 80/tcp >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
else
  cat > "${INSTALL_DIR}/deploy/Caddyfile.admin" <<'EOF'
:80 {
  encode gzip
  reverse_proxy api_admin:3000
}
EOF
  ufw allow 80/tcp >/dev/null 2>&1 || true
fi

echo "[6/7] Starting containers and migrating schema..."
cd "${INSTALL_DIR}"
docker compose --env-file .env.admin.prod -f deploy/docker-compose.admin.image.yml up -d redis_admin postgres_admin
sh scripts/db_migrate.sh "deploy/docker-compose.admin.image.yml" ".env.admin.prod"
docker compose --env-file .env.admin.prod -f deploy/docker-compose.admin.image.yml pull api_admin || true
docker compose --env-file .env.admin.prod -f deploy/docker-compose.admin.image.yml up -d api_admin caddy_admin

echo "[7/7] Done."
echo ""
echo "Control-plane deployed."
if [[ "${SSL_MODE}" == "on" ]]; then
  echo "Website URL: https://${PUBLIC_DOMAIN}"
  echo "Admin URL: https://${ADMIN_DOMAIN}/admin"
  echo "License URL(for user instances): https://${LICENSE_DOMAIN}"
else
  echo "Website URL: http://<YOUR_VPS_IP>"
  echo "Admin URL: http://<YOUR_VPS_IP>/admin"
  echo "License URL(for user instances): http://<YOUR_VPS_IP>"
fi
echo "Admin username: admin"
echo "Admin initial password: ${ADMIN_DEFAULT_PASSWORD}"
echo "Control plane shared key: $(sed -n 's/^CONTROL_PLANE_SHARED_KEY=//p' .env.admin.prod | head -n 1)"
echo ""
echo "Compose status command:"
echo "  cd ${INSTALL_DIR} && docker compose --env-file .env.admin.prod -f deploy/docker-compose.admin.image.yml ps"
