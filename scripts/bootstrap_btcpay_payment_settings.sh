#!/usr/bin/env bash
set -euo pipefail

COMPOSE_FILE="${1:-deploy/docker-compose.admin.image.yml}"
ENV_FILE="${2:-.env.admin.prod}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "[btcpay-bootstrap] env file not found: ${ENV_FILE}"
  exit 0
fi

set -a
. "./${ENV_FILE}"
set +a

trim_trailing_slash() {
  local v="${1:-}"
  echo "${v%/}"
}

BTCPAY_BASE_URL_TEST="$(trim_trailing_slash "${BTCPAY_BASE_URL_TEST:-}")"
BTCPAY_BASE_URL_LIVE="$(trim_trailing_slash "${BTCPAY_BASE_URL_LIVE:-}")"
BTCPAY_STORE_ID_TEST="${BTCPAY_STORE_ID_TEST:-}"
BTCPAY_STORE_ID_LIVE="${BTCPAY_STORE_ID_LIVE:-}"
BTCPAY_API_KEY_TEST="${BTCPAY_API_KEY_TEST:-}"
BTCPAY_API_KEY_LIVE="${BTCPAY_API_KEY_LIVE:-}"
BTCPAY_WEBHOOK_SECRET_TEST="${BTCPAY_WEBHOOK_SECRET_TEST:-${CONTROL_PLANE_SHARED_KEY:-}}"
BTCPAY_WEBHOOK_SECRET_LIVE="${BTCPAY_WEBHOOK_SECRET_LIVE:-${BTCPAY_WEBHOOK_SECRET_TEST}}"
BTCPAY_USDT_CURRENCY_CODE_TEST="${BTCPAY_USDT_CURRENCY_CODE_TEST:-USDT_TRON}"
BTCPAY_USDT_CURRENCY_CODE_LIVE="${BTCPAY_USDT_CURRENCY_CODE_LIVE:-USDT_TRON}"

PAYLOAD_JSON="$(
cat <<EOF
{
  "btcpayBaseUrlTest":"${BTCPAY_BASE_URL_TEST}",
  "btcpayStoreIdTest":"${BTCPAY_STORE_ID_TEST}",
  "btcpayApiKeyTest":"${BTCPAY_API_KEY_TEST}",
  "btcpayWebhookSecretTest":"${BTCPAY_WEBHOOK_SECRET_TEST}",
  "btcpayUsdtCurrencyCodeTest":"${BTCPAY_USDT_CURRENCY_CODE_TEST}",
  "btcpayBaseUrlLive":"${BTCPAY_BASE_URL_LIVE}",
  "btcpayStoreIdLive":"${BTCPAY_STORE_ID_LIVE}",
  "btcpayApiKeyLive":"${BTCPAY_API_KEY_LIVE}",
  "btcpayWebhookSecretLive":"${BTCPAY_WEBHOOK_SECRET_LIVE}",
  "btcpayUsdtCurrencyCodeLive":"${BTCPAY_USDT_CURRENCY_CODE_LIVE}"
}
EOF
)"

echo "[btcpay-bootstrap] write BTCPay test/live settings into control-plane runtime..."
docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" exec -T \
  -e BTCPAY_BOOTSTRAP_PAYLOAD="${PAYLOAD_JSON}" \
  api_admin sh -lc "node -e \"(async()=>{const payload=JSON.parse(process.env.BTCPAY_BOOTSTRAP_PAYLOAD||'{}'); const store=require('/app/apps/backend/src/billingOpsStore'); await store.savePaymentSettings(payload); const masked=await store.getPaymentSettings({masked:true}); console.log(JSON.stringify({ok:true,item:masked},null,2));})().catch((e)=>{console.error(e); process.exit(1);});\""

echo "[btcpay-bootstrap] done."
