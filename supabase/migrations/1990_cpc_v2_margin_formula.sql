-- PLAN 8.8: the club's rating formula (cpc-v2). A player's change in a match depends on their own rating and the score margin:
--     new rating = rating + K * (own points - opponent points) / T        (the opponent gets the opposite sign)
-- where the rating is the player's own, or 3.500 when they have none (NR); T is the target game points of the match's scoring
-- rule; and K depends on the player's completed rated matches before the match:
--     0-5: 0.250 (provisional)   6-15: 0.150   16-30: 0.100   31+: 0.050
-- Singles and Doubles are counted separately. For a match of several games the margin is the points difference over all games
-- divided by T times the number of games. As before, each player's changes over the division are added to the rating they
-- started the division with (frozen at the draw) and applied once at finalization, clamped to 2.000-8.000 and rounded to
-- three decimals. A player with no rating no longer blocks a draw: they start at 3.500 and are rated by the division.
-- cpc-v1 (migrations 1830-1890) remains the version of anything already calculated.

do $$
declare c record;
begin
  for c in
    select conrelid::regclass::text as tbl, conname from pg_constraint
    where contype = 'c' and conrelid in ('public.division_cpc_rating_snapshots'::regclass, 'public.member_cpc_rating_history'::regclass)
      and pg_get_constraintdef(oid) like '%algorithm_version%'
  loop
    execute format('alter table %s drop constraint %I', c.tbl, c.conname);
  end loop;
end $$;
alter table public.division_cpc_rating_snapshots add constraint division_cpc_rating_snapshots_algorithm_chk check (algorithm_version in ('cpc-v1', 'cpc-v2'));
alter table public.member_cpc_rating_history add constraint member_cpc_rating_history_algorithm_chk check (algorithm_version in ('cpc-v1', 'cpc-v2'));
alter table public.division_cpc_rating_snapshots alter column algorithm_version set default 'cpc-v2';
alter table public.member_cpc_rating_history alter column algorithm_version set default 'cpc-v2';

create or replace function core.cpc_rating_k(p_prior_matches integer) returns numeric
language plpgsql immutable parallel safe set search_path = '' as $$
begin
  if p_prior_matches is null or p_prior_matches < 0 then
    raise exception 'a valid completed-match count is required' using errcode = '22023';
  end if;
  return case when p_prior_matches <= 5 then 0.250 when p_prior_matches <= 15 then 0.150 when p_prior_matches <= 30 then 0.100 else 0.050 end;
end $$;

create or replace function core.cpc_margin_delta(p_points_for integer, p_points_against integer, p_target integer, p_games integer, p_prior_matches integer)
returns numeric
language plpgsql immutable parallel safe set search_path = '' as $$
begin
  if p_points_for is null or p_points_against is null or p_points_for < 0 or p_points_against < 0
     or p_target is null or p_target < 1 or p_games is null or p_games < 1 then
    raise exception 'valid played-match points, target points and game count are required' using errcode = '22023';
  end if;
  -- keep precision here: the changes of a division are added, then clamped and rounded once
  return core.cpc_rating_k(p_prior_matches) * (p_points_for - p_points_against)::numeric / (p_target::numeric * p_games);
end $$;
revoke all on function core.cpc_rating_k(integer), core.cpc_margin_delta(integer, integer, integer, integer, integer) from public, anon, authenticated;
grant execute on function core.cpc_rating_k(integer), core.cpc_margin_delta(integer, integer, integer, integer, integer) to service_role;
comment on function core.cpc_margin_delta(integer, integer, integer, integer, integer) is
  'CPC cpc-v2 match change: K(completed matches) * (points for - points against) / (target points * games). Private engine helper.';

create or replace function core.cpc_division_outcomes(p_division_id text)
returns table (member_id text, entry_id text, starting_points numeric, prior_count integer, matches_played integer,
  raw_delta numeric, division_points numeric, points_delta numeric)
language sql stable security definer set search_path = '' as $$
  with eligible as (
    select m.id as match_id, m.entry_a_id, m.entry_b_id,
      row_number() over (order by s.stage_no, m.round_no, m.match_no, m.id) as seq,
      (select sum(g.score_a) from public.match_games g where g.match_id = m.id) as pts_a,
      (select sum(g.score_b) from public.match_games g where g.match_id = m.id) as pts_b,
      (core.match_scoring_rule(m.id) ->> 'points_per_game')::integer as target,
      (select count(*) from public.match_games g where g.match_id = m.id)::integer as games
    from public.matches m join public.division_stages s on s.id = m.division_stage_id
    where s.division_id = p_division_id and m.status = 'completed'
      and m.entry_a_id is not null and m.entry_b_id is not null
      and exists (select 1 from public.match_games g where g.match_id = m.id)
      and exists (select 1 from public.division_cpc_rating_snapshots x where x.division_id = p_division_id and x.entry_id = m.entry_a_id)
      and exists (select 1 from public.division_cpc_rating_snapshots x where x.division_id = p_division_id and x.entry_id = m.entry_b_id)
  ), sides as (
    select e.match_id, e.seq, e.entry_a_id as own, e.entry_b_id as opp, e.pts_a as pf, e.pts_b as pa, e.target, e.games from eligible e
    union all
    select e.match_id, e.seq, e.entry_b_id, e.entry_a_id, e.pts_b, e.pts_a, e.target, e.games from eligible e
  ), players as (
    select sn.member_id, sn.entry_id, sn.starting_points, sn.prior_eligible_match_count
    from public.division_cpc_rating_snapshots sn
    where sn.division_id = p_division_id and sn.member_id is not null
  ), per_match as (
    select p.member_id, p.entry_id, p.starting_points, p.prior_eligible_match_count,
      core.cpc_margin_delta(
        sd.pf::integer, sd.pa::integer, sd.target, sd.games,
        p.prior_eligible_match_count + (row_number() over (partition by p.member_id order by sd.seq))::integer - 1) as delta
    from players p join sides sd on sd.own = p.entry_id
  ), summed as (
    select pl.member_id, pl.entry_id, pl.starting_points, pl.prior_eligible_match_count,
      count(pm.delta)::integer as n, coalesce(sum(pm.delta), 0) as raw
    from players pl left join per_match pm on pm.member_id = pl.member_id
    group by pl.member_id, pl.entry_id, pl.starting_points, pl.prior_eligible_match_count
  )
  select su.member_id, su.entry_id, su.starting_points, su.prior_eligible_match_count, su.n, su.raw,
    core.cpc_rating_points(su.starting_points + su.raw),
    core.cpc_rating_points(su.starting_points + su.raw) - su.starting_points
  from summed su
$$;

create or replace function core.freeze_division_cpc_ratings(p_division_id text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  dv public.divisions; snapshot_count integer; active_entries integer; player_entries integer; missing integer;
begin
  select * into dv from public.divisions where id = p_division_id for update;
  if not found then raise exception 'division not found' using errcode = '22023'; end if;
  select count(*) into snapshot_count from public.division_cpc_rating_snapshots where division_id = dv.id;
  if snapshot_count > 0 then
    return jsonb_build_object('division_id', dv.id, 'snapshots', snapshot_count, 'replayed', true);
  end if;
  select count(*) into active_entries from public.entries where division_id = dv.id and status = 'active';
  select count(distinct x.entry_id) into player_entries from (
    select em.entry_id from public.entry_members em join public.entries e on e.id = em.entry_id
      where e.division_id = dv.id and e.status = 'active'
    union all
    select eg.entry_id from public.entry_guests eg join public.entries e on e.id = eg.entry_id
      where e.division_id = dv.id and e.status = 'active'
  ) x;
  if active_entries = 0 or player_entries <> active_entries then
    raise exception 'every active entry needs a player before the division rating snapshot' using errcode = '22023';
  end if;
  -- a player with no rating starts at 3.500 (cpc-v2); the division gives them their first rating
  with player_inputs as (
    select e.id as entry_id, e.unit_id, em.member_id, null::text as participant_id,
      coalesce(mr.points, 3.500) as starting_points, coalesce(mr.eligible_match_count, 0) as prior_eligible_match_count
    from public.entries e join public.entry_members em on em.entry_id = e.id
    left join public.member_cpc_ratings mr on mr.member_id = em.member_id and mr.discipline = dv.format and mr.deleted_at is null
    where e.division_id = dv.id and e.status = 'active'
    union all
    select e.id, e.unit_id, null::text, eg.participant_id, coalesce(gr.points, 3.500), 0
    from public.entries e join public.entry_guests eg on eg.entry_id = e.id
    left join public.event_participant_cpc_ratings gr on gr.participant_id = eg.participant_id and gr.discipline = dv.format and gr.deleted_at is null
    where e.division_id = dv.id and e.status = 'active'
  ), strengths as (
    select entry_id, round(avg(starting_points), 3)::numeric(4,3) as team_strength from player_inputs group by entry_id
  )
  insert into public.division_cpc_rating_snapshots(org_id, unit_id, division_id, entry_id, member_id, participant_id, discipline,
    starting_points, prior_eligible_match_count, team_strength)
  select dv.org_id, p.unit_id, dv.id, p.entry_id, p.member_id, p.participant_id, dv.format,
    p.starting_points, p.prior_eligible_match_count, s.team_strength
  from player_inputs p join strengths s on s.entry_id = p.entry_id;
  select count(*) into snapshot_count from public.division_cpc_rating_snapshots where division_id = dv.id;
  perform core.write_audit(dv.org_id, 'cpc_rating.snapshot', 'public.division_cpc_rating_snapshots', dv.id, null,
    jsonb_build_object('division_id', dv.id, 'snapshots', snapshot_count, 'discipline', dv.format, 'algorithm', 'cpc-v2'));
  return jsonb_build_object('division_id', dv.id, 'snapshots', snapshot_count, 'replayed', false);
end $$;

create or replace function core.apply_cpc_points(p_division_id text, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  dv public.divisions;
  o record;
  h public.member_cpc_rating_history;
  cur public.member_cpc_ratings;
  mr public.member_ranks;
  v_actor text := core.current_profile_id();
  v_rev integer;
  v_old_rank text;
  v_rank_after_rev text;
  v_new_rank text;
  v_pts numeric;
  v_cnt integer;
  v_other numeric;
  v_rh text;
  v_applied integer := 0;
  v_reversed integer := 0;
  v_unchanged integer := 0;
  v_ids text[];
  v_had boolean;
begin
  select * into dv from public.divisions where id = p_division_id for update;
  if not exists (select 1 from public.division_cpc_rating_snapshots where division_id = dv.id) then
    return jsonb_build_object('mode', 'legacy');
  end if;
  select coalesce(max(x.revision), 0) + 1 into v_rev from public.member_cpc_rating_history x
  where x.division_id = dv.id and x.entry_type = 'division_finalization';
  -- lock both rating rows of every player in a stable order so overlapping divisions apply relative changes without lost updates
  select array_agg(sn.member_id order by sn.member_id) into v_ids from public.division_cpc_rating_snapshots sn
  where sn.division_id = dv.id and sn.member_id is not null;
  -- a player with no rating record yet gets an empty one; the division then gives them their first rating
  insert into public.member_cpc_ratings(org_id, unit_id, member_id, discipline)
  select dv.org_id, null, sn.member_id, dv.format from public.division_cpc_rating_snapshots sn
  where sn.division_id = dv.id and sn.member_id is not null
    and not exists (select 1 from public.member_cpc_ratings r where r.member_id = sn.member_id and r.discipline = dv.format and r.deleted_at is null)
  on conflict (member_id, discipline) where deleted_at is null do nothing;
  perform 1 from public.member_cpc_ratings r where r.member_id = any(v_ids) and r.deleted_at is null order by r.member_id, r.discipline for update;

  for o in select * from core.cpc_division_outcomes(dv.id) order by member_id loop
    select * into cur from public.member_cpc_ratings r where r.member_id = o.member_id and r.discipline = dv.format and r.deleted_at is null;
    select r.points into v_other from public.member_cpc_ratings r
      where r.member_id = o.member_id and r.discipline <> dv.format and r.deleted_at is null;
    select * into mr from public.member_ranks k where k.member_id = o.member_id and k.deleted_at is null;
    v_old_rank := mr.rank_id;
    select x.* into h from public.member_cpc_rating_history x
    where x.division_id = dv.id and x.member_id = o.member_id and x.entry_type = 'division_finalization'
      and not exists (select 1 from public.member_cpc_rating_history y where y.reverses_id = x.id)
    order by x.revision desc limit 1;
    v_had := found;
    if v_had and h.points_delta = o.points_delta and h.match_count_delta = o.matches_played then
      v_unchanged := v_unchanged + 1;
      continue;
    end if;
    v_pts := coalesce(cur.points, o.starting_points); v_cnt := cur.eligible_match_count;
    if v_had then
      insert into public.member_cpc_rating_history(org_id, unit_id, member_id, rating_id, discipline, entry_type, division_id, reverses_id,
        points_before, points_after, match_count_before, match_count_after, points_delta, match_count_delta, revision, reason)
      values (dv.org_id, cur.unit_id, o.member_id, cur.id, dv.format, 'reversal', dv.id, h.id,
        v_pts, core.cpc_rating_points(v_pts - h.points_delta), v_cnt, greatest(v_cnt - h.match_count_delta, 0),
        -h.points_delta, -h.match_count_delta, h.revision, 'Reversed after a correction: ' || coalesce(p_reason, ''));
      v_pts := core.cpc_rating_points(v_pts - h.points_delta);
      v_cnt := greatest(v_cnt - h.match_count_delta, 0);
      v_reversed := v_reversed + 1;
    end if;
    v_rank_after_rev := coalesce(case when v_had then core.cpc_rank_for_points(dv.org_id, greatest(v_pts, coalesce(v_other, v_pts))) end, v_old_rank);
    insert into public.member_cpc_rating_history(org_id, unit_id, member_id, rating_id, discipline, entry_type, division_id,
      points_before, points_after, match_count_before, match_count_after, points_delta, match_count_delta, revision, reason, meta)
    values (dv.org_id, cur.unit_id, o.member_id, cur.id, dv.format, 'division_finalization', dv.id,
      v_pts, core.cpc_rating_points(v_pts + o.points_delta), v_cnt, v_cnt + o.matches_played, o.points_delta, o.matches_played, v_rev,
      coalesce(p_reason, 'Division finalized'),
      jsonb_build_object('starting_points', o.starting_points, 'prior_count', o.prior_count, 'raw_delta', o.raw_delta,
        'division_points', o.division_points));
    v_pts := core.cpc_rating_points(v_pts + o.points_delta);
    v_cnt := v_cnt + o.matches_played;
    update public.member_cpc_ratings set points = v_pts, eligible_match_count = v_cnt, source = 'division_finalization',
      assessed_at = now(), assessed_by = coalesce(v_actor, cur.assessed_by) where id = cur.id;

    -- the club rank follows the higher of the member's ratings; the previous live rank row of this division is reversed first
    v_new_rank := core.cpc_rank_for_points(dv.org_id, greatest(v_pts, coalesce(v_other, v_pts)));
    if v_had then
      for v_rh in select x.id from public.rank_history x
        where x.division_id = dv.id and x.member_id = o.member_id and x.reverses_id is null
          and not exists (select 1 from public.rank_history y where y.reverses_id = x.id)
      loop
        insert into public.rank_history(org_id, member_id, from_rank_id, to_rank_id, division_id, event_id, reason, reverses_id, revision)
        values (dv.org_id, o.member_id, v_old_rank, v_rank_after_rev, dv.id, dv.event_id,
          'Reversed after a correction: ' || coalesce(p_reason, ''), v_rh,
          (select x.revision from public.rank_history x where x.id = v_rh));
      end loop;
      v_old_rank := v_rank_after_rev;
    end if;
    insert into public.rank_history(org_id, member_id, from_rank_id, to_rank_id, division_id, event_id, reason, revision)
    values (dv.org_id, o.member_id, v_old_rank, v_new_rank, dv.id, dv.event_id,
      format('%s rating %s (%s%s)', initcap(dv.format), to_char(v_pts, 'FM9.000'), case when o.points_delta >= 0 then '+' else '' end,
        to_char(o.points_delta, 'FM0.000')),
      v_rev);
    if mr.id is null then
      insert into public.member_ranks(org_id, member_id, rank_id, source_division_id) values (dv.org_id, o.member_id, v_new_rank, dv.id);
    elsif mr.rank_id <> v_new_rank then
      update public.member_ranks set rank_id = v_new_rank, set_by_rule_id = null, source_division_id = dv.id where id = mr.id;
    end if;
    v_applied := v_applied + 1;
  end loop;
  return jsonb_build_object('mode', 'points', 'discipline', dv.format, 'revision', v_rev, 'applied', v_applied,
    'reversed', v_reversed, 'unchanged', v_unchanged);
end $$;

notify pgrst, 'reload schema';
