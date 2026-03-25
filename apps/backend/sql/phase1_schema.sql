-- Phase 1 PostgreSQL schema scaffold

create extension if not exists "pgcrypto";

create table if not exists tasks (
  id uuid primary key default gen_random_uuid(),
  task_code varchar(32) not null unique,
  name varchar(255) not null,
  alliance_name varchar(255) not null default '',
  alliance_account_name varchar(255) not null default '',
  offer_url text not null,
  target_domain varchar(255) not null,
  countries jsonb not null default '[]'::jsonb,
  device_types jsonb not null default '[]'::jsonb,
  referer text not null default '',
  timezone varchar(64) not null,
  schedule_days jsonb not null default '[0,1,2,3,4,5,6]'::jsonb,
  schedule_hours jsonb not null default '[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23]'::jsonb,
  visit_interval_sec int not null,
  replace_interval_sec int not null,
  ads_account_id varchar(64) not null default '',
  ads_mcc_id varchar(64) not null default '',
  ads_customer_id varchar(64) not null default '',
  ads_campaign_id varchar(64) not null default '',
  status varchar(16) not null,
  total_visits int not null default 0,
  total_replacements int not null default 0,
  last_run_at timestamptz null,
  last_error_code varchar(128) null,
  last_error_message text null,
  consecutive_failures int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_tasks_status on tasks(status);
create index if not exists idx_tasks_task_code on tasks(task_code);
create index if not exists idx_tasks_last_run_at on tasks(last_run_at);
create index if not exists idx_tasks_updated_at on tasks(updated_at desc);

create table if not exists task_runs (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references tasks(id) on delete cascade,
  run_type varchar(16) not null,
  success boolean not null,
  error_code varchar(128) null,
  error_message text null,
  started_at timestamptz not null,
  ended_at timestamptz not null,
  final_url text null,
  extracted_params jsonb null
);

create index if not exists idx_task_runs_task_id on task_runs(task_id);
create index if not exists idx_task_runs_started_at on task_runs(started_at desc);
create index if not exists idx_task_runs_run_type on task_runs(run_type);
create index if not exists idx_task_runs_success on task_runs(success);

create table if not exists google_ads_service_accounts (
  id uuid primary key default gen_random_uuid(),
  name varchar(255) not null,
  service_account_email varchar(255) not null,
  private_key text not null,
  developer_token text not null default '',
  customer_id varchar(64) not null,
  login_customer_id varchar(64) not null default '',
  enabled boolean not null default true,
  description text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table if exists google_ads_service_accounts
  add column if not exists developer_token text not null default '';

create table if not exists alerting_config (
  id int primary key default 1,
  feishu_webhook text not null default '',
  fail_threshold int not null default 3,
  dedupe_minutes int not null default 10,
  constraint chk_singleton check (id = 1)
);

insert into alerting_config(id) values (1)
on conflict (id) do nothing;

create table if not exists alert_state (
  key varchar(255) primary key,
  last_sent_at timestamptz not null
);

create table if not exists dynamic_ip_config (
  id int primary key default 1,
  enabled boolean not null default false,
  request_url text not null default '',
  country_param_name varchar(64) not null default 'country',
  parse_rule varchar(255) not null default 'data.ip',
  auth_header text not null default '',
  timeout_ms int not null default 5000,
  constraint chk_dynamic_ip_singleton check (id = 1)
);

insert into dynamic_ip_config(id) values (1)
on conflict (id) do nothing;
