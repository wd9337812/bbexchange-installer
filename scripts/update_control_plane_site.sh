#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root (use: sudo bash scripts/update_control_plane_site.sh)"
  exit 1
fi

INSTALL_DIR="${INSTALL_DIR:-/opt/bbauto-control-plane}"
ENV_FILE="${ENV_FILE:-.env.admin.prod}"
COMPOSE_FILE="${COMPOSE_FILE:-deploy/docker-compose.admin.image.yml}"

cd "${INSTALL_DIR}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "env file not found: ${INSTALL_DIR}/${ENV_FILE}"
  exit 1
fi

echo "[1/4] Pull latest control-plane api image..."
docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" pull api_admin

echo "[2/4] Run db migrations..."
sh scripts/db_migrate.sh "${COMPOSE_FILE}" "${ENV_FILE}"

echo "[3/4] Restart api + caddy..."
docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" up -d api_admin caddy_admin

echo "[4/4] Health check..."
curl -fsS http://127.0.0.1:3111/api/health >/dev/null

echo "Control-plane update complete."
