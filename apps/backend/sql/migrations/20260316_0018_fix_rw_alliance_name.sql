update alliances
set alliance_name = 'Rewardoo',
    updated_at = now()
where alliance_code = 'RW'
  and alliance_name in ('Rewardful', 'RW', '');
