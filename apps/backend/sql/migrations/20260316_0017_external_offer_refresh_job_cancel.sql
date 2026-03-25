alter table if exists external_offer_refresh_jobs
  add column if not exists cancel_requested boolean not null default false;
