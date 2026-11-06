-- Ratings move after every match, like DUPR, instead of once when the division is finalized.
--   * When a match is completed (a score finalized, or a corrected score), the division's points are recalculated from the same
--     frozen inputs and the same cpc-v1 formula, and each member's Singles or Doubles rating and club rank are updated.
--   * The recalculation is the one finalization uses, so the result after the last match equals the old division-end result;
--     finalizing the division then changes nothing more. Forfeits, byes and voided matches still do not count.
--   * The rating history shows one live row per division ("Match results so far") that moves with each match; the
--     recalculation reversals are kept in the ledger but hidden from the member's history list.

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
  perform 1 from public.member_cpc_ratings r where r.member_id = any(v_ids) and r.deleted_at is null order by r.member_id, r.discipline for update;

  for o in select * from core.cpc_division_outcomes(dv.id) order by member_id loop
    select * into cur from public.member_cpc_ratings r where r.member_id = o.member_id and r.discipline = dv.format and r.deleted_at is null;
    if not found or cur.points is null then
      raise exception 'member % has no % rating to update', o.member_id, dv.format using errcode = '22023';
    end if;
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
    v_pts := cur.points; v_cnt := cur.eligible_match_count;
    if v_had then
      insert into public.member_cpc_rating_history(org_id, unit_id, member_id, rating_id, discipline, entry_type, division_id, reverses_id,
        points_before, points_after, match_count_before, match_count_after, points_delta, match_count_delta, revision, reason)
      values (dv.org_id, cur.unit_id, o.member_id, cur.id, dv.format, 'reversal', dv.id, h.id,
        v_pts, core.cpc_rating_points(v_pts - h.points_delta), v_cnt, greatest(v_cnt - h.match_count_delta, 0),
        -h.points_delta, -h.match_count_delta, h.revision,
        case when p_reason = 'Match result' then 'Recalculated after a new result' else 'Reversed after a correction: ' || coalesce(p_reason, '') end);
      v_pts := core.cpc_rating_points(v_pts - h.points_delta);
      v_cnt := greatest(v_cnt - h.match_count_delta, 0);
      v_reversed := v_reversed + 1;
    end if;
    v_rank_after_rev := coalesce(case when v_had then core.cpc_rank_for_points(dv.org_id, greatest(v_pts, coalesce(v_other, v_pts))) end, v_old_rank);
    insert into public.member_cpc_rating_history(org_id, unit_id, member_id, rating_id, discipline, entry_type, division_id,
      points_before, points_after, match_count_before, match_count_after, points_delta, match_count_delta, revision, reason, meta)
    values (dv.org_id, cur.unit_id, o.member_id, cur.id, dv.format, 'division_finalization', dv.id,
      v_pts, core.cpc_rating_points(v_pts + o.points_delta), v_cnt, v_cnt + o.matches_played, o.points_delta, o.matches_played, v_rev,
      case when p_reason = 'Match result' then 'Match results so far' else coalesce(p_reason, 'Division finalized') end,
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

create or replace function core.cpc_points_history_view(p_member_id text default null)
returns table (id text, occurred_at timestamptz, discipline text, entry_type text, points_before numeric, points_after numeric,
  points_delta numeric, match_count_delta integer, reason text, event_name text, division_name text,
  is_reversal boolean, reversed boolean, revision integer)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_me public.members;
  v_target public.members;
begin
  select m.* into v_me from public.members m join public.profiles pr on pr.id = m.profile_id
  where pr.auth_user_id = (select auth.uid()) and pr.is_active and pr.deleted_at is null and m.deleted_at is null limit 1;
  if p_member_id is null then
    v_target := v_me;
  else
    select * into v_target from public.members x where x.id = p_member_id and x.deleted_at is null;
  end if;
  if v_target.id is null then
    raise exception 'member not found' using errcode = '22023';
  end if;
  if v_target.id is distinct from v_me.id and not core.has_permission(v_target.org_id, null, 'members.read') then
    raise exception 'you can read only your own rating history' using errcode = '42501';
  end if;
  return query
  select h.id, h.created_at, h.discipline, h.entry_type, h.points_before, h.points_after,
    h.points_delta, h.match_count_delta, h.reason,
    ev.name, dv.name, h.entry_type = 'reversal',
    exists (select 1 from public.member_cpc_rating_history y where y.reverses_id = h.id), h.revision
  from public.member_cpc_rating_history h
  left join public.divisions dv on dv.id = h.division_id
  left join public.events ev on ev.id = dv.event_id
  where h.member_id = v_target.id
    and not (h.entry_type = 'reversal' and h.reason = 'Recalculated after a new result')
    and not exists (select 1 from public.member_cpc_rating_history y
                    where y.reverses_id = h.id and y.entry_type = 'reversal' and y.reason = 'Recalculated after a new result')
  order by h.created_at desc, h.id desc;
end $$;

create or replace function core.tg_match_rating_live() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_division text;
begin
  if new.status <> 'completed' or old.status = 'completed' then
    return null;
  end if;
  select s.division_id into v_division from public.division_stages s where s.id = new.division_stage_id;
  if exists (select 1 from public.division_cpc_rating_snapshots x where x.division_id = v_division)
     and exists (select 1 from public.divisions d where d.id = v_division and d.status in ('drawn', 'in_progress')) then
    perform core.apply_cpc_points(v_division, 'Match result');
  end if;
  return null;
end $$;
revoke all on function core.tg_match_rating_live() from public, anon, authenticated;
drop trigger if exists z9_match_rating_live on public.matches;
create trigger z9_match_rating_live after update of status on public.matches
  for each row execute function core.tg_match_rating_live();

notify pgrst, 'reload schema';
