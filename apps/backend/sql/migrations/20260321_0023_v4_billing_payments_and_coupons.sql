create table if not exists billing_coupons (
  id uuid primary key default gen_random_uuid(),
  code varchar(64) not null unique,
  discount_percent numeric(5,2) not null,
  coupon_type varchar(24) not null default 'one_time',
  duration varchar(24) not null default 'once',
  max_redemptions int null,
  redeemed_count int not null default 0,
  active boolean not null default true,
  expires_at timestamptz null,
  metadata_json jsonb not null default '{}'::jsonb,
  created_by varchar(64) not null default 'system',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_billing_coupons_active on billing_coupons(active);

create table if not exists billing_coupon_redemptions (
  id uuid primary key default gen_random_uuid(),
  coupon_id uuid not null references billing_coupons(id) on delete cascade,
  tenant_id uuid not null references billing_tenants(id) on delete cascade,
  checkout_session_id uuid null,
  amount_off_usd numeric(18,2) not null default 0,
  created_at timestamptz not null default now()
);

create index if not exists idx_billing_coupon_redemptions_coupon_id on billing_coupon_redemptions(coupon_id);
create index if not exists idx_billing_coupon_redemptions_tenant_id on billing_coupon_redemptions(tenant_id);

create table if not exists billing_checkout_sessions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references billing_tenants(id) on delete cascade,
  plan_code varchar(32) not null,
  billing_cycle varchar(16) not null,
  payment_method varchar(24) not null,
  coupon_code varchar(64) null,
  amount_usd numeric(18,2) not null,
  discount_usd numeric(18,2) not null default 0,
  final_amount_usd numeric(18,2) not null,
  status varchar(24) not null default 'pending',
  provider_ref varchar(255) not null default '',
  checkout_url text null,
  metadata_json jsonb not null default '{}'::jsonb,
  expires_at timestamptz null,
  paid_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_billing_checkout_sessions_tenant_id on billing_checkout_sessions(tenant_id);
create index if not exists idx_billing_checkout_sessions_status on billing_checkout_sessions(status);

alter table billing_runtime_settings
  add column if not exists stripe_publishable_key text not null default '',
  add column if not exists stripe_secret_key text not null default '',
  add column if not exists stripe_webhook_secret text not null default '',
  add column if not exists usdt_api_key text not null default '',
  add column if not exists usdt_webhook_secret text not null default '',
  add column if not exists usdt_receive_address text not null default '',
  add column if not exists offline_payment_note text not null default '';
