#!/usr/bin/env bash
set -euo pipefail

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
  local channel_base channel_name channel_url resolved
  channel_base="$(sed -n 's/^SELF_UPDATE_CHANNEL_BASE=//p' "${ENV_FILE}" | head -n 1)"
  channel_name="$(sed -n 's/^SELF_UPDATE_IMAGE_CHANNEL=//p' "${ENV_FILE}" | head -n 1)"
  channel_url="$(sed -n 's/^SELF_UPDATE_IMAGE_CHANNEL_URL=//p' "${ENV_FILE}" | head -n 1)"
  channel_base="${channel_base:-${CHANNEL_BASE_DEFAULT}}"
  channel_name="${CHANNEL_NAME_OVERRIDE:-${channel_name:-stable}}"
  if [[ -z "${channel_url}" ]]; then
    channel_url="${channel_base%/}/${channel_name}"
  fi
  resolved="$(curl -fsSL --max-time 10 "${channel_url}" 2>/dev/null | tr -d '\r' | head -n 1 || true)"
  if [[ "${resolved}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    TARGET_TAG="${resolved}"
    echo "[update] resolved image tag from channel (${channel_name}): ${TARGET_TAG}"
    return 0
  fi
  return 1
}

if [[ -z "${TARGET_TAG}" ]]; then
  if ! resolve_target_tag_from_channel; then
    TARGET_TAG="$(sed -n 's/^SELF_UPDATE_IMAGE_CHANNEL_TAG=//p' "${ENV_FILE}" | head -n 1)"
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
write_env_stamp="${TARGET_TAG}-$(date +%s)"
if grep -q '^FRONTEND_BUILD_ID=' "${ENV_FILE}"; then
  sed -i "s/^FRONTEND_BUILD_ID=.*/FRONTEND_BUILD_ID=${write_env_stamp}/" "${ENV_FILE}"
else
  echo "FRONTEND_BUILD_ID=${write_env_stamp}" >> "${ENV_FILE}"
fi

echo "[update] pull images: ${TARGET_TAG}"
docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" pull api worker

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
docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" up -d --force-recreate api worker caddy

echo "[update] health check"
curl -fsS --max-time 10 http://127.0.0.1/api/health >/dev/null

echo "[update] success: IMAGE_TAG=${TARGET_TAG}"
api_cid="$(docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" ps -q api 2>/dev/null || true)"
worker_cid="$(docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" ps -q worker 2>/dev/null || true)"
api_started="$(docker inspect -f '{{.State.StartedAt}}' "${api_cid}" 2>/dev/null || true)"
worker_started="$(docker inspect -f '{{.State.StartedAt}}' "${worker_cid}" 2>/dev/null || true)"
api_digest="$(docker inspect --format='{{index .RepoDigests 0}}' "${API_IMAGE_REF}" 2>/dev/null || true)"
worker_digest="$(docker inspect --format='{{index .RepoDigests 0}}' "${WORKER_IMAGE_REF}" 2>/dev/null || true)"
echo "[summary] api image id=${after_api_id} started_at=${api_started} digest=${api_digest:-unknown}"
echo "[summary] worker image id=${after_worker_id} started_at=${worker_started} digest=${worker_digest:-unknown}"
