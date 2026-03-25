alter table if exists automation_global_configs
  add column if not exists keyword_source varchar(32) not null default 'mixed',
  add column if not exists copy_source varchar(32) not null default 'ai';

create table if not exists automation_offer_cart_items (
  id uuid primary key default gen_random_uuid(),
  username varchar(64) not null,
  external_offer_id uuid not null references external_offer_pool(id) on delete cascade,
  selected_at timestamptz not null default now(),
  unique(username, external_offer_id)
);

create index if not exists idx_automation_offer_cart_items_user on automation_offer_cart_items(username, selected_at desc);

create table if not exists automation_create_jobs (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  started_at timestamptz null,
  finished_at timestamptz null,
  created_by varchar(64) not null default 'admin',
  status varchar(24) not null default 'queued',
  total_count integer not null default 0,
  running_count integer not null default 0,
  success_count integer not null default 0,
  failed_count integer not null default 0,
  cancelled_count integer not null default 0,
  trigger_source varchar(24) not null default 'manual',
  request_json jsonb not null default '{}'::jsonb,
  error_message text not null default ''
);

create index if not exists idx_automation_create_jobs_created_at on automation_create_jobs(created_at desc);
create index if not exists idx_automation_create_jobs_status on automation_create_jobs(status, created_at desc);

create table if not exists automation_create_job_items (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references automation_create_jobs(id) on delete cascade,
  external_offer_id uuid not null references external_offer_pool(id) on delete cascade,
  status varchar(24) not null default 'queued',
  task_id uuid null references tasks(id) on delete set null,
  task_code varchar(32) not null default '',
  error_code varchar(64) not null default '',
  error_message text not null default '',
  started_at timestamptz null,
  finished_at timestamptz null,
  payload_json jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(job_id, external_offer_id)
);

create index if not exists idx_automation_create_job_items_job on automation_create_job_items(job_id, created_at asc);
create index if not exists idx_automation_create_job_items_status on automation_create_job_items(status, updated_at desc);
