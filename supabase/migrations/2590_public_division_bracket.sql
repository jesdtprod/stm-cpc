-- Public bracketing page (View Bracketing / View Final Results on a public event card): the standings and the matches of one
-- division, readable by visitors. Only divisions of the club's published events that have been drawn are shown. No ids of
-- people or entries are returned: sides are named by team and players, and a winner is "a" or "b".

create or replace function public.public_division_bracket(p_division_id text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  dv public.divisions;
  ev public.events;
  v_finished boolean;
  v_stages jsonb;
  v_matches jsonb;
  v_standings jsonb;
  v_places jsonb := '[]'::jsonb;
begin
  select d.* into dv from public.divisions d where d.id = p_division_id and d.status in ('drawn', 'in_progress', 'finalized');
  if not found then
    return null;
  end if;
  select e.* into ev from public.events e
  where e.id = dv.event_id and e.status in ('drawn', 'in_progress', 'completed')
    and e.org_id in (select o.id from public.orgs o where o.code = 'cpc' and o.deleted_at is null);
  if not found then
    return null;
  end if;
  v_finished := dv.status = 'finalized'
    or (exists (select 1 from public.division_stages s where s.division_id = dv.id and s.status = 'completed')
        and not exists (select 1 from public.division_stages s where s.division_id = dv.id and s.status not in ('completed', 'cancelled')));

  select coalesce(jsonb_agg(jsonb_build_object('stage_no', s.stage_no, 'stage_type', s.stage_type, 'status', s.status) order by s.stage_no), '[]'::jsonb)
    into v_stages from public.division_stages s where s.division_id = dv.id and s.status <> 'cancelled';

  select coalesce(jsonb_agg(jsonb_build_object(
      'stage_no', s.stage_no, 'stage_type', s.stage_type, 'round_no', m.round_no, 'match_no', m.match_no, 'group_label', m.group_label,
      'status', m.status,
      'a_name', core.entry_name(m.entry_a_id), 'a_players', core.entry_players(m.entry_a_id),
      'b_name', core.entry_name(m.entry_b_id), 'b_players', core.entry_players(m.entry_b_id),
      'a_label', m.meta ->> 'a_label', 'b_label', m.meta ->> 'b_label',
      'winner', case when m.winner_entry_id is null then null when m.winner_entry_id = m.entry_a_id then 'a' else 'b' end,
      'games', coalesce((select jsonb_agg(jsonb_build_object('a', g.score_a, 'b', g.score_b) order by g.game_no)
                         from public.match_games g where g.match_id = m.id), '[]'::jsonb))
    order by s.stage_no, m.group_label nulls first, m.round_no, m.match_no), '[]'::jsonb)
    into v_matches
  from public.matches m join public.division_stages s on s.id = m.division_stage_id
  where s.division_id = dv.id and m.status <> 'void' and s.status <> 'cancelled';

  -- league tables for round robin and pool play stages
  select coalesce(jsonb_agg(jsonb_build_object(
      'stage_no', s.stage_no, 'group_label', t.group_label, 'place', t.place, 'tied', t.tied,
      'name', t.entry_name, 'players', core.entry_players(t.entry_id),
      'played', t.played, 'wins', t.wins, 'losses', t.losses, 'points_for', t.points_for, 'points_against', t.points_against)
    order by s.stage_no, t.group_label nulls first, t.place), '[]'::jsonb)
    into v_standings
  from public.division_stages s
  cross join lateral core.stage_standings(s.id) t
  where s.division_id = dv.id and s.stage_type in ('round_robin', 'pool_play') and s.status <> 'cancelled';

  -- final placements once every stage is played (champions first)
  if v_finished then
    select coalesce(jsonb_agg(jsonb_build_object(
        'place', p.placement, 'tier', p.bracket_tier, 'result', p.bracket_result,
        'name', core.entry_name(p.entry_id), 'players', core.entry_players(p.entry_id))
      order by p.bracket_tier nulls first, p.placement), '[]'::jsonb)
      into v_places
    from core.compute_placements(dv.id) p;
  end if;

  return jsonb_build_object(
    'event_name', ev.name, 'starts_on', ev.starts_on, 'division_name', dv.name, 'discipline', dv.format,
    'status', dv.status, 'finished', v_finished,
    'stages', v_stages, 'matches', v_matches, 'standings', v_standings, 'placements', v_places);
end $$;
revoke all on function public.public_division_bracket(text) from public, anon, authenticated;
grant execute on function public.public_division_bracket(text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';
