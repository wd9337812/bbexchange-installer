alter table if exists alliances
  add column if not exists is_system_default boolean not null default false;

alter table if exists alliance_accounts
  add column if not exists api_token text not null default '',
  add column if not exists token_updated_at timestamptz null,
  add column if not exists token_status varchar(16) not null default 'unknown';

create index if not exists idx_alliance_accounts_token_status on alliance_accounts(token_status);

create table if not exists external_offer_pool (
  id uuid primary key default gen_random_uuid(),
  alliance_code varchar(32) not null,
  alliance_account_id uuid not null references alliance_accounts(id) on delete cascade,
  external_offer_id varchar(128) not null,
  offer_name varchar(255) not null,
  tracking_url text not null default '',
  final_url text not null default '',
  site_url text not null default '',
  domain text not null default '',
  commission_type varchar(32) not null default '',
  commission_value numeric(18,6) not null default 0,
  commission_text text not null default '',
  country varchar(64) not null default '',
  support_region text not null default '',
  primary_region varchar(64) not null default '',
  relationship varchar(64) not null default '',
  status varchar(64) not null default '',
  is_runnable boolean not null default false,
  not_runnable_reason text not null default '',
  source_updated_at timestamptz null,
  raw_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(alliance_account_id, external_offer_id)
);

create index if not exists idx_external_offer_pool_runnable on external_offer_pool(is_runnable);
create index if not exists idx_external_offer_pool_alliance_code on external_offer_pool(alliance_code);
create index if not exists idx_external_offer_pool_updated_at on external_offer_pool(updated_at desc);

create table if not exists external_offer_refresh_jobs (
  id uuid primary key default gen_random_uuid(),
  trigger_type varchar(16) not null default 'manual',
  alliance_code varchar(32) not null default '',
  alliance_account_id uuid null references alliance_accounts(id) on delete set null,
  status varchar(16) not null default 'running',
  started_at timestamptz not null default now(),
  finished_at timestamptz null,
  fetched_count integer not null default 0,
  upserted_count integer not null default 0,
  runnable_count integer not null default 0,
  failed_count integer not null default 0,
  error_message text not null default '',
  detail_json jsonb not null default '{}'::jsonb
);

create index if not exists idx_external_offer_refresh_jobs_started_at on external_offer_refresh_jobs(started_at desc);

create table if not exists automation_global_configs (
  id int primary key default 1,
  enabled boolean not null default true,
  external_offer_refresh_hours integer not null default 1,
  default_visit_frequency_sec integer not null default 20,
  default_replace_every_visits integer not null default 1,
  ad_account_max_running_campaigns integer not null default 30,
  ad_account_min_balance_usd numeric(18,6) not null default 20,
  default_cpc_cap_usd numeric(18,6) not null default 0.10,
  default_budget_usd numeric(18,6) not null default 5,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint chk_automation_global_singleton check (id = 1)
);

insert into automation_global_configs(id) values (1)
on conflict (id) do nothing;

create table if not exists automation_policies (
  id uuid primary key default gen_random_uuid(),
  policy_name varchar(128) not null,
  policy_type varchar(32) not null,
  enabled boolean not null default true,
  scope_type varchar(16) not null default 'global',
  priority integer not null default 100,
  condition_json jsonb not null default '{}'::jsonb,
  action_json jsonb not null default '{}'::jsonb,
  created_by varchar(64) not null default 'admin',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_automation_policies_type_enabled on automation_policies(policy_type, enabled);
create index if not exists idx_automation_policies_scope_priority on automation_policies(scope_type, priority desc);

create table if not exists automation_policy_bindings (
  id uuid primary key default gen_random_uuid(),
  policy_id uuid not null references automation_policies(id) on delete cascade,
  task_id uuid not null references tasks(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique(policy_id, task_id)
);

create index if not exists idx_automation_policy_bindings_task on automation_policy_bindings(task_id);

create table if not exists users (
  id uuid primary key default gen_random_uuid(),
  username varchar(64) not null unique,
  password_hash varchar(128) not null,
  display_name varchar(128) not null default '',
  status varchar(16) not null default 'active',
  last_login_at timestamptz null,
  created_by varchar(64) not null default 'system',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists roles (
  id uuid primary key default gen_random_uuid(),
  role_key varchar(64) not null unique,
  role_name varchar(128) not null,
  is_system boolean not null default false,
  description text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists permissions (
  id uuid primary key default gen_random_uuid(),
  perm_key varchar(128) not null unique,
  perm_name varchar(128) not null,
  perm_group varchar(64) not null default 'general',
  created_at timestamptz not null default now()
);

create table if not exists user_roles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  role_id uuid not null references roles(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique(user_id, role_id)
);

create table if not exists role_permissions (
  id uuid primary key default gen_random_uuid(),
  role_id uuid not null references roles(id) on delete cascade,
  permission_id uuid not null references permissions(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique(role_id, permission_id)
);

create table if not exists audit_logs (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  actor_username varchar(64) not null default 'system',
  action varchar(64) not null,
  target_type varchar(64) not null default '',
  target_id varchar(128) not null default '',
  result varchar(16) not null default 'success',
  message text not null default '',
  before_json jsonb not null default '{}'::jsonb,
  after_json jsonb not null default '{}'::jsonb,
  extra_json jsonb not null default '{}'::jsonb
);

create index if not exists idx_audit_logs_created_at on audit_logs(created_at desc);
create index if not exists idx_audit_logs_actor_action on audit_logs(actor_username, action);

insert into roles(role_key, role_name, is_system, description)
values
  ('admin', '管理员', true, '全量权限'),
  ('optimizer', '优化师', true, '任务与广告操作 + 数据查看'),
  ('analyst', '分析师', true, '只读数据')
on conflict (role_key) do nothing;

insert into permissions(perm_key, perm_name, perm_group)
values
  ('dashboard.view', '查看总览看板', 'dashboard'),
  ('task.view', '查看任务', 'task'),
  ('task.edit', '编辑任务', 'task'),
  ('task.operate', '操作任务状态', 'task'),
  ('ads.operate', '操作广告', 'ads'),
  ('report.view', '查看报表', 'report'),
  ('automation.view', '查看自动化', 'automation'),
  ('automation.execute', '执行自动化创建', 'automation'),
  ('automation.policy', '管理自动化策略', 'automation'),
  ('system.config', '系统配置', 'system'),
  ('rbac.manage', '管理子账号与权限', 'rbac')
on conflict (perm_key) do nothing;

insert into role_permissions(role_id, permission_id)
select r.id, p.id
from roles r
join permissions p on true
where r.role_key = 'admin'
on conflict do nothing;

insert into role_permissions(role_id, permission_id)
select r.id, p.id
from roles r
join permissions p on p.perm_key in ('dashboard.view','task.view','task.edit','task.operate','ads.operate','report.view','automation.view')
where r.role_key = 'optimizer'
on conflict do nothing;

insert into role_permissions(role_id, permission_id)
select r.id, p.id
from roles r
join permissions p on p.perm_key in ('dashboard.view','task.view','report.view','automation.view')
where r.role_key = 'analyst'
on conflict do nothing;

update alliances
set is_system_default = true,
    updated_at = now()
where alliance_code in ('LH','PM','PB','RW','LB','BSH','CG','CF','BL');
