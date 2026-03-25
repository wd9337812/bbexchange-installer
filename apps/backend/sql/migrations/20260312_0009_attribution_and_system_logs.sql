alter table if exists ad_hourly_stats
  add column if not exists mapped boolean not null default true,
  add column if not exists unmapped_reason text not null default '',
  add column if not exists mapped_at timestamptz null;

update ad_hourly_stats
set mapped = case when coalesce(task_code, '') <> '' then true else false end
where mapped is null;

alter table if exists ad_hourly_stats
  alter column task_code drop not null;

alter table if exists ad_hourly_stats
  drop constraint if exists ad_hourly_stats_task_code_stat_date_stat_hour_customer_id_campaign_id_key;

create unique index if not exists uq_ad_hourly_stats_natural
  on ad_hourly_stats(stat_date, stat_hour, customer_id, campaign_id);

alter table if exists affiliate_conversions
  add column if not exists mapped boolean not null default true,
  add column if not exists unmapped_reason text not null default '',
  add column if not exists mapped_at timestamptz null,
  add column if not exists parse_mode varchar(16) not null default 'rule',
  add column if not exists parse_confidence numeric(5,2) null;

update affiliate_conversions
set mapped = case when coalesce(task_code, '') <> '' then true else false end
where mapped is null;

alter table if exists affiliate_conversions
  alter column task_code drop not null;

create index if not exists idx_ad_hourly_mapped on ad_hourly_stats(mapped, stat_date desc);
create index if not exists idx_affiliate_mapped on affiliate_conversions(mapped, txn_date desc);

create table if not exists system_logs (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  log_type varchar(32) not null,
  level varchar(16) not null,
  title_zh varchar(255) not null,
  message_zh text not null default '',
  task_id uuid null,
  task_code varchar(32) null,
  module varchar(64) not null default '',
  trace_id varchar(64) not null default '',
  payload_json jsonb not null default '{}'::jsonb,
  meta_json jsonb not null default '{}'::jsonb
);

create index if not exists idx_system_logs_created_at on system_logs(created_at desc);
create index if not exists idx_system_logs_type_level on system_logs(log_type, level, created_at desc);
create index if not exists idx_system_logs_task on system_logs(task_code, created_at desc);

create table if not exists system_log_configs (
  id int primary key default 1,
  retention_days int not null default 30,
  auto_cleanup_enabled boolean not null default true,
  updated_at timestamptz not null default now(),
  constraint chk_system_log_singleton check (id = 1)
);

insert into system_log_configs(id) values (1)
on conflict (id) do nothing;
