create table if not exists alliances (
  id uuid primary key default gen_random_uuid(),
  alliance_code varchar(32) not null unique,
  alliance_name varchar(255) not null,
  description text not null default '',
  logo_url text not null default '',
  admin_url text not null default '',
  remark text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_alliances_code on alliances(alliance_code);
create index if not exists idx_alliances_updated_at on alliances(updated_at desc);

create table if not exists alliance_accounts (
  id uuid primary key default gen_random_uuid(),
  alliance_id uuid not null references alliances(id) on delete cascade,
  account_name varchar(255) not null,
  remark text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_alliance_accounts_alliance_id on alliance_accounts(alliance_id);
create index if not exists idx_alliance_accounts_updated_at on alliance_accounts(updated_at desc);

create table if not exists merchants (
  id uuid primary key default gen_random_uuid(),
  name varchar(255) not null,
  country varchar(64) not null default '',
  state varchar(64) not null default '',
  city varchar(128) not null default '',
  website text not null default '',
  remark text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_merchants_name on merchants(name);
create index if not exists idx_merchants_updated_at on merchants(updated_at desc);

create table if not exists offers (
  id uuid primary key default gen_random_uuid(),
  name varchar(255) not null,
  merchant_id uuid not null references merchants(id) on delete restrict,
  offer_url text not null,
  alliance_id uuid not null references alliances(id) on delete restrict,
  alliance_account_id uuid not null references alliance_accounts(id) on delete restrict,
  countries jsonb not null default '[]'::jsonb,
  remark text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_offers_alliance_id on offers(alliance_id);
create index if not exists idx_offers_alliance_account_id on offers(alliance_account_id);
create index if not exists idx_offers_merchant_id on offers(merchant_id);
create index if not exists idx_offers_updated_at on offers(updated_at desc);

create table if not exists ad_hourly_stats (
  id uuid primary key default gen_random_uuid(),
  task_code varchar(32) not null,
  stat_date date not null,
  stat_hour smallint not null,
  mcc_id varchar(64) not null default '',
  customer_id varchar(64) not null,
  campaign_id varchar(64) not null,
  campaign_name varchar(255) not null default '',
  cost numeric(18,6) not null default 0,
  cpc numeric(18,6) not null default 0,
  clicks integer not null default 0,
  ctr numeric(18,6) not null default 0,
  impressions integer not null default 0,
  currency_code varchar(16) not null default '',
  updated_at timestamptz not null default now(),
  unique(task_code, stat_date, stat_hour, customer_id, campaign_id)
);

create index if not exists idx_ad_hourly_task_date on ad_hourly_stats(task_code, stat_date);
create index if not exists idx_ad_hourly_updated_at on ad_hourly_stats(updated_at desc);

create table if not exists affiliate_conversions (
  id uuid primary key default gen_random_uuid(),
  alliance_code varchar(32) not null,
  unique_id varchar(128) not null,
  task_code varchar(32) not null,
  order_id varchar(128) not null,
  sale_amount numeric(18,6) not null default 0,
  commission_amount numeric(18,6) not null default 0,
  commission_status varchar(64) not null,
  txn_date date not null,
  updated_date date not null,
  alliance_account_id uuid null references alliance_accounts(id) on delete set null,
  currency_code varchar(16) not null default '',
  raw_payload jsonb not null default '{}'::jsonb,
  ingested_at timestamptz not null default now(),
  unique(alliance_code, unique_id)
);

create index if not exists idx_affiliate_task_date on affiliate_conversions(task_code, txn_date);
create index if not exists idx_affiliate_updated_date on affiliate_conversions(updated_date desc);

create table if not exists db_backup_configs (
  id int primary key default 1,
  enabled boolean not null default false,
  schedule_cron varchar(64) not null default '0 3 * * *',
  google_drive_folder_id varchar(255) not null default '',
  retention_days int not null default 30,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint chk_db_backup_singleton check (id = 1)
);

insert into db_backup_configs(id) values (1)
on conflict (id) do nothing;

create table if not exists db_backup_jobs (
  id uuid primary key default gen_random_uuid(),
  started_at timestamptz not null default now(),
  finished_at timestamptz null,
  status varchar(32) not null,
  file_path text not null default '',
  file_size bigint not null default 0,
  google_drive_file_id varchar(255) not null default '',
  message text not null default ''
);

create index if not exists idx_db_backup_jobs_started_at on db_backup_jobs(started_at desc);
