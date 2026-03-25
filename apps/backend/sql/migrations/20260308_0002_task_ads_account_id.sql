alter table if exists tasks
  add column if not exists ads_account_id varchar(64) not null default '';

