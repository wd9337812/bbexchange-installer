#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="${1:-deploy/docker-compose.admin.image.yml}"
ENV_FILE="${2:-.env.admin.prod}"
CLI_TENANT_CODE="${3:-}"
MODE="${MODE:-dry-run}" # dry-run | apply

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "[clear-billing] env file not found: ${ENV_FILE}"
  exit 1
fi

if [[ "${MODE}" != "dry-run" && "${MODE}" != "apply" ]]; then
  echo "[clear-billing] MODE must be dry-run or apply"
  exit 1
fi

set -a
# shellcheck disable=SC1090
. "${ENV_FILE}"
set +a

POSTGRES_USER="${POSTGRES_USER:-bb}"
POSTGRES_DB="${POSTGRES_DB:-bbexchange}"
TENANT_SQL_FILTER=""
TENANT_NOTE="ALL"

if [[ -n "${CLI_TENANT_CODE}" ]]; then
  if ! [[ "${CLI_TENANT_CODE}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "[clear-billing] invalid TENANT_CODE: ${CLI_TENANT_CODE}"
    exit 1
  fi
  TENANT_NOTE="${CLI_TENANT_CODE}"
  TENANT_SQL_FILTER="where tenant_id in (select id from billing_tenants where tenant_code='${CLI_TENANT_CODE}')"
fi

echo "[clear-billing] mode=${MODE} tenant=${TENANT_NOTE}"

read -r -d '' SQL_COUNT <<SQL || true
select 'billing_checkout_sessions' as table_name, count(*) as cnt from billing_checkout_sessions ${TENANT_SQL_FILTER}
union all
select 'billing_invoices', count(*) from billing_invoices ${TENANT_SQL_FILTER}
union all
select 'billing_payment_events', count(*) from billing_payment_events ${TENANT_SQL_FILTER}
union all
select 'billing_coupon_redemptions', count(*) from billing_coupon_redemptions ${TENANT_SQL_FILTER}
order by table_name;
SQL

echo "[clear-billing] current rows:"
docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" exec -T postgres_admin sh -lc \
  "psql -U '${POSTGRES_USER}' -d '${POSTGRES_DB}' -P pager=off -c \"${SQL_COUNT}\""

if [[ "${MODE}" == "dry-run" ]]; then
  echo "[clear-billing] dry-run finished. set MODE=apply to execute delete."
  exit 0
fi

echo "[clear-billing] applying delete..."
read -r -d '' SQL_DELETE <<SQL || true
begin;
delete from billing_payment_events ${TENANT_SQL_FILTER};
delete from billing_coupon_redemptions ${TENANT_SQL_FILTER};
delete from billing_invoices ${TENANT_SQL_FILTER};
delete from billing_checkout_sessions ${TENANT_SQL_FILTER};
commit;
SQL

docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" exec -T postgres_admin sh -lc \
  "psql -U '${POSTGRES_USER}' -d '${POSTGRES_DB}' -v ON_ERROR_STOP=1 -c \"${SQL_DELETE}\""

echo "[clear-billing] remaining rows:"
docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" exec -T postgres_admin sh -lc \
  "psql -U '${POSTGRES_USER}' -d '${POSTGRES_DB}' -P pager=off -c \"${SQL_COUNT}\""

echo "[clear-billing] done."
