#!/usr/bin/env bash
set -Eeuo pipefail

TARGET_TAG="${1:-}"
COMPOSE_FILE="${COMPOSE_FILE:-deploy/docker-compose.image.yml}"
ENV_FILE="${ENV_FILE:-.env.prod}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAST_TAG_FILE="${REPO_DIR}/apps/backend/data/last_good_image_tag.txt"
RESOURCE_BACKUP="${REPO_DIR}/apps/backend/data/last_good_resource_env.txt"

cd "${REPO_DIR}"
command -v flock >/dev/null || { echo '[rollback] flock is required';exit 34; }
exec 9>"${REPO_DIR}/.bb-update.lock"
flock -w 5 9 || { echo '[rollback] another install/update is running';exit 34; }

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "env file not found: ${ENV_FILE}"
  exit 1
fi

if [[ -z "${TARGET_TAG}" ]]; then
  if [[ -f "${REPO_DIR}/apps/backend/data/previous_verified_image_tag.txt" ]];then
    TARGET_TAG="$(cat "${REPO_DIR}/apps/backend/data/previous_verified_image_tag.txt")"
  elif [[ -f "${LAST_TAG_FILE}" ]]; then
    echo "[rollback] legacy tag is an unverified candidate; verify the intended version before switching." >&2
    echo "Candidate: $(cat "${LAST_TAG_FILE}")" >&2
    exit 35
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
  capture_runtime_resource_env "${ENV_FILE}" "${RESOURCE_BACKUP}.rollback-attempt"
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

ALLOW_LEGACY_READINESS=true bash scripts/wait_runtime_ready.sh
verified_current="$(cat apps/backend/data/current_verified_image_tag.txt 2>/dev/null || true)"
if [[ -n "${verified_current}" && "${verified_current}" != "${TARGET_TAG}" ]];then
  printf '%s\n' "${verified_current}" > apps/backend/data/previous_verified_image_tag.txt.tmp
  mv apps/backend/data/previous_verified_image_tag.txt.tmp apps/backend/data/previous_verified_image_tag.txt
  if [[ -f apps/backend/data/current_verified_resource_env.txt ]] && grep -qx "# verified_image_tag=${verified_current}" apps/backend/data/current_verified_resource_env.txt;then
    cp -p apps/backend/data/current_verified_resource_env.txt "${RESOURCE_BACKUP}"
  elif [[ "${verified_current}" == "${CURRENT_TAG}" && -f "${RESOURCE_BACKUP}.rollback-attempt" ]];then cp -p "${RESOURCE_BACKUP}.rollback-attempt" "${RESOURCE_BACKUP}";fi
fi
if declare -F capture_runtime_resource_env >/dev/null;then
  capture_runtime_resource_env "${ENV_FILE}" apps/backend/data/current_verified_resource_env.txt.values
  { printf '# verified_image_tag=%s\n' "${TARGET_TAG}";cat apps/backend/data/current_verified_resource_env.txt.values; } > apps/backend/data/current_verified_resource_env.txt.tmp
  mv apps/backend/data/current_verified_resource_env.txt.tmp apps/backend/data/current_verified_resource_env.txt
fi
printf '%s\n' "${TARGET_TAG}" > apps/backend/data/current_verified_image_tag.txt.tmp
mv apps/backend/data/current_verified_image_tag.txt.tmp apps/backend/data/current_verified_image_tag.txt
echo "[rollback] success: IMAGE_TAG=${TARGET_TAG}"
trap - ERR
