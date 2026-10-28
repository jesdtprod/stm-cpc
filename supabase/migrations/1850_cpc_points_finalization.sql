-- PLAN 8.4c: CPC points replace H/L level movement at division finalization and corrections.
-- Activation is explicit: setting ranks.cpc_points_enabled (default false). A division uses points only if it has
-- frozen rating snapshots (taken at the draw while the setting is on and the event is not opted out). Divisions drawn
-- before activation, or opted-out events, keep the legacy rank movement. Placements and division_results are unchanged.

insert into public.settings (org_id, key, value)
select o.id, 'ranks.cpc_points_enabled', 'false'::jsonb from public.orgs o
on conflict (org_id, (coalesce(unit_id, '')), key) where deleted_at is null do nothing;

-- ---------------------------------------------------------------------------
-- history: relative deltas and revisions so corrections can reverse without losing later adjustments
-- ---------------------------------------------------------------------------
alter table public.member_cpc_rating_history
  add column points_delta numeric(5,3),
  add column match_count_delta integer,
  add column revision integer not null default 1 constraint member_cpc_rating_history_revision_chk check (revision >= 1),
  add constraint member_cpc_rating_history_reversal_chk check ((entry_type = 'reversal') = (reverses_id is not null));
create unique index member_cpc_rating_history_division_member_uq
  on public.member_cpc_rating_history (division_id, member_id, revision)
  where entry_type = 'division_finalization';
create unique index member_cpc_rating_history_reverses_uq
  on public.member_cpc_rating_history (reverses_id) where reverses_id is not null;

create or replace function core.cpc_points_enabled(p_org text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select s.value #>> '{}' = 'true' from public.settings s
    where s.org_id = p_org and s.unit_id is null and s.key = 'ranks.cpc_points_enabled' and s.deleted_at is null), false)
$$;

-- ---------------------------------------------------------------------------
-- freezing inputs: internal worker (no caller check) shared by the draw hook and the RPC
-- ---------------------------------------------------------------------------
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
  select count(*) into missing from (
    select mr.points from public.entries e join public.entry_members em on em.entry_id = e.id
      left join public.member_cpc_ratings mr on mr.member_id = em.member_id and mr.deleted_at is null
      where e.division_id = dv.id and e.status = 'active'
    union all
    select gr.points from public.entries e join public.entry_guests eg on eg.entry_id = e.id
      left join public.event_participant_cpc_ratings gr on gr.participant_id = eg.participant_id and gr.deleted_at is null
      where e.division_id = dv.id and e.status = 'active'
  ) v where v.points is null;
  if missing > 0 then
    raise exception 'every player needs assessed CPC points before the division starts (% missing)', missing using errcode = '22023';
  end if;
  with player_inputs as (
    select e.id as entry_id, e.unit_id, em.member_id, null::text as participant_id,
      mr.points as starting_points, mr.eligible_match_count as prior_eligible_match_count
    from public.entries e join public.entry_members em on em.entry_id = e.id
    join public.member_cpc_ratings mr on mr.member_id = em.member_id and mr.deleted_at is null
    where e.division_id = dv.id and e.status = 'active'
    union all
    select e.id, e.unit_id, null::text, eg.participant_id, gr.points, 0
    from public.entries e join public.entry_guests eg on eg.entry_id = e.id
    join public.event_participant_cpc_ratings gr on gr.participant_id = eg.participant_id and gr.deleted_at is null
    where e.division_id = dv.id and e.status = 'active'
  ), strengths as (
    select entry_id, round(avg(starting_points), 3)::numeric(4,3) as team_strength from player_inputs group by entry_id
  )
  insert into public.division_cpc_rating_snapshots(org_id, unit_id, division_id, entry_id, member_id, participant_id,
    starting_points, prior_eligible_match_count, team_strength)
  select dv.org_id, p.unit_id, dv.id, p.entry_id, p.member_id, p.participant_id,
    p.starting_points, p.prior_eligible_match_count, s.team_strength
  from player_inputs p join strengths s on s.entry_id = p.entry_id;
  select count(*) into snapshot_count from public.division_cpc_rating_snapshots where division_id = dv.id;
  perform core.write_audit(dv.org_id, 'cpc_rating.snapshot', 'public.division_cpc_rating_snapshots', dv.id, null,
    jsonb_build_object('division_id', dv.id, 'snapshots', snapshot_count, 'algorithm', 'cpc-v1'));
  return jsonb_build_object('division_id', dv.id, 'snapshots', snapshot_count, 'replayed', false);
end $$;
revoke all on function core.freeze_division_cpc_ratings(text) from public, anon, authenticated;
grant execute on function core.freeze_division_cpc_ratings(text) to service_role;

-- the 1840 RPC keeps its permission and status checks and delegates
create or replace function core.snapshot_division_cpc_ratings(p_division_id text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare dv public.divisions;
begin
  select * into dv from public.divisions where id = p_division_id;
  if core.current_profile_id() is null or not found or not core.has_permission(dv.org_id, null, 'scores.finalize') then
    raise exception 'not allowed to freeze CPC rating inputs' using errcode = '42501';
  end if;
  if dv.status not in ('drawn', 'in_progress', 'finalized') then
    raise exception 'CPC rating inputs can be frozen only after the draw' using errcode = '22023';
  end if;
  return core.freeze_division_cpc_ratings(dv.id);
end $$;

-- Freeze at the draw: a points-rated division cannot start unless every player has assessed points.
create or replace function core.tg_division_freeze_cpc() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'drawn' and old.status is distinct from 'drawn'
     and core.cpc_points_enabled(new.org_id)
     and exists (select 1 from public.events e where e.id = new.event_id and e.apply_cpc_rank_changes) then
    perform core.freeze_division_cpc_ratings(new.id);
  end if;
  return new;
end $$;
revoke all on function core.tg_division_freeze_cpc() from public, anon, authenticated;
create trigger c9_division_freeze_cpc after update of status on public.divisions
  for each row execute function core.tg_division_freeze_cpc();

-- ---------------------------------------------------------------------------
-- calculation from the frozen inputs and the played matches (read-only)
-- ---------------------------------------------------------------------------
-- Eligible: completed (not forfeited, cancelled or void), both sides known and frozen, at least one game played.
-- Order is stable across corrections (stage, round, match number); the count grows per player and each match counts once.
create or replace function core.cpc_division_outcomes(p_division_id text)
returns table (member_id text, entry_id text, starting_points numeric, prior_count integer, matches_played integer,
  raw_delta numeric, division_points numeric, points_delta numeric)
language sql stable security definer set search_path = '' as $$
  with eligible as (
    select m.id as match_id, m.entry_a_id, m.entry_b_id,
      row_number() over (order by s.stage_no, m.round_no, m.match_no, m.id) as seq,
      (select sum(g.score_a) from public.match_games g where g.match_id = m.id) as pts_a,
      (select sum(g.score_b) from public.match_games g where g.match_id = m.id) as pts_b
    from public.matches m join public.division_stages s on s.id = m.division_stage_id
    where s.division_id = p_division_id and m.status = 'completed'
      and m.entry_a_id is not null and m.entry_b_id is not null
      and exists (select 1 from public.match_games g where g.match_id = m.id)
      and exists (select 1 from public.division_cpc_rating_snapshots x where x.division_id = p_division_id and x.entry_id = m.entry_a_id)
      and exists (select 1 from public.division_cpc_rating_snapshots x where x.division_id = p_division_id and x.entry_id = m.entry_b_id)
  ), sides as (
    select e.match_id, e.seq, e.entry_a_id as own, e.entry_b_id as opp, e.pts_a as pf, e.pts_b as pa from eligible e
    union all
    select e.match_id, e.seq, e.entry_b_id, e.entry_a_id, e.pts_b, e.pts_a from eligible e
  ), players as (
    select sn.member_id, sn.entry_id, sn.starting_points, sn.prior_eligible_match_count
    from public.division_cpc_rating_snapshots sn
    where sn.division_id = p_division_id and sn.member_id is not null
  ), per_match as (
    select p.member_id, p.entry_id, p.starting_points, p.prior_eligible_match_count,
      core.cpc_rating_delta(
        (select x.team_strength from public.division_cpc_rating_snapshots x where x.division_id = p_division_id and x.entry_id = sd.own limit 1),
        (select x.team_strength from public.division_cpc_rating_snapshots x where x.division_id = p_division_id and x.entry_id = sd.opp limit 1),
        sd.pf::integer, sd.pa::integer,
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
revoke all on function core.cpc_division_outcomes(text) from public, anon, authenticated;
grant execute on function core.cpc_division_outcomes(text) to service_role;

-- exact rank for final points, from the club's rank bands (never guessed)
create or replace function core.cpc_rank_for_points(p_org text, p_points numeric) returns text
language plpgsql stable security definer set search_path = '' as $$
declare v_code text := core.cpc_rating_band_code(p_points); v_ids text[];
begin
  select array_agg(r.id order by r.id) into v_ids from public.ranks r
  join public.rank_ladders l on l.id = r.ladder_id and l.deleted_at is null
  where r.org_id = p_org and r.code = v_code and r.deleted_at is null
    and r.rating_min is not null and p_points between r.rating_min and r.rating_max;
  if v_ids is null or cardinality(v_ids) <> 1 then
    raise exception 'the club has no single rank band for % points', p_points using errcode = '22023';
  end if;
  return v_ids[1];
end $$;
revoke all on function core.cpc_rank_for_points(text, numeric) from public, anon, authenticated;
grant execute on function core.cpc_rank_for_points(text, numeric) to service_role;

-- ---------------------------------------------------------------------------
-- applying points (first finalization or a correction revision)
-- ---------------------------------------------------------------------------
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
  -- lock member rating rows in a stable order so overlapping divisions apply relative changes without lost updates
  select array_agg(sn.member_id order by sn.member_id) into v_ids from public.division_cpc_rating_snapshots sn
  where sn.division_id = dv.id and sn.member_id is not null;
  perform 1 from public.member_cpc_ratings r where r.member_id = any(v_ids) and r.deleted_at is null order by r.member_id for update;

  for o in select * from core.cpc_division_outcomes(dv.id) order by member_id loop
    select * into cur from public.member_cpc_ratings r where r.member_id = o.member_id and r.deleted_at is null;
    if not found or cur.points is null then
      raise exception 'member % has no CPC points to update', o.member_id using errcode = '22023';
    end if;
    select * into mr from public.member_ranks k where k.member_id = o.member_id and k.deleted_at is null;
    v_old_rank := mr.rank_id;
    -- the live (not reversed) entry of the previous revision, if any
    select x.* into h from public.member_cpc_rating_history x
    where x.division_id = dv.id and x.member_id = o.member_id and x.entry_type = 'division_finalization'
      and not exists (select 1 from public.member_cpc_rating_history y where y.reverses_id = x.id)
    order by x.revision desc limit 1;
    v_had := found;
    if v_had and h.points_delta = o.points_delta and h.match_count_delta = o.matches_played then
      v_unchanged := v_unchanged + 1;
      continue;
    end if;
    v_pts := cur.points; v_cnt := cur.eligible_match_count;
    if v_had then
      insert into public.member_cpc_rating_history(org_id, unit_id, member_id, rating_id, entry_type, division_id, reverses_id,
        points_before, points_after, match_count_before, match_count_after, points_delta, match_count_delta, revision, reason)
      values (dv.org_id, cur.unit_id, o.member_id, cur.id, 'reversal', dv.id, h.id,
        v_pts, core.cpc_rating_points(v_pts - h.points_delta), v_cnt, greatest(v_cnt - h.match_count_delta, 0),
        -h.points_delta, -h.match_count_delta, h.revision, 'Reversed after a correction: ' || coalesce(p_reason, ''));
      v_pts := core.cpc_rating_points(v_pts - h.points_delta);
      v_cnt := greatest(v_cnt - h.match_count_delta, 0);
      v_reversed := v_reversed + 1;
    end if;
    v_rank_after_rev := coalesce(case when v_had then core.cpc_rank_for_points(dv.org_id, v_pts) end, v_old_rank);
    insert into public.member_cpc_rating_history(org_id, unit_id, member_id, rating_id, entry_type, division_id,
      points_before, points_after, match_count_before, match_count_after, points_delta, match_count_delta, revision, reason, meta)
    values (dv.org_id, cur.unit_id, o.member_id, cur.id, 'division_finalization', dv.id,
      v_pts, core.cpc_rating_points(v_pts + o.points_delta), v_cnt, v_cnt + o.matches_played, o.points_delta, o.matches_played, v_rev,
      coalesce(p_reason, 'Division finalized'),
      jsonb_build_object('starting_points', o.starting_points, 'prior_count', o.prior_count, 'raw_delta', o.raw_delta,
        'division_points', o.division_points));
    v_pts := core.cpc_rating_points(v_pts + o.points_delta);
    v_cnt := v_cnt + o.matches_played;
    update public.member_cpc_ratings set points = v_pts, eligible_match_count = v_cnt, source = 'division_finalization',
      assessed_at = now(), assessed_by = coalesce(v_actor, cur.assessed_by) where id = cur.id;

    -- rank follows the points; the previous live rank row of this division is reversed, then the new one is written
    v_new_rank := core.cpc_rank_for_points(dv.org_id, v_pts);
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
      format('CPC points %s (%s%s)', to_char(v_pts, 'FM9.000'), case when o.points_delta >= 0 then '+' else '' end, to_char(o.points_delta, 'FM0.000')),
      v_rev);
    if mr.id is null then
      insert into public.member_ranks(org_id, member_id, rank_id, source_division_id) values (dv.org_id, o.member_id, v_new_rank, dv.id);
    elsif mr.rank_id <> v_new_rank then
      update public.member_ranks set rank_id = v_new_rank, set_by_rule_id = null, source_division_id = dv.id where id = mr.id;
    end if;
    v_applied := v_applied + 1;
  end loop;
  return jsonb_build_object('mode', 'points', 'revision', v_rev, 'applied', v_applied, 'reversed', v_reversed, 'unchanged', v_unchanged);
end $$;
revoke all on function core.apply_cpc_points(text, text) from public, anon, authenticated;
grant execute on function core.apply_cpc_points(text, text) to service_role;

-- correction of a finalized points division: placements are re-evaluated and points are recomputed even when only scores changed
create or replace function core.reapply_division_points(p_division_id text, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare dv public.divisions; v_rev integer; v_actor text := coalesce(core.current_profile_id(), 'system'); v_points jsonb; v_changed boolean;
begin
  select * into dv from public.divisions where id = p_division_id for update;
  select exists (
    select 1 from core.compute_placements(dv.id) p
    full join (select * from public.division_results x where x.division_id = dv.id and x.superseded_at is null) r on r.entry_id = p.entry_id
    where p.entry_id is null or r.entry_id is null
       or (p.placement, p.bracket_tier, p.bracket_result) is distinct from (r.placement, r.bracket_tier, r.bracket_result)) into v_changed;
  if v_changed then
    select coalesce(max(revision), 1) + 1 into v_rev from public.division_results where division_id = dv.id;
    update public.division_results set superseded_at = now(), superseded_by = v_actor where division_id = dv.id and superseded_at is null;
    insert into public.division_results (org_id, division_id, entry_id, placement, bracket_tier, bracket_result, revision)
    select dv.org_id, dv.id, p.entry_id, p.placement, p.bracket_tier, p.bracket_result, v_rev from core.compute_placements(dv.id) p;
  end if;
  v_points := core.apply_cpc_points(dv.id, p_reason);
  perform core.write_audit(dv.org_id, 'division.reapply', 'public.divisions', dv.id, null,
    jsonb_build_object('placements_changed', v_changed, 'reason', p_reason) || v_points);
  return jsonb_build_object('changed', v_changed or coalesce((v_points ->> 'applied')::integer, 0) > 0) || v_points;
end $$;
revoke all on function core.reapply_division_points(text, text) from public, anon, authenticated;
grant execute on function core.reapply_division_points(text, text) to service_role;

-- ---------------------------------------------------------------------------
-- finalize_division (1510) with the points branch
-- ---------------------------------------------------------------------------
create or replace function core.finalize_division(p_division_id text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  dv public.divisions;
  v_moves jsonb;
  v_count integer;
begin
  select * into dv from public.divisions x where x.id = p_division_id for update;
  if not found then
    raise exception 'division not found' using errcode = '22023';
  end if;
  if not core.has_permission(dv.org_id, null, 'scores.finalize') then
    raise exception 'you do not have permission to finalize a division' using errcode = '42501';
  end if;
  if dv.status = 'finalized' then
    return jsonb_build_object('division_id', dv.id, 'status', 'finalized', 'unchanged', true);
  end if;
  if dv.status <> 'in_progress' then
    raise exception 'only a division that is under way can be finalized (this one is %)', dv.status using errcode = '22023';
  end if;
  if exists (select 1 from public.division_stages s where s.division_id = dv.id and s.status not in ('completed', 'cancelled')) then
    raise exception 'every stage must be completed first' using errcode = '22023';
  end if;
  insert into public.division_results (org_id, division_id, entry_id, placement, bracket_tier, bracket_result)
  select dv.org_id, dv.id, p.entry_id, p.placement, p.bracket_tier, p.bracket_result from core.compute_placements(dv.id) p;
  get diagnostics v_count = row_count;
  if v_count = 0 then
    raise exception 'there are no results to finalize' using errcode = '22023';
  end if;
  update public.divisions set status = 'finalized', finalized_at = now(), finalized_by = coalesce(core.current_profile_id(), 'system')
  where id = dv.id;
  -- a division with frozen CPC rating inputs is rated by points; otherwise the legacy rank rules apply
  if exists (select 1 from public.division_cpc_rating_snapshots where division_id = dv.id) then
    v_moves := core.apply_cpc_points(dv.id, 'Division finalized');
  else
    v_moves := core.apply_rank_movement(dv.id, 1);
  end if;
  if not exists (select 1 from public.divisions x where x.event_id = dv.event_id and x.status not in ('finalized', 'cancelled')) then
    update public.events set status = 'completed' where id = dv.event_id and status = 'in_progress';
  end if;
  perform core.write_audit(dv.org_id, 'division.finalize', 'public.divisions', dv.id, null,
    jsonb_build_object('results', v_count) || v_moves);
  return jsonb_build_object('division_id', dv.id, 'status', 'finalized', 'results', v_count) || v_moves;
end $$;

-- correct_match (1510) choosing the points or legacy re-evaluation
create or replace function core.correct_match(p_match_id text, p_reason text, p_games jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  m public.matches;
  v_new public.matches;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_final public.score_events;
  v_i integer;
  v_n integer;
  v_result jsonb;
  v_reapply jsonb;
  v_division text;
begin
  select * into m from public.matches x where x.id = p_match_id for update;
  if not found then
    raise exception 'match not found' using errcode = '22023';
  end if;
  if not core.has_permission(m.org_id, null, 'scores.correct') then
    raise exception 'you do not have permission to correct scores' using errcode = '42501';
  end if;
  if m.status not in ('completed', 'forfeited') then
    raise exception 'only a finished match can be corrected' using errcode = '22023';
  end if;
  if v_reason is null or char_length(v_reason) < 3 or char_length(v_reason) > 500 then
    raise exception 'a reason of 3 to 500 characters is required' using errcode = '22023';
  end if;
  if jsonb_typeof(p_games) <> 'array' or jsonb_array_length(p_games) < 1 then
    raise exception 'send the corrected games as a list' using errcode = '22023';
  end if;
  select e.* into v_final from public.score_events e
  where e.match_id = m.id and e.kind = 'finalized' and not exists (select 1 from public.score_events r where r.reverses_id = e.id)
  order by e.occurred_at desc, e.id desc limit 1;
  if not found then
    raise exception 'the match has no final result to correct' using errcode = '22023';
  end if;

  v_n := jsonb_array_length(p_games);
  update public.matches set status = 'void', status_reason = 'Corrected: ' || v_reason where id = m.id;
  insert into public.score_events (org_id, match_id, kind, payload, reverses_id)
  values (m.org_id, m.id, 'corrected', jsonb_build_object('reason', v_reason), v_final.id);
  insert into public.matches (org_id, division_stage_id, round_no, match_no, group_label, entry_a_id, entry_b_id, feeds_match_id,
    slot, court_id, scheduled_at, referee_member_id)
  values (m.org_id, m.division_stage_id, m.round_no, m.match_no, m.group_label, m.entry_a_id, m.entry_b_id, m.feeds_match_id,
    m.slot, m.court_id, m.scheduled_at, m.referee_member_id)
  returning * into v_new;
  for v_i in 1..v_n loop
    insert into public.match_games (org_id, match_id, game_no, score_a, score_b)
    values (v_new.org_id, v_new.id, v_i, (p_games -> (v_i - 1) ->> 'a')::integer, (p_games -> (v_i - 1) ->> 'b')::integer);
  end loop;
  v_result := core.apply_final(v_new.id);
  select s.division_id into v_division from public.division_stages s where s.id = m.division_stage_id;
  if exists (select 1 from public.divisions d where d.id = v_division and d.status = 'finalized') then
    if exists (select 1 from public.division_cpc_rating_snapshots where division_id = v_division) then
      v_reapply := core.reapply_division_points(v_division, v_reason);
    else
      v_reapply := core.reapply_division(v_division, v_reason);
    end if;
  end if;
  perform core.write_audit(m.org_id, 'match.correct', 'public.matches', m.id,
    jsonb_build_object('winner_entry_id', m.winner_entry_id), jsonb_build_object('new_match_id', v_new.id, 'reason', v_reason,
      'winner_entry_id', v_result ->> 'winner_entry_id'));
  return v_result || jsonb_build_object('old_match_id', m.id, 'new_match_id', v_new.id)
    || case when v_reapply is null then '{}'::jsonb else jsonb_build_object('ranks', v_reapply) end;
end $$;

notify pgrst, 'reload schema';
