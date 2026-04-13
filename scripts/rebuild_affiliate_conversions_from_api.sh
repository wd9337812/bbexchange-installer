#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-.env.prod}"
MODE="${2:-dry-run}" # dry-run | apply
INCREMENTAL_DAYS="${3:-3650}"
RECONCILE_DAYS="${4:-3650}"
PAGE_SIZE="${5:-1000}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "[rebuild] env file not found: ${ENV_FILE}"
  exit 1
fi

if [[ "${MODE}" != "dry-run" && "${MODE}" != "apply" ]]; then
  echo "[rebuild] MODE must be dry-run or apply"
  exit 1
fi

set -a
# shellcheck disable=SC1090
. "${ENV_FILE}"
set +a

echo "[rebuild] mode=${MODE} incremental_days=${INCREMENTAL_DAYS} reconcile_days=${RECONCILE_DAYS} page_size=${PAGE_SIZE}"
node scripts/rebuild_affiliate_conversions_from_api.js \
  --mode "${MODE}" \
  --incremental-days "${INCREMENTAL_DAYS}" \
  --reconcile-days "${RECONCILE_DAYS}" \
  --page-size "${PAGE_SIZE}"

