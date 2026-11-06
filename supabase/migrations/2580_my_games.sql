-- My Games (Members Portal): the signed-in member's own matches, newest first: who they played, the games, the result, and
-- (when the division is rated) how much each finished match moved their rating, using the cpc-v2 margin formula and the
-- same match order as the division calculation. A member sees only their own matches.

create or replace function core.entry_players(p_entry_id text) returns text
language sql stable security definer set search_path = '' as $$
  select string_agg(x.name, ' & ' order by x.ord, x.name) from (
    select pe.display_name as name, 1 as ord
    from public.entry_members em
    join public.members m on m.id = em.member_id
    join public.persons pe on pe.id = m.person_id
    where em.entry_id = p_entry_id
    union all
    select pe.display_name, 2
    from public.entry_guests eg
    join public.event_participants ep on ep.id = eg.participant_id
    join public.persons pe on pe.id = ep.person_id
    where eg.entry_id = p_entry_id
  ) x
$$;
revoke all on function core.entry_players(text) from public, anon, authenticated;
grant execute on function core.entry_players(text) to service_role;

create or replace function core.my_games()
returns table (match_id text, played_at timestamptz, event_name text, division_name text, discipline text, stage_label text,
  match_no integer, status text, result text, my_team text, my_players text, opp_team text, opp_players text, games jsonb,
  rating_change numeric)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_me text;
begin
  select m.id into v_me from public.members m join public.profiles pr on pr.id = m.profile_id
  where pr.auth_user_id = (select auth.uid()) and pr.is_active and pr.deleted_at is null and m.deleted_at is null limit 1;
  if v_me is null then
    return;
  end if;
  return query
  with mine as (
    select em.entry_id, en.division_id
    from public.entry_members em join public.entries en on en.id = em.entry_id
    where em.member_id = v_me and en.status = 'active'
  ), ms as (
    select m.id as mid, m.round_no, m.match_no, m.group_label, m.status, m.winner_entry_id, m.scheduled_at, m.updated_at,
      s.id as stage_id, s.stage_no, s.stage_type, mine.division_id, mine.entry_id as my_entry,
      case when m.entry_a_id = mine.entry_id then m.entry_b_id else m.entry_a_id end as opp_entry,
      (m.entry_a_id = mine.entry_id) as is_a
    from mine
    join public.division_stages s on s.division_id = mine.division_id
    join public.matches m on m.division_stage_id = s.id and mine.entry_id in (m.entry_a_id, m.entry_b_id)
    where m.status in ('scheduled', 'in_progress', 'completed', 'forfeited')
      and m.entry_a_id is not null and m.entry_b_id is not null
  ), scored as (
    select ms.*,
      (select sum(case when ms.is_a then g.score_a else g.score_b end) from public.match_games g where g.match_id = ms.mid)::integer as pf,
      (select sum(case when ms.is_a then g.score_b else g.score_a end) from public.match_games g where g.match_id = ms.mid)::integer as pa,
      (select count(*) from public.match_games g where g.match_id = ms.mid)::integer as n_games,
      (core.match_scoring_rule(ms.mid) ->> 'points_per_game')::integer as target,
      (select max(x.round_no) from public.matches x where x.division_stage_id = ms.stage_id
         and x.group_label is not distinct from ms.group_label and x.status <> 'void')::integer as last_round,
      (ms.status = 'completed' and exists (select 1 from public.match_games g where g.match_id = ms.mid)
        and exists (select 1 from public.division_cpc_rating_snapshots x where x.division_id = ms.division_id and x.member_id = v_me)) as rated
    from ms
  ), ordered as (
    select sc.*,
      row_number() over (partition by sc.division_id, sc.rated order by sc.stage_no, sc.round_no, sc.match_no, sc.mid) as rn
    from scored sc
  )
  select o.mid,
    case when o.status in ('completed', 'forfeited') then o.updated_at else o.scheduled_at end,
    ev.name, dv.name, dv.format,
    case
      when o.group_label in ('H', 'L') then o.group_label || ' Bracket · ' || case o.last_round - o.round_no
        when 0 then 'Final' when 1 then 'Semifinals' when 2 then 'Quarterfinals' else 'Round ' || o.round_no end
      when o.group_label is not null then 'Group ' || o.group_label || ' · Round ' || o.round_no
      when o.stage_type = 'single_elimination' then case o.last_round - o.round_no
        when 0 then 'Final' when 1 then 'Semifinals' when 2 then 'Quarterfinals' else 'Round ' || o.round_no end
      else 'Round ' || o.round_no
    end,
    o.match_no::integer, o.status,
    case when o.status in ('completed', 'forfeited') then case when o.winner_entry_id = o.my_entry then 'win' else 'loss' end end,
    core.entry_name(o.my_entry), core.entry_players(o.my_entry), core.entry_name(o.opp_entry), core.entry_players(o.opp_entry),
    coalesce((select jsonb_agg(jsonb_build_object('me', case when o.is_a then g.score_a else g.score_b end,
                                                  'opp', case when o.is_a then g.score_b else g.score_a end) order by g.game_no)
              from public.match_games g where g.match_id = o.mid), '[]'::jsonb),
    case when o.rated and o.target is not null and o.n_games > 0 then
      core.cpc_margin_delta(o.pf, o.pa, o.target, o.n_games,
        (select x.prior_eligible_match_count from public.division_cpc_rating_snapshots x
          where x.division_id = o.division_id and x.member_id = v_me limit 1) + o.rn::integer - 1)
    end
  from ordered o
  join public.divisions dv on dv.id = o.division_id and dv.status in ('drawn', 'in_progress', 'finalized')
  join public.events ev on ev.id = dv.event_id
  order by 2 desc nulls last, 1;
end $$;
revoke all on function core.my_games() from public, anon, authenticated;
grant execute on function core.my_games() to authenticated, service_role;

create or replace function public.my_games()
returns table (match_id text, played_at timestamptz, event_name text, division_name text, discipline text, stage_label text,
  match_no integer, status text, result text, my_team text, my_players text, opp_team text, opp_players text, games jsonb,
  rating_change numeric)
language sql stable security invoker set search_path = '' as $$
  select * from core.my_games()
$$;
revoke all on function public.my_games() from public, anon, authenticated;
grant execute on function public.my_games() to authenticated, service_role;

notify pgrst, 'reload schema';
