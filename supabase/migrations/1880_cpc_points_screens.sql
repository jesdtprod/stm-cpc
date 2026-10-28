-- PLAN 8.4d: data for the CPC points screens, and the activation guard.
--   * Rank names carry their band again ("Novice Low (2.500-2.749)"): the Home, Member Details, Ranking and public screens
--     read the band out of the name. The numbers are generated from rating_min / rating_max here, so they cannot disagree.
--     Open/Professional keeps its label.
--   * cpc_ranking_list: every active member, ordered by points (unrated last), with points, provisional status and the
--     current rank. Points are visible to staff (members.read) and to the member themselves only.
--   * cpc_points_history_view: the member's append-only points history (self or members.read).
--   * cpc_points_status: counts for the admin panel (members.read).
--   * Turning ranks.cpc_points_enabled on is refused until every active member has a CPC points record (initialization).

update public.ranks r
set name = v.base || ' (' || to_char(r.rating_min, 'FM0.000') || '–' || to_char(r.rating_max, 'FM0.000') || ')'
from (values
  ('beginner-low', 'Beginner Low'), ('beginner-high', 'Beginner High'),
  ('novice-low', 'Novice Low'), ('novice-high', 'Novice High'),
  ('intermediate-low', 'Intermediate Low'), ('intermediate-high', 'Intermediate High'),
  ('advanced-low', 'Advanced Low'), ('advanced-high', 'Advanced High')
) as v(code, base)
where r.code = v.code and r.deleted_at is null and r.rating_min is not null and r.rating_max is not null;

-- ---------------------------------------------------------------------------
-- activation guard (any path that writes the setting)
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
        and not exists (select 1 from public.member_cpc_ratings r where r.member_id = m.id and r.deleted_at is null);
      if v_missing > 0 then
        raise exception 'prepare the members first: % active member(s) have no CPC points record', v_missing using errcode = '22023';
      end if;
    end if;
  end if;
  return new;
end $$;
revoke all on function core.tg_cpc_points_activation() from public, anon, authenticated;
create trigger c8_cpc_points_activation before update of value on public.settings
  for each row execute function core.tg_cpc_points_activation();

-- ---------------------------------------------------------------------------
-- ranking list by points
-- ---------------------------------------------------------------------------
create or replace function core.cpc_ranking_list(p_category_id text default null)
returns table (member_id text, member_no text, display_name text, category_id text, category_name text, rank_id text,
  rank_name text, rank_idx integer, since timestamptz, points numeric, eligible_match_count integer, provisional boolean,
  points_version integer, assessed_at timestamptz)
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
    case when v_staff or m.id = v_me then cr.points end,
    case when v_staff or m.id = v_me then coalesce(cr.eligible_match_count, 0) end,
    case when v_staff or m.id = v_me then (cr.points is not null and cr.eligible_match_count < 5) end,
    case when v_staff then coalesce(cr.version, 0) end,
    case when v_staff or m.id = v_me then cr.assessed_at end
  from public.members m
  join public.persons pe on pe.id = m.person_id
  left join public.member_ranks mr on mr.member_id = m.id and mr.deleted_at is null
  left join public.ranks r on r.id = mr.rank_id
  left join public.rank_ladders l on l.id = r.ladder_id
  left join public.categories c on c.id = l.category_id
  left join core.rank_chain(v_org) ch on ch.rank_id = r.id
  left join public.member_cpc_ratings cr on cr.member_id = m.id and cr.deleted_at is null
  where m.org_id = v_org and m.deleted_at is null and m.status = 'active'
    and (p_category_id is null or c.id = p_category_id)
  order by cr.points desc nulls last, ch.idx desc nulls last, pe.display_name;
end $$;

-- ---------------------------------------------------------------------------
-- points history of one member
-- ---------------------------------------------------------------------------
create or replace function core.cpc_points_history_view(p_member_id text default null)
returns table (id text, occurred_at timestamptz, entry_type text, points_before numeric, points_after numeric,
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
    raise exception 'you can read only your own points history' using errcode = '42501';
  end if;
  return query
  select h.id, h.created_at, h.entry_type, h.points_before, h.points_after,
    h.points_delta, h.match_count_delta, h.reason,
    ev.name, dv.name, h.entry_type = 'reversal',
    exists (select 1 from public.member_cpc_rating_history y where y.reverses_id = h.id), h.revision
  from public.member_cpc_rating_history h
  left join public.divisions dv on dv.id = h.division_id
  left join public.events ev on ev.id = dv.event_id
  where h.member_id = v_target.id
  order by h.created_at desc, h.id desc;
end $$;

-- ---------------------------------------------------------------------------
-- admin panel counts
-- ---------------------------------------------------------------------------
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
      and exists (select 1 from public.member_cpc_ratings r where r.member_id = m.id and r.deleted_at is null)),
    'rated', (select count(*) from public.members m join public.member_cpc_ratings r on r.member_id = m.id and r.deleted_at is null
      where m.org_id = v_org and m.deleted_at is null and m.status = 'active' and r.points is not null));
end $$;

create or replace function public.cpc_ranking_list(p_category_id text default null)
returns table (member_id text, member_no text, display_name text, category_id text, category_name text, rank_id text,
  rank_name text, rank_idx integer, since timestamptz, points numeric, eligible_match_count integer, provisional boolean,
  points_version integer, assessed_at timestamptz)
language sql stable security invoker set search_path = '' as $$ select * from core.cpc_ranking_list(p_category_id) $$;
create or replace function public.cpc_points_history_view(p_member_id text default null)
returns table (id text, occurred_at timestamptz, entry_type text, points_before numeric, points_after numeric,
  points_delta numeric, match_count_delta integer, reason text, event_name text, division_name text,
  is_reversal boolean, reversed boolean, revision integer)
language sql stable security invoker set search_path = '' as $$ select * from core.cpc_points_history_view(p_member_id) $$;
create or replace function public.cpc_points_status() returns jsonb
language sql stable security invoker set search_path = '' as $$ select core.cpc_points_status() $$;

revoke all on function core.cpc_ranking_list(text), core.cpc_points_history_view(text), core.cpc_points_status(),
  public.cpc_ranking_list(text), public.cpc_points_history_view(text), public.cpc_points_status() from public, anon, authenticated;
grant execute on function core.cpc_ranking_list(text), core.cpc_points_history_view(text), core.cpc_points_status(),
  public.cpc_ranking_list(text), public.cpc_points_history_view(text), public.cpc_points_status() to authenticated, service_role;

notify pgrst, 'reload schema';
