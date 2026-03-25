alter table if exists tasks
  add column if not exists alliance_id uuid null references alliances(id) on delete set null;

alter table if exists tasks
  add column if not exists alliance_account_id uuid null references alliance_accounts(id) on delete set null;

alter table if exists tasks
  add column if not exists merchant_id uuid null references merchants(id) on delete set null;

alter table if exists tasks
  add column if not exists offer_id uuid null references offers(id) on delete set null;

create index if not exists idx_tasks_alliance_id on tasks(alliance_id);
create index if not exists idx_tasks_alliance_account_id on tasks(alliance_account_id);
create index if not exists idx_tasks_merchant_id on tasks(merchant_id);
create index if not exists idx_tasks_offer_id on tasks(offer_id);
