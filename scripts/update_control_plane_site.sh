#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root (use: sudo bash scripts/update_control_plane_site.sh)"
  exit 1
fi

INSTALL_DIR="${INSTALL_DIR:-/opt/bbauto-control-plane}"
ENV_FILE="${ENV_FILE:-.env.admin.prod}"
COMPOSE_FILE="${COMPOSE_FILE:-deploy/docker-compose.admin.image.yml}"
TARGET_TAG="${1:-}"
LAST_TAG_FILE_REL="apps/backend/data/last_good_admin_image_tag.txt"
LAST_TAG_FILE="${INSTALL_DIR}/${LAST_TAG_FILE_REL}"

read_env() {
  local key="$1"
  local file="$2"
  sed -n "s/^${key}=//p" "$file" | head -n 1
}

write_env() {
  local key="$1"
  local value="$2"
  local file="$3"
  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

rollback() {
  local old_tag="$1"
  if [[ -z "$old_tag" ]]; then
    return 0
  fi
  echo "[rollback] reverting IMAGE_TAG to ${old_tag}"
  write_env "IMAGE_TAG" "${old_tag}" "${ENV_FILE}"
  docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" pull api_admin || true
  docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" up -d api_admin caddy_admin || true
}

cd "${INSTALL_DIR}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "env file not found: ${INSTALL_DIR}/${ENV_FILE}"
  exit 1
fi

CURRENT_TAG="$(read_env "IMAGE_TAG" "${ENV_FILE}")"
CURRENT_TAG="${CURRENT_TAG:-latest}"
if [[ -z "${TARGET_TAG}" ]]; then
  TARGET_TAG="${CURRENT_TAG}"
fi

IMAGE_REGISTRY="$(read_env "IMAGE_REGISTRY" "${ENV_FILE}")"
API_IMAGE="$(read_env "API_IMAGE" "${ENV_FILE}")"
IMAGE_REGISTRY="${IMAGE_REGISTRY:-ghcr.io/wd9337812}"
API_IMAGE="${API_IMAGE:-bbexchange-api}"
API_IMAGE_REF="${IMAGE_REGISTRY}/${API_IMAGE}:${TARGET_TAG}"

mkdir -p "$(dirname "${LAST_TAG_FILE}")"
if [[ -n "${CURRENT_TAG}" ]]; then
  echo "${CURRENT_TAG}" > "${LAST_TAG_FILE}"
fi

echo "[1/6] Backup control-plane data..."
sh scripts/db_backup.sh "${COMPOSE_FILE}" "${ENV_FILE}"

echo "[2/6] Pull target api image (${TARGET_TAG})..."
write_env "IMAGE_TAG" "${TARGET_TAG}" "${ENV_FILE}"
if ! docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" pull api_admin; then
  rollback "${CURRENT_TAG}"
  exit 1
fi

echo "[3/6] Run db migrations from image SQL..."
if ! SOURCE_IMAGE="${API_IMAGE_REF}" sh scripts/db_migrate.sh "${COMPOSE_FILE}" "${ENV_FILE}"; then
  rollback "${CURRENT_TAG}"
  exit 1
fi

echo "[4/6] Restart api + caddy..."
if ! docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" up -d api_admin caddy_admin; then
  rollback "${CURRENT_TAG}"
  exit 1
fi

echo "[5/6] Health check..."
if ! curl -fsS http://127.0.0.1:3111/api/health >/dev/null; then
  rollback "${CURRENT_TAG}"
  exit 1
fi
if ! curl -fsS http://127.0.0.1:3111/api/public/bootstrap-status >/dev/null; then
  rollback "${CURRENT_TAG}"
  exit 1
fi

echo "[6/6] Done."
echo "Control-plane update complete."
echo "Current tag: ${TARGET_TAG}"
