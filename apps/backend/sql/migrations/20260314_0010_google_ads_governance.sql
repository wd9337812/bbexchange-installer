alter table if exists google_ads_service_accounts
  add column if not exists token_level text not null default 'EXPLORER';

create table if not exists google_ads_governance_configs (
  service_account_id uuid primary key references google_ads_service_accounts(id) on delete cascade,
  degrade_threshold_pct int not null default 80,
  hard_limit_threshold_pct int not null default 95,
  min_write_qps numeric(10,3) not null default 2,
  query_qps numeric(10,3) not null default 2,
  merge_enabled boolean not null default true,
  merge_window_ms int not null default 500,
  max_batch_ops int not null default 200,
  single_flight_enabled boolean not null default true,
  cache_prefer_enabled boolean not null default true,
  hierarchy_cache_ms int not null default 600000,
  account_summary_cache_ms int not null default 1800000,
  keyword_idea_cache_ms int not null default 86400000,
  budget_recommendation_cache_ms int not null default 86400000,
  refresh_min_interval_sec int not null default 3,
  queue_timeout_ms int not null default 15000,
  updated_at timestamptz not null default now()
);
