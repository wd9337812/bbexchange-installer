alter table if exists external_offer_pool
  add column if not exists is_active boolean not null default true,
  add column if not exists last_seen_at timestamptz null;

create index if not exists idx_external_offer_pool_active on external_offer_pool(is_active);

update external_offer_pool
set is_active = true
where is_active is distinct from true;
