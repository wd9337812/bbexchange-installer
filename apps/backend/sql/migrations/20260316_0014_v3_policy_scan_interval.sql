alter table if exists automation_global_configs
  add column if not exists policy_scan_interval_minutes integer not null default 60;

