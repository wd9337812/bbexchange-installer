alter table if exists automation_global_configs
  add column if not exists external_offer_max_pages integer not null default 20;
