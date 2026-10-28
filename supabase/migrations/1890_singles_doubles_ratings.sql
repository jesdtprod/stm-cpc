-- PLAN 8.4e: every player has a Singles rating and a Doubles rating (each 2.000-8.000, each with its own provisional
-- count and history). A singles division updates only Singles, a doubles division (mixed included) only Doubles.
-- The club rank follows the HIGHER of the two ratings that exist (an unrated side is ignored); one place to change:
-- core.apply_cpc_points. Points are still off and no one is assessed yet, so this reshapes empty tables.

-- ---------------------------------------------------------------------------
-- storage: a discipline on every rating, history row, guest assessment and snapshot
-- ---------------------------------------------------------------------------
alter table public.member_cpc_ratings
  add column discipline text not null default 'singles' constraint member_cpc_ratings_discipline_chk check (discipline in ('singles', 'doubles'));
drop index public.member_cpc_ratings_member_live_uq;
create unique index member_cpc_ratings_member_discipline_live_uq
  on public.member_cpc_ratings (member_id, discipline) where deleted_at is null;

alter table public.event_participant_cpc_ratings
  add column discipline text not null default 'singles' constraint event_participant_cpc_ratings_discipline_chk check (discipline in ('singles', 'doubles'));
drop index public.event_participant_cpc_ratings_participant_live_uq;
create unique index event_participant_cpc_ratings_participant_discipline_live_uq
  on public.event_participant_cpc_ratings (participant_id, discipline) where deleted_at is null;

alter table public.member_cpc_rating_history
  add column discipline text not null default 'singles' constraint member_cpc_rating_history_discipline_chk check (discipline in ('singles', 'doubles'));
alter table public.division_cpc_rating_snapshots
  add column discipline text not null default 'singles' constraint division_cpc_rating_snapshots_discipline_chk check (discipline in ('singles', 'doubles'));

-- ---------------------------------------------------------------------------
-- the old single-rating functions go
-- ---------------------------------------------------------------------------
drop function public.set_member_cpc_rating(text, numeric, integer, text, text);
drop function core.set_member_cpc_rating(text, numeric, integer, text, text);
drop function public.set_event_participant_cpc_rating(text, numeric, integer, text, text);
drop function core.set_event_participant_cpc_rating(text, numeric, integer, text, text);
drop function public.cpc_ranking_list(text);
drop function core.cpc_ranking_list(text);
drop function public.cpc_points_history_view(text);
drop function core.cpc_points_history_view(text);

-- ---------------------------------------------------------------------------
-- assessments (ranks.override): a member and a guest, per discipline
-- ---------------------------------------------------------------------------
create function core.set_member_cpc_rating(
  p_member_id text, p_discipline text, p_points numeric, p_expected_version integer, p_key text, p_reason text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  m public.members; rating public.member_cpc_ratings; actor text := core.current_profile_id(); v_before numeric;
  v_reason text := nullif(btrim(p_reason), ''); replay jsonb; response jsonb;
begin
  select * into m from public.members where id = p_member_id and deleted_at is null for share;
  if actor is null or not found or not core.has_permission(m.org_id, null, 'ranks.override') then
    raise exception 'not allowed to assess ratings' using errcode = '42501';
  end if;
  if p_discipline is null or p_discipline not in ('singles', 'doubles') then
    raise exception 'choose singles or doubles' using errcode = '22023';
  end if;
  if p_points is null then raise exception 'an assessed rating is required' using errcode = '22023'; end if;
  perform core.cpc_rating_band_code(p_points);
  if coalesce(length(v_reason), 0) < 3 or length(v_reason) > 500 then
    raise exception 'give an assessment reason from 3 to 500 characters' using errcode = '22023';
  end if;
  replay := core.idem_begin(p_key, m.org_id, 'cpc_rating.member_assessment',
    jsonb_build_object('member', m.id, 'discipline', p_discipline, 'points', p_points, 'version', p_expected_version, 'reason', v_reason));
  if replay is not null then return replay; end if;
  select * into rating from public.member_cpc_ratings where member_id = m.id and discipline = p_discipline and deleted_at is null for update;
  if found and p_expected_version is distinct from rating.version then
    raise exception 'rating changed; reload before saving' using errcode = 'CP409';
  elsif not found and coalesce(p_expected_version, 0) <> 0 then
    raise exception 'rating changed; reload before saving' using errcode = 'CP409';
  end if;
  if found then
    v_before := rating.points;
    update public.member_cpc_ratings set points = p_points, source = 'admin_assessment', reason = v_reason,
      assessed_at = now(), assessed_by = actor where id = rating.id;
  else
    insert into public.member_cpc_ratings(org_id, member_id, discipline, points, source, reason, assessed_at, assessed_by)
      values(m.org_id, m.id, p_discipline, p_points, 'admin_assessment', v_reason, now(), actor) returning * into rating;
  end if;
  select * into rating from public.member_cpc_ratings where member_id = m.id and discipline = p_discipline and deleted_at is null;
  -- An assessment resets the starting value only; the played-match count is kept.
  insert into public.member_cpc_rating_history(org_id, unit_id, member_id, rating_id, discipline, entry_type, points_before, points_after,
    match_count_before, match_count_after, reason)
  values(m.org_id, rating.unit_id, m.id, rating.id, p_discipline, 'admin_assessment', v_before, rating.points,
    rating.eligible_match_count, rating.eligible_match_count, v_reason);
  perform core.write_audit(m.org_id, 'cpc_rating.member_assessment', 'public.member_cpc_ratings', rating.id, null,
    jsonb_build_object('member_id', m.id, 'discipline', p_discipline, 'points', rating.points, 'version', rating.version, 'reason', v_reason));
  response := jsonb_build_object('ok', true, 'member_id', m.id, 'discipline', p_discipline, 'points', rating.points, 'version', rating.version);
  perform core.idem_complete(p_key, response);
  return response;
end $$;

create function core.set_event_participant_cpc_rating(
  p_participant_id text, p_discipline text, p_points numeric, p_expected_version integer, p_key text, p_reason text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  participant public.event_participants; rating public.event_participant_cpc_ratings;
  actor text := core.current_profile_id(); v_reason text := nullif(btrim(p_reason), ''); replay jsonb; response jsonb;
begin
  select * into participant from public.event_participants where id = p_participant_id and deleted_at is null for share;
  if actor is null or not found or not core.has_permission(participant.org_id, null, 'ranks.override') then
    raise exception 'not allowed to assess guest ratings' using errcode = '42501';
  end if;
  if p_discipline is null or p_discipline not in ('singles', 'doubles') then
    raise exception 'choose singles or doubles' using errcode = '22023';
  end if;
  if p_points is null then raise exception 'an assessed rating is required' using errcode = '22023'; end if;
  perform core.cpc_rating_band_code(p_points);
  if coalesce(length(v_reason), 0) < 3 or length(v_reason) > 500 then
    raise exception 'give an assessment reason from 3 to 500 characters' using errcode = '22023';
  end if;
  replay := core.idem_begin(p_key, participant.org_id, 'cpc_rating.guest_assessment',
    jsonb_build_object('participant', participant.id, 'discipline', p_discipline, 'points', p_points, 'version', p_expected_version, 'reason', v_reason));
  if replay is not null then return replay; end if;
  if exists (select 1 from public.division_cpc_rating_snapshots s where s.participant_id = participant.id and s.discipline = p_discipline) then
    raise exception 'guest rating is frozen in a drawn division' using errcode = '22023';
  end if;
  select * into rating from public.event_participant_cpc_ratings
    where participant_id = participant.id and discipline = p_discipline and deleted_at is null for update;
  if found and p_expected_version is distinct from rating.version then
    raise exception 'guest rating changed; reload before saving' using errcode = 'CP409';
  elsif not found and coalesce(p_expected_version, 0) <> 0 then
    raise exception 'guest rating changed; reload before saving' using errcode = 'CP409';
  end if;
  if found then
    update public.event_participant_cpc_ratings set points = p_points, source = 'admin_assessment', reason = v_reason,
      assessed_at = now(), assessed_by = actor where id = rating.id;
  else
    insert into public.event_participant_cpc_ratings(org_id, unit_id, participant_id, discipline, points, source, reason, assessed_at, assessed_by)
      values(participant.org_id, participant.unit_id, participant.id, p_discipline, p_points, 'admin_assessment', v_reason, now(), actor)
      returning * into rating;
  end if;
  select * into rating from public.event_participant_cpc_ratings
    where participant_id = participant.id and discipline = p_discipline and deleted_at is null;
  perform core.write_audit(participant.org_id, 'cpc_rating.guest_assessment', 'public.event_participant_cpc_ratings', rating.id, null,
    jsonb_build_object('participant_id', participant.id, 'discipline', p_discipline, 'points', rating.points, 'version', rating.version, 'reason', v_reason));
  response := jsonb_build_object('ok', true, 'participant_id', participant.id, 'discipline', p_discipline, 'points', rating.points, 'version', rating.version);
  perform core.idem_complete(p_key, response);
  return response;
end $$;

-- ---------------------------------------------------------------------------
-- preparing members: one unrated Singles row and one unrated Doubles row each
-- ---------------------------------------------------------------------------
create or replace function core.initialize_member_cpc_ratings(p_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  org text := (select p.org_id from public.profiles p where p.id = core.current_profile_id()); replay jsonb; response jsonb; created integer;
begin
  if core.current_profile_id() is null or org is null or not core.has_permission(org, null, 'ranks.override') then
    raise exception 'not allowed to prepare ratings' using errcode = '42501';
  end if;
  replay := core.idem_begin(p_key, org, 'cpc_rating.initialize', jsonb_build_object('org', org));
  if replay is not null then return replay; end if;
  -- Unrated (NULL) rows only where missing; existing points, counts and ranks are untouched.
  insert into public.member_cpc_ratings(org_id, unit_id, member_id, discipline)
  select m.org_id, m.unit_id, m.id, d.discipline from public.members m
  cross join (values ('singles'), ('doubles')) as d(discipline)
  where m.org_id = org and m.deleted_at is null and m.status = 'active'
    and not exists (select 1 from public.member_cpc_ratings r where r.member_id = m.id and r.discipline = d.discipline and r.deleted_at is null)
  order by m.id, d.discipline
  on conflict (member_id, discipline) where deleted_at is null do nothing;
  get diagnostics created = row_count;
  perform core.write_audit(org, 'cpc_rating.initialize', 'public.member_cpc_ratings', org, null,
    jsonb_build_object('created_unrated', created));
  response := jsonb_build_object('ok', true, 'created_unrated', created);
  perform core.idem_complete(p_key, response);
  return response;
end $$;

-- ---------------------------------------------------------------------------
-- freezing a division's inputs: the division's format picks the rating
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
      left join public.member_cpc_ratings mr on mr.member_id = em.member_id and mr.discipline = dv.format and mr.deleted_at is null
      where e.division_id = dv.id and e.status = 'active'
    union all
    select gr.points from public.entries e join public.entry_guests eg on eg.entry_id = e.id
      left join public.event_participant_cpc_ratings gr on gr.participant_id = eg.participant_id and gr.discipline = dv.format and gr.deleted_at is null
      where e.division_id = dv.id and e.status = 'active'
  ) v where v.points is null;
  if missing > 0 then
    raise exception 'every player needs an assessed % rating before the division starts (% missing)', dv.format, missing using errcode = '22023';
  end if;
  with player_inputs as (
    select e.id as entry_id, e.unit_id, em.member_id, null::text as participant_id,
      mr.points as starting_points, mr.eligible_match_count as prior_eligible_match_count
    from public.entries e join public.entry_members em on em.entry_id = e.id
    join public.member_cpc_ratings mr on mr.member_id = em.member_id and mr.discipline = dv.format and mr.deleted_at is null
    where e.division_id = dv.id and e.status = 'active'
    union all
    select e.id, e.unit_id, null::text, eg.participant_id, gr.points, 0
    from public.entries e join public.entry_guests eg on eg.entry_id = e.id
    join public.event_participant_cpc_ratings gr on gr.participant_id = eg.participant_id and gr.discipline = dv.format and gr.deleted_at is null
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
    jsonb_build_object('division_id', dv.id, 'snapshots', snapshot_count, 'discipline', dv.format, 'algorithm', 'cpc-v1'));
  return jsonb_build_object('division_id', dv.id, 'snapshots', snapshot_count, 'replayed', false);
end $$;

-- ---------------------------------------------------------------------------
-- applying a division: the division's discipline is updated; the rank follows the higher rating
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

-- ---------------------------------------------------------------------------
-- activation guard: every active member needs both rating records
-- ---------------------------------------------------------------------------
create or replace function core.tg_cpc_points_activation() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_missing integer;
begin
  if new.key = 'ranks.cpc_points_enabled' and new.unit_id is null and new.deleted_at is null then
    if jsonb_typeof(new.value) <> 'boolean' then
      raise exception 'this setting is on or off' using errcode = '22023';
    end if;
    if new.value = 'true'::jsonb and old.value is distinct from 'true'::jsonb then
      select count(*) into v_missing from public.members m
      where m.org_id = new.org_id and m.deleted_at is null and m.status = 'active'
        and (select count(distinct r.discipline) from public.member_cpc_ratings r where r.member_id = m.id and r.deleted_at is null) < 2;
      if v_missing > 0 then
        raise exception 'prepare the members first: % active member(s) have no rating record', v_missing using errcode = '22023';
      end if;
    end if;
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- screens: both ratings side by side, history with the discipline, admin counts
-- ---------------------------------------------------------------------------
create function core.cpc_ranking_list(p_category_id text default null)
returns table (member_id text, member_no text, display_name text, category_id text, category_name text, rank_id text,
  rank_name text, rank_idx integer, since timestamptz,
  singles_points numeric, singles_matches integer, singles_provisional boolean, singles_version integer,
  doubles_points numeric, doubles_matches integer, doubles_provisional boolean, doubles_version integer)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_org text;
  v_staff boolean;
  v_me text;
begin
  select pr.org_id into v_org from public.profiles pr
  where pr.auth_user_id = (select auth.uid()) and pr.is_active and pr.deleted_at is null limit 1;
  if v_org is null or not core.is_org_member(v_org) then
    raise exception 'sign in to see the ranking' using errcode = '42501';
  end if;
  v_staff := core.has_permission(v_org, null, 'members.read');
  select m.id into v_me from public.members m join public.profiles pr on pr.id = m.profile_id
  where pr.auth_user_id = (select auth.uid()) and m.deleted_at is null limit 1;
  return query
  select m.id, m.member_no, pe.display_name, c.id, c.name, r.id, r.name, ch.idx, mr.updated_at,
    case when v_staff or m.id = v_me then sr.points end,
    case when v_staff or m.id = v_me then coalesce(sr.eligible_match_count, 0) end,
    case when v_staff or m.id = v_me then (sr.points is not null and sr.eligible_match_count < 5) end,
    case when v_staff then coalesce(sr.version, 0) end,
    case when v_staff or m.id = v_me then dr.points end,
    case when v_staff or m.id = v_me then coalesce(dr.eligible_match_count, 0) end,
    case when v_staff or m.id = v_me then (dr.points is not null and dr.eligible_match_count < 5) end,
    case when v_staff then coalesce(dr.version, 0) end
  from public.members m
  join public.persons pe on pe.id = m.person_id
  left join public.member_ranks mr on mr.member_id = m.id and mr.deleted_at is null
  left join public.ranks r on r.id = mr.rank_id
  left join public.rank_ladders l on l.id = r.ladder_id
  left join public.categories c on c.id = l.category_id
  left join core.rank_chain(v_org) ch on ch.rank_id = r.id
  left join public.member_cpc_ratings sr on sr.member_id = m.id and sr.discipline = 'singles' and sr.deleted_at is null
  left join public.member_cpc_ratings dr on dr.member_id = m.id and dr.discipline = 'doubles' and dr.deleted_at is null
  where m.org_id = v_org and m.deleted_at is null and m.status = 'active'
    and (p_category_id is null or c.id = p_category_id)
  order by greatest(sr.points, dr.points) desc nulls last, ch.idx desc nulls last, pe.display_name;
end $$;

create function core.cpc_points_history_view(p_member_id text default null)
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
  order by h.created_at desc, h.id desc;
end $$;

create or replace function core.cpc_points_status() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_org text;
begin
  select pr.org_id into v_org from public.profiles pr
  where pr.auth_user_id = (select auth.uid()) and pr.is_active and pr.deleted_at is null limit 1;
  if v_org is null or not core.has_permission(v_org, null, 'members.read') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'enabled', core.cpc_points_enabled(v_org),
    'active_members', (select count(*) from public.members m where m.org_id = v_org and m.deleted_at is null and m.status = 'active'),
    'prepared', (select count(*) from public.members m where m.org_id = v_org and m.deleted_at is null and m.status = 'active'
      and (select count(distinct r.discipline) from public.member_cpc_ratings r where r.member_id = m.id and r.deleted_at is null) = 2),
    'rated_singles', (select count(*) from public.members m join public.member_cpc_ratings r on r.member_id = m.id and r.deleted_at is null
      and r.discipline = 'singles' where m.org_id = v_org and m.deleted_at is null and m.status = 'active' and r.points is not null),
    'rated_doubles', (select count(*) from public.members m join public.member_cpc_ratings r on r.member_id = m.id and r.deleted_at is null
      and r.discipline = 'doubles' where m.org_id = v_org and m.deleted_at is null and m.status = 'active' and r.points is not null));
end $$;

-- ---------------------------------------------------------------------------
-- public wrappers and grants (the core functions must be executable by the signed-in role too)
-- ---------------------------------------------------------------------------
create function public.set_member_cpc_rating(p_member_id text, p_discipline text, p_points numeric, p_expected_version integer, p_key text, p_reason text)
returns jsonb language sql security invoker set search_path = '' as $$
  select core.set_member_cpc_rating(p_member_id, p_discipline, p_points, p_expected_version, p_key, p_reason) $$;
create function public.set_event_participant_cpc_rating(p_participant_id text, p_discipline text, p_points numeric, p_expected_version integer, p_key text, p_reason text)
returns jsonb language sql security invoker set search_path = '' as $$
  select core.set_event_participant_cpc_rating(p_participant_id, p_discipline, p_points, p_expected_version, p_key, p_reason) $$;
create function public.cpc_ranking_list(p_category_id text default null)
returns table (member_id text, member_no text, display_name text, category_id text, category_name text, rank_id text,
  rank_name text, rank_idx integer, since timestamptz,
  singles_points numeric, singles_matches integer, singles_provisional boolean, singles_version integer,
  doubles_points numeric, doubles_matches integer, doubles_provisional boolean, doubles_version integer)
language sql stable security invoker set search_path = '' as $$ select * from core.cpc_ranking_list(p_category_id) $$;
create function public.cpc_points_history_view(p_member_id text default null)
returns table (id text, occurred_at timestamptz, discipline text, entry_type text, points_before numeric, points_after numeric,
  points_delta numeric, match_count_delta integer, reason text, event_name text, division_name text,
  is_reversal boolean, reversed boolean, revision integer)
language sql stable security invoker set search_path = '' as $$ select * from core.cpc_points_history_view(p_member_id) $$;

revoke all on function core.set_member_cpc_rating(text, text, numeric, integer, text, text),
  core.set_event_participant_cpc_rating(text, text, numeric, integer, text, text),
  core.cpc_ranking_list(text), core.cpc_points_history_view(text),
  public.set_member_cpc_rating(text, text, numeric, integer, text, text),
  public.set_event_participant_cpc_rating(text, text, numeric, integer, text, text),
  public.cpc_ranking_list(text), public.cpc_points_history_view(text) from public, anon, authenticated;
grant execute on function core.set_member_cpc_rating(text, text, numeric, integer, text, text),
  core.set_event_participant_cpc_rating(text, text, numeric, integer, text, text),
  core.cpc_ranking_list(text), core.cpc_points_history_view(text),
  public.set_member_cpc_rating(text, text, numeric, integer, text, text),
  public.set_event_participant_cpc_rating(text, text, numeric, integer, text, text),
  public.cpc_ranking_list(text), public.cpc_points_history_view(text) to authenticated, service_role;

notify pgrst, 'reload schema';
