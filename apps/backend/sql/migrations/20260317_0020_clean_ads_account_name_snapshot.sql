-- Clean historical polluted snapshots such as:
-- "AccountName|启动系列1|余额$18.81" -> "AccountName"
update tasks
set ads_account_name_snapshot = regexp_replace(ads_account_name_snapshot, '\|.*$', '')
where ads_account_name_snapshot like '%|%';

