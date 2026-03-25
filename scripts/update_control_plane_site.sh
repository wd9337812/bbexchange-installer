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
REQUIRED_FREE_GB="${REQUIRED_FREE_GB:-4}"
REQUIRED_FREE_INODE_PERCENT="${REQUIRED_FREE_INODE_PERCENT:-10}"
AUTO_CLEANUP="${AUTO_CLEANUP:-true}"
DRY_RUN="${DRY_RUN:-false}"
INSTALLER_RAW_BASE_DEFAULT="https://raw.githubusercontent.com/wd9337812/bbexchange-installer/main"

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

bool_true() {
  local v="${1:-}"
  v="$(echo "${v}" | tr '[:upper:]' '[:lower:]')"
  [[ "${v}" == "1" || "${v}" == "true" || "${v}" == "yes" || "${v}" == "on" ]]
}

check_path_capacity() {
  local path="$1"
  local required_kb="$2"
  local required_inode_percent="$3"
  local label="$4"
  local avail_kb
  local inode_total
  local inode_avail
  local inode_free_percent
  avail_kb="$(df -Pk "${path}" | awk 'NR==2 {print $4}')"
  inode_total="$(df -Pi "${path}" | awk 'NR==2 {print $2}')"
  inode_avail="$(df -Pi "${path}" | awk 'NR==2 {print $4}')"
  avail_kb="${avail_kb:-0}"
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

  echo "[preflight] start safe cleanup (without volume prune)..."
  docker container prune -f || true
  docker network prune -f || true
  docker builder prune -af || true
  docker image prune -af || true
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

self_update_ops_assets() {
  local base_url="$1"
  local tmp
  if ! command -v curl >/dev/null 2>&1; then
    echo "[update] curl not found, skip ops-assets self-update."
    return 0
  fi
  echo "[update] sync control-plane ops assets from: ${base_url}"
  mkdir -p deploy scripts
  tmp="$(mktemp)"

  fetch_one() {
    local rel="$1"
    if curl -fsSL "${base_url}/${rel}" -o "${tmp}"; then
      mv "${tmp}" "${rel}"
      echo "[update] ${rel} sync ok"
    else
      echo "[update] ${rel} keep local"
    fi
  }

  fetch_one "deploy/docker-compose.admin.image.yml"
  fetch_one "scripts/db_migrate.sh"
  fetch_one "scripts/db_backup.sh"
  fetch_one "scripts/update_control_plane_site.sh"
  rm -f "${tmp}" >/dev/null 2>&1 || true
  chmod +x scripts/db_migrate.sh scripts/db_backup.sh scripts/update_control_plane_site.sh >/dev/null 2>&1 || true
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

INSTALLER_RAW_BASE="$(read_env "SELF_UPDATE_INSTALLER_RAW_BASE" "${ENV_FILE}")"
INSTALLER_RAW_BASE="${INSTALLER_RAW_BASE:-${INSTALLER_RAW_BASE_DEFAULT}}"
self_update_ops_assets "${INSTALLER_RAW_BASE}"

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

if ! run_preflight_upgrade; then
  code=$?
  echo "[update] preflight failed with code=${code}"
  exit "${code}"
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
