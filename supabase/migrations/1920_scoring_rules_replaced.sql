-- The club's scoring rules are exactly these five. The previous rules are retired (soft-deleted; divisions keep their own
-- snapshot of the rule they were drawn with, so nothing that exists is affected), and the default for new divisions is
-- "Single Game to 11". Games are to 11, win by 2, unless the name says otherwise; a forfeit scores the points of one game.
select set_config('core.rpc', 'on', true);
update public.scoring_rules r
set is_active = false, deleted_at = now(), deleted_by = 'system', delete_reason = 'Replaced by the club scoring rule list'
where r.deleted_at is null and r.org_id = (select o.id from public.orgs o where o.code = 'cpc')
  and lower(r.name) not in ('single game to 11', 'single game to 15', 'single game to 21', 'best of 3 games', 'best of 5 games');
select set_config('core.rpc', 'off', true);

insert into public.scoring_rules (org_id, name, games_to_win, points_per_game, win_by, point_cap, forfeit_score)
select o.id, v.name, v.games_to_win, v.points, 2, null, v.points
from public.orgs o
cross join (values
  ('Single Game to 11', 1, 11),
  ('Single Game to 15', 1, 15),
  ('Single Game to 21', 1, 21),
  ('Best of 3 Games', 2, 11),
  ('Best of 5 Games', 3, 11)
) as v(name, games_to_win, points)
where o.code = 'cpc'
on conflict (org_id, (lower(name))) where deleted_at is null do nothing;

-- the setting is matched by name without regard to case; store the new spelling
update public.settings set value = '"Single Game to 11"'::jsonb
where key = 'events.default_scoring_rule' and unit_id is null and deleted_at is null
  and value is distinct from '"Single Game to 11"'::jsonb;
