#!/usr/bin/env bash
set -euo pipefail

TARGET_TAG="${1:-}"
COMPOSE_FILE="${COMPOSE_FILE:-deploy/docker-compose.image.yml}"
ENV_FILE="${ENV_FILE:-.env.prod}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAST_TAG_FILE="${REPO_DIR}/apps/backend/data/last_good_image_tag.txt"
INSTALLER_RAW_BASE_DEFAULT="https://raw.githubusercontent.com/wd9337812/bbexchange-installer/main"

cd "${REPO_DIR}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "env file not found: ${ENV_FILE}"
  exit 1
fi

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

  rm -f "${tmp}" >/dev/null 2>&1 || true
  chmod +x scripts/db_migrate.sh scripts/db_backup.sh scripts/rollback_image.sh scripts/update_image.sh >/dev/null 2>&1 || true
}

self_update_ops_assets

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

