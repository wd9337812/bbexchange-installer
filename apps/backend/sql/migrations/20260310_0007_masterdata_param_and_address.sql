alter table if exists alliances
  add column if not exists task_param_key varchar(64) not null default 'subid';

alter table if exists merchants
  add column if not exists company_address_path text not null default '';

create index if not exists idx_alliances_task_param_key on alliances(task_param_key);
