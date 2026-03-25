alter table if exists google_ads_service_accounts
  add column if not exists developer_token text not null default '';
