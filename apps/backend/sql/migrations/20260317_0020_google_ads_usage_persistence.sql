create table if not exists google_ads_usage_events (
  id bigserial primary key,
  occurred_at timestamptz not null default now(),
  service_account_id uuid,
  mcc_id text not null default '',
  customer_id text not null default '',
  campaign_id text not null default '',
  api_category text not null default 'other',
  operation text not null default '',
  request_units int not null default 1,
  success boolean not null default true,
  error_code text not null default '',
  source_module text not null default ''
);

create index if not exists idx_google_ads_usage_events_occurred_at
  on google_ads_usage_events(occurred_at desc);
create index if not exists idx_google_ads_usage_events_service_account
  on google_ads_usage_events(service_account_id, occurred_at desc);

create table if not exists google_ads_usage_hourly (
  bucket_hour timestamptz not null,
  service_account_id uuid not null,
  api_category text not null default 'other',
  success boolean not null default true,
  request_units int not null default 0,
  query_units int not null default 0,
  write_units int not null default 0,
  error_count int not null default 0,
  primary key(bucket_hour, service_account_id, api_category, success)
);

create index if not exists idx_google_ads_usage_hourly_service_bucket
  on google_ads_usage_hourly(service_account_id, bucket_hour desc);

