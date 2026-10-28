-- PLAN 8.4f: the Club Rank is automatic. It always equals the classification of the HIGHER of the member's Singles and
-- Doubles ratings (an unrated side is ignored), and is recalculated whenever either rating changes. Rank history is written
-- only when the classification changes. Members can submit their initial Singles and Doubles ratings once; after that only
-- authorized administrators (ranks.override) change them. Event eligibility uses the rating for the division's format, not
-- the Club Rank, while ratings are on.

-- ---------------------------------------------------------------------------
-- a member's own first submission is a new source and history type
-- ---------------------------------------------------------------------------
do $$
declare c record;
begin
  for c in
    select conrelid::regclass::text as tbl, conname from pg_constraint
    where contype = 'c' and conrelid in ('public.member_cpc_ratings'::regclass, 'public.member_cpc_rating_history'::regclass)
      and pg_get_constraintdef(oid) like '%admin_assessment%' and pg_get_constraintdef(oid) not like '%assessed_at%'
  loop
    execute format('alter table %s drop constraint %I', c.tbl, c.conname);
  end loop;
end $$;
alter table public.member_cpc_ratings add constraint member_cpc_ratings_source_chk
  check (source in ('admin_assessment', 'member_self', 'division_finalization'));
alter table public.member_cpc_rating_history add constraint member_cpc_rating_history_entry_type_chk
  check (entry_type in ('admin_assessment', 'member_self', 'division_finalization', 'reversal'));

-- ---------------------------------------------------------------------------
-- the Club Rank: Classification(MAX(Singles, Doubles)), stored in member_ranks (rank history only on a change)
-- ---------------------------------------------------------------------------
create or replace function core.sync_member_club_rank(p_member_id text, p_reason text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  m public.members; mr public.member_ranks; v_best numeric; v_new text;
begin
  select * into m from public.members where id = p_member_id and deleted_at is null;
  if not found then return null; end if;
  select max(r.points) into v_best from public.member_cpc_ratings r
  where r.member_id = m.id and r.deleted_at is null and r.points is not null;
  if v_best is null then return null; end if;            -- NR on both sides: no Club Rank to derive
  v_new := core.cpc_rank_for_points(m.org_id, v_best);
  select * into mr from public.member_ranks k where k.member_id = m.id and k.deleted_at is null;
  if mr.id is not null and mr.rank_id = v_new then return v_new; end if;   -- same classification: no new history
  if mr.id is null then
    insert into public.member_ranks(org_id, member_id, rank_id) values (m.org_id, m.id, v_new);
  else
    update public.member_ranks set rank_id = v_new, set_by_rule_id = null where id = mr.id;
  end if;
  insert into public.rank_history(org_id, member_id, from_rank_id, to_rank_id, reason)
  values (m.org_id, m.id, mr.rank_id, v_new, p_reason);
  return v_new;
end $$;
revoke all on function core.sync_member_club_rank(text, text) from public, anon, authenticated;
grant execute on function core.sync_member_club_rank(text, text) to service_role;

-- ---------------------------------------------------------------------------
-- administrator assessment (1890) now also recalculates the Club Rank
-- ---------------------------------------------------------------------------
create or replace function core.set_member_cpc_rating(
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
  -- the Club Rank is Classification(MAX(Singles, Doubles)); history only if the classification changes
  perform core.sync_member_club_rank(m.id, format('Assessed %s rating %s', initcap(p_discipline), to_char(rating.points, 'FM9.000')));
  perform core.write_audit(m.org_id, 'cpc_rating.member_assessment', 'public.member_cpc_ratings', rating.id, null,
    jsonb_build_object('member_id', m.id, 'discipline', p_discipline, 'points', rating.points, 'version', rating.version, 'reason', v_reason));
  response := jsonb_build_object('ok', true, 'member_id', m.id, 'discipline', p_discipline, 'points', rating.points, 'version', rating.version);
  perform core.idem_complete(p_key, response);
  return response;
end $$;

-- ---------------------------------------------------------------------------
-- initial self-submission: once per rating, afterwards only administrators
-- ---------------------------------------------------------------------------
create function core.submit_member_ratings(p_singles numeric, p_doubles numeric, p_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  actor text := core.current_profile_id(); m public.members; d text; v numeric; rating public.member_cpc_ratings;
  replay jsonb; response jsonb; v_saved text[] := '{}';
begin
  select * into m from public.members x where x.profile_id = actor and x.deleted_at is null;
  if actor is null or not found then
    raise exception 'sign in as a member to submit your ratings' using errcode = '42501';
  end if;
  if p_singles is null and p_doubles is null then
    raise exception 'enter a Singles rating, a Doubles rating, or both' using errcode = '22023';
  end if;
  if p_singles is not null then perform core.cpc_rating_band_code(p_singles); end if;
  if p_doubles is not null then perform core.cpc_rating_band_code(p_doubles); end if;
  replay := core.idem_begin(p_key, m.org_id, 'cpc_rating.member_submit',
    jsonb_build_object('member', m.id, 'singles', p_singles, 'doubles', p_doubles));
  if replay is not null then return replay; end if;
  foreach d in array array['singles', 'doubles'] loop
    v := case d when 'singles' then p_singles else p_doubles end;
    continue when v is null;
    select * into rating from public.member_cpc_ratings r where r.member_id = m.id and r.discipline = d and r.deleted_at is null for update;
    if found and rating.points is not null then
      raise exception 'your % rating was already submitted; only an administrator can change it', d using errcode = '42501';
    end if;
    if found then
      update public.member_cpc_ratings set points = v, source = 'member_self', reason = null, assessed_at = now(), assessed_by = actor
        where id = rating.id;
    else
      insert into public.member_cpc_ratings(org_id, member_id, discipline, points, source, assessed_at, assessed_by)
        values (m.org_id, m.id, d, v, 'member_self', now(), actor) returning * into rating;
    end if;
    insert into public.member_cpc_rating_history(org_id, unit_id, member_id, rating_id, discipline, entry_type, points_before, points_after,
      match_count_before, match_count_after, reason)
    values (m.org_id, rating.unit_id, m.id, rating.id, d, 'member_self', null, v, rating.eligible_match_count, rating.eligible_match_count,
      'Self-assessed by the member');
    v_saved := v_saved || d;
  end loop;
  perform core.sync_member_club_rank(m.id, 'Self-assessed rating submitted');
  perform core.write_audit(m.org_id, 'cpc_rating.member_submit', 'public.members', m.id, null,
    jsonb_build_object('singles', p_singles, 'doubles', p_doubles));
  response := jsonb_build_object('ok', true, 'saved', to_jsonb(v_saved));
  perform core.idem_complete(p_key, response);
  return response;
end $$;

-- ---------------------------------------------------------------------------
-- the profile card: both ratings, their classification and status, and the automatic Club Rank
-- ---------------------------------------------------------------------------
create function core.get_member_ratings(p_member_id text default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_me public.members; v_target public.members; v_staff boolean; v_self boolean; v_out jsonb; d text; r public.member_cpc_ratings;
  rk public.ranks; v_best numeric; v_src text; side jsonb; v_club jsonb;
begin
  select m.* into v_me from public.members m join public.profiles pr on pr.id = m.profile_id
  where pr.auth_user_id = (select auth.uid()) and pr.is_active and pr.deleted_at is null and m.deleted_at is null limit 1;
  if p_member_id is null then v_target := v_me;
  else select * into v_target from public.members x where x.id = p_member_id and x.deleted_at is null; end if;
  if v_target.id is null then raise exception 'member not found' using errcode = '22023'; end if;
  v_self := v_target.id is not distinct from v_me.id;
  v_staff := core.has_permission(v_target.org_id, null, 'ranks.override');
  if not v_self and not core.has_permission(v_target.org_id, null, 'members.read') then
    raise exception 'you can read only your own ratings' using errcode = '42501';
  end if;
  v_out := jsonb_build_object('member_id', v_target.id, 'admin_edit', v_staff, 'self', v_self);
  foreach d in array array['singles', 'doubles'] loop
    select * into r from public.member_cpc_ratings x where x.member_id = v_target.id and x.discipline = d and x.deleted_at is null;
    rk := null;
    if r.points is not null then
      select k.* into rk from public.ranks k where k.id = core.cpc_rank_for_points(v_target.org_id, r.points);
    end if;
    side := jsonb_build_object(
      'points', r.points,                                   -- NULL means NR (not rated)
      'classification', case when rk.id is null then null else regexp_replace(rk.name, '\s*\(.*$', '') end,
      'status', case when r.points is null then 'NR' when r.source = 'member_self' then 'self'
        when r.source = 'admin_assessment' then 'admin' else 'played' end,
      'matches', coalesce(r.eligible_match_count, 0),
      'version', coalesce(r.version, 0),
      'locked', r.points is not null,
      'updated_at', r.assessed_at);
    v_out := v_out || jsonb_build_object(d, side);
  end loop;
  select max(x.points) into v_best from public.member_cpc_ratings x where x.member_id = v_target.id and x.deleted_at is null and x.points is not null;
  if v_best is null then
    v_club := jsonb_build_object('name', 'Not Rated', 'range', null, 'best_points', null, 'source', null);
  else
    select k.* into rk from public.ranks k where k.id = core.cpc_rank_for_points(v_target.org_id, v_best);
    select x.discipline into v_src from public.member_cpc_ratings x
      where x.member_id = v_target.id and x.deleted_at is null and x.points = v_best order by x.discipline desc limit 1;
    v_club := jsonb_build_object('name', regexp_replace(rk.name, '\s*\(.*$', ''),
      'range', to_char(rk.rating_min, 'FM0.000') || '–' || to_char(rk.rating_max, 'FM0.000'),
      'best_points', v_best, 'source', v_src);
  end if;
  return v_out || jsonb_build_object('club_rank', v_club,
    'can_self_submit', v_self
      and (select count(*) from public.member_cpc_ratings y where y.member_id = v_target.id and y.deleted_at is null and y.points is not null) < 2);
end $$;

create function public.submit_member_ratings(p_singles numeric, p_doubles numeric, p_key text)
returns jsonb language sql security invoker set search_path = '' as $$ select core.submit_member_ratings(p_singles, p_doubles, p_key) $$;
create function public.get_member_ratings(p_member_id text default null)
returns jsonb language sql stable security invoker set search_path = '' as $$ select core.get_member_ratings(p_member_id) $$;
revoke all on function core.submit_member_ratings(numeric, numeric, text), core.get_member_ratings(text),
  public.submit_member_ratings(numeric, numeric, text), public.get_member_ratings(text) from public, anon, authenticated;
grant execute on function core.submit_member_ratings(numeric, numeric, text), core.get_member_ratings(text),
  public.submit_member_ratings(numeric, numeric, text), public.get_member_ratings(text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- event eligibility (1690 version): while ratings are on, the rating for the division's format decides, not the Club Rank
-- ---------------------------------------------------------------------------
create or replace function core.registration_problem(p_member_id text, p_division_id text, p_soft boolean default true)
returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  m public.members;
  per public.persons;
  dv public.divisions;
  ev public.events;
  v_rank record;
  v_lo integer;
  v_hi integer;
  v_age integer;
  v_group text;
  v_a integer;
  v_b integer;
begin
  select * into m from public.members x where x.id = p_member_id and x.deleted_at is null;
  if not found or m.status <> 'active' then
    return 'Only an active member can register.';
  end if;
  select * into dv from public.divisions x where x.id = p_division_id;
  if not found or dv.org_id <> m.org_id then
    return 'That division does not exist.';
  end if;
  select * into ev from public.events x where x.id = dv.event_id;
  if ev.status <> 'registration_open' and not (ev.status = 'registration_closed' and core.has_permission(ev.org_id,dv.unit_id,'events.admin_roster')) then
    return 'Registration for this event is not open.';
  end if;
  if not core.has_permission(ev.org_id,dv.unit_id,'events.admin_roster') and ((ev.registration_opens_at is not null and now() < ev.registration_opens_at)
     or (ev.registration_closes_at is not null and now() >= ev.registration_closes_at)) then
    return 'Registration for this event is outside its registration window.';
  end if;
  if dv.status <> 'open' then
    return 'This division is not open for registration.';
  end if;
  if not p_soft then
    return null;
  end if;

  if core.cpc_points_enabled(m.org_id) then
    -- ratings are on: the rating for this division's format decides (Singles or Doubles), never the Club Rank
    select r.id, r.sort_order, l.category_id into v_rank
    from public.member_cpc_ratings cr
    join public.ranks r on r.id = core.cpc_rank_for_points(m.org_id, cr.points)
    join public.rank_ladders l on l.id = r.ladder_id
    where cr.member_id = m.id and cr.discipline = dv.format and cr.deleted_at is null and cr.points is not null;
    if not found then
      return format('You have no %s rating yet, so you cannot join a ranked division.', dv.format);
    end if;
  else
    select r.id, r.sort_order, l.category_id into v_rank
    from public.member_ranks mr
    join public.ranks r on r.id = mr.rank_id
    join public.rank_ladders l on l.id = r.ladder_id
    where mr.member_id = m.id and mr.deleted_at is null;
    if not found then
      return 'You have no rank yet, so you cannot join a ranked division.';
    end if;
  end if;
  if v_rank.category_id <> dv.category_id then
    return 'This division is for a different category than your current rank.';
  end if;
  if dv.min_rank_id is not null then
    select sort_order into v_lo from public.ranks where id = dv.min_rank_id;
    if v_rank.sort_order < v_lo then return 'Your rank is below this division''s lowest allowed rank.'; end if;
  end if;
  if dv.max_rank_id is not null then
    select sort_order into v_hi from public.ranks where id = dv.max_rank_id;
    if v_rank.sort_order > v_hi then return 'Your rank is above this division''s highest allowed rank.'; end if;
  end if;

  select * into per from public.persons p where p.id = m.person_id;
  if dv.gender in ('male', 'female') then
    if per.gender is null then
      return 'Add your gender to your profile to join this division.';
    elsif per.gender <> dv.gender then
      return case dv.gender when 'male' then 'This division is for men.' else 'This division is for women.' end;
    end if;
  end if;

  v_group := btrim(coalesce(dv.age_group, ''));
  if v_group ~ '^\d{1,2}\+$' or v_group ~ '^\d{1,2}\s*-\s*\d{1,2}$' then
    if per.date_of_birth is null then
      return 'Your birth date is needed to check this division''s age group.';
    end if;
    v_age := extract(year from age(ev.starts_on, per.date_of_birth))::integer;
    if v_group ~ '\+$' then
      v_a := substring(v_group from '^\d+')::integer;
      if v_age < v_a then return format('This division is for ages %s and over.', v_a); end if;
    else
      v_a := substring(v_group from '^\d+')::integer;
      v_b := substring(v_group from '(\d+)$')::integer;
      if v_age < v_a or v_age > v_b then return format('This division is for ages %s to %s.', v_a, v_b); end if;
    end if;
  end if;
  return null;
end $$;

-- ---------------------------------------------------------------------------
-- one-time reconciliation (idempotent): the Club Rank of members who have a rating follows it; the stored rank of members
-- with no Singles and no Doubles rating is retired (soft-deleted, still in rank history) so they show Not Rated.
-- ---------------------------------------------------------------------------
select set_config('core.rpc', 'on', true);
do $$
declare m record; v_cleared integer := 0; v_synced integer := 0; v_org text;
begin
  for m in select id, org_id from public.members where deleted_at is null and status = 'active' order by id loop
    if exists (select 1 from public.member_cpc_ratings r where r.member_id = m.id and r.deleted_at is null and r.points is not null) then
      if core.sync_member_club_rank(m.id, 'Club Rank follows the highest rating') is not null then v_synced := v_synced + 1; end if;
    else
      update public.member_ranks set deleted_at = now(), deleted_by = 'system', delete_reason = 'Not rated: no Singles or Doubles rating'
      where member_id = m.id and deleted_at is null;
      if found then v_cleared := v_cleared + 1; v_org := m.org_id; end if;
    end if;
  end loop;
  if v_cleared > 0 then
    perform core.write_audit(v_org, 'cpc_rating.reconcile', 'public.member_ranks', null, null,
      jsonb_build_object('cleared_unrated', v_cleared));
  end if;
end $$;
select set_config('core.rpc', 'off', true);

notify pgrst, 'reload schema';
