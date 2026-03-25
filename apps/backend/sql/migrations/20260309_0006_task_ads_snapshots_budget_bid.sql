alter table if exists tasks
  add column if not exists ads_account_name_snapshot varchar(255) not null default '';

alter table if exists tasks
  add column if not exists ads_campaign_name_snapshot varchar(255) not null default '';

alter table if exists tasks
  add column if not exists ads_bid_ceiling_usd numeric(18,6) null;

alter table if exists tasks
  add column if not exists ads_budget_usd numeric(18,6) null;

create index if not exists idx_tasks_ads_account_name_snapshot on tasks(ads_account_name_snapshot);
create index if not exists idx_tasks_ads_campaign_name_snapshot on tasks(ads_campaign_name_snapshot);
