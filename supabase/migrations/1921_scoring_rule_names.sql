-- 1920 kept the two old rules whose values already match the club list; give them the club's spelling.
update public.scoring_rules
set name = case lower(name) when 'single game to 11' then 'Single Game to 11' else 'Single Game to 15' end
where deleted_at is null and lower(name) in ('single game to 11', 'single game to 15')
  and name not in ('Single Game to 11', 'Single Game to 15');
