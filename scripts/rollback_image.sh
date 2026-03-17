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

if grep -q '^IMAGE_TAG=' "${ENV_FILE}"; then
  sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=${TARGET_TAG}/" "${ENV_FILE}"
else
  echo "IMAGE_TAG=${TARGET_TAG}" >> "${ENV_FILE}"
fi

docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" pull api worker
docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" up -d api worker caddy

curl -fsS --max-time 10 http://127.0.0.1/api/health >/dev/null
echo "[rollback] success: IMAGE_TAG=${TARGET_TAG}"
