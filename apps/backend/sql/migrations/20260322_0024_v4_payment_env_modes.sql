alter table billing_runtime_settings
  add column if not exists stripe_env varchar(16) not null default 'test',
  add column if not exists usdt_env varchar(16) not null default 'test';

alter table billing_runtime_settings
  add constraint chk_billing_runtime_stripe_env
  check (stripe_env in ('test', 'live'));

alter table billing_runtime_settings
  add constraint chk_billing_runtime_usdt_env
  check (usdt_env in ('test', 'live'));

alter table billing_runtime_settings
  add column if not exists stripe_publishable_key_test text not null default '',
  add column if not exists stripe_secret_key_test text not null default '',
  add column if not exists stripe_webhook_secret_test text not null default '',
  add column if not exists stripe_publishable_key_live text not null default '',
  add column if not exists stripe_secret_key_live text not null default '',
  add column if not exists stripe_webhook_secret_live text not null default '',
  add column if not exists usdt_api_key_test text not null default '',
  add column if not exists usdt_webhook_secret_test text not null default '',
  add column if not exists usdt_receive_address_test text not null default '',
  add column if not exists usdt_api_key_live text not null default '',
  add column if not exists usdt_webhook_secret_live text not null default '',
  add column if not exists usdt_receive_address_live text not null default '';
