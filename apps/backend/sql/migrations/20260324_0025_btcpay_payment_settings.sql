-- V4.0.2: BTCPay Server payment settings (test/live)
alter table if exists billing_runtime_settings
  add column if not exists btcpay_base_url_test text,
  add column if not exists btcpay_store_id_test text,
  add column if not exists btcpay_api_key_test text,
  add column if not exists btcpay_webhook_secret_test text,
  add column if not exists btcpay_usdt_currency_code_test text default 'USDT_TRON',
  add column if not exists btcpay_base_url_live text,
  add column if not exists btcpay_store_id_live text,
  add column if not exists btcpay_api_key_live text,
  add column if not exists btcpay_webhook_secret_live text,
  add column if not exists btcpay_usdt_currency_code_live text default 'USDT_TRON';

update billing_runtime_settings
set usdt_provider = 'btcpay'
where id = 1
  and coalesce(nullif(trim(usdt_provider), ''), 'depay') = 'depay';
