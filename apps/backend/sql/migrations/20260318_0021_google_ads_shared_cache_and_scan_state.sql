create table if not exists google_ads_shared_cache (
  scope text not null,
  cache_key text not null,
  service_account_id uuid,
  data_json jsonb not null default '{}'::jsonb,
  expire_at timestamptz not null,
  updated_at timestamptz not null default now(),
  primary key(scope, cache_key)
);

create index if not exists idx_google_ads_shared_cache_expire
  on google_ads_shared_cache(expire_at);

create table if not exists google_ads_account_scan_state (
  id int primary key,
  last_summary_updated_at timestamptz,
  last_full_scan_at timestamptz,
  updated_at timestamptz not null default now()
);

insert into google_ads_account_scan_state(id)
values (1)
on conflict (id) do nothing;

create table if not exists google_ads_account_alert_pending (
  service_account_id uuid not null,
  mcc_id text not null default '',
  customer_id text not null default '',
  row_json jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key(service_account_id, mcc_id, customer_id)
);

create index if not exists idx_google_ads_account_alert_pending_updated
  on google_ads_account_alert_pending(updated_at desc);

