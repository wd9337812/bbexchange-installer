alter table if exists ai_config
  add column if not exists postback_llm_enabled boolean not null default true;
