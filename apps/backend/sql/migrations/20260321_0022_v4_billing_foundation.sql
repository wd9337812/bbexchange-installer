create table if not exists billing_tenants (
  id uuid primary key default gen_random_uuid(),
  tenant_code varchar(64) not null unique,
  tenant_name varchar(255) not null default '',
  is_internal boolean not null default false,
  status varchar(32) not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_billing_tenants_status on billing_tenants(status);

create table if not exists billing_subscriptions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references billing_tenants(id) on delete cascade,
  plan_code varchar(32) not null default 'max',
  billing_cycle varchar(16) not null default 'monthly',
  status varchar(32) not null default 'active',
  trial_ends_at timestamptz null,
  current_period_start timestamptz null,
  current_period_end timestamptz null,
  provider varchar(32) not null default 'manual',
  provider_ref varchar(255) not null default '',
  metadata_json jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_billing_subscriptions_tenant_id on billing_subscriptions(tenant_id);
create index if not exists idx_billing_subscriptions_status on billing_subscriptions(status);

create table if not exists billing_plan_prices (
  id uuid primary key default gen_random_uuid(),
  plan_code varchar(32) not null,
  billing_cycle varchar(16) not null,
  price_usd numeric(18,2) not null default 0,
  enabled boolean not null default true,
  updated_by varchar(64) not null default 'system',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(plan_code, billing_cycle)
);

create table if not exists billing_runtime_settings (
  id int primary key default 1,
  billing_enforce boolean not null default false,
  trial_enabled boolean not null default true,
  trial_days int not null default 7,
  allow_offline_mark_paid boolean not null default true,
  usdt_provider varchar(32) not null default 'depay',
  stripe_enabled boolean not null default true,
  usdt_enabled boolean not null default true,
  offline_enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint chk_billing_runtime_singleton check (id = 1)
);

insert into billing_runtime_settings(
  id, billing_enforce, trial_enabled, trial_days, allow_offline_mark_paid, usdt_provider, stripe_enabled, usdt_enabled, offline_enabled
)
values (1, false, true, 7, true, 'depay', true, true, true)
on conflict (id) do nothing;

insert into billing_plan_prices(plan_code, billing_cycle, price_usd, enabled, updated_by)
values
  ('lite', 'monthly', 29.00, true, 'system'),
  ('lite', 'quarterly', 79.00, true, 'system'),
  ('lite', 'yearly', 299.00, true, 'system'),
  ('pro', 'monthly', 79.00, true, 'system'),
  ('pro', 'quarterly', 219.00, true, 'system'),
  ('pro', 'yearly', 799.00, true, 'system'),
  ('max', 'monthly', 149.00, true, 'system'),
  ('max', 'quarterly', 419.00, true, 'system'),
  ('max', 'yearly', 1499.00, true, 'system')
on conflict (plan_code, billing_cycle) do nothing;

insert into billing_tenants(tenant_code, tenant_name, is_internal, status)
values ('local', 'Default Tenant', false, 'active')
on conflict (tenant_code) do nothing;

insert into billing_subscriptions(
  tenant_id, plan_code, billing_cycle, status, current_period_start, current_period_end, provider, provider_ref
)
select t.id, 'max', 'monthly', 'active', now(), now() + interval '30 days', 'manual', 'bootstrap'
from billing_tenants t
where t.tenant_code = 'local'
  and not exists (
    select 1 from billing_subscriptions s where s.tenant_id = t.id
  );
