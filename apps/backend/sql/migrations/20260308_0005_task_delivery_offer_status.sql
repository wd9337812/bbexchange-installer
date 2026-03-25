alter table if exists tasks
  add column if not exists delivery_status varchar(32) not null default '测试中';

create index if not exists idx_tasks_delivery_status on tasks(delivery_status);
