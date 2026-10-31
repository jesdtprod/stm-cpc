-- Staff accounts are not shown as members.
-- Anyone who holds a staff role (scanner, referee, front desk, manager, admin) is flagged on the members row, kept up to
-- date by triggers, and left out of the public Members page, the rankings, the partner pickers and the admin Members list.
alter table public.members add column if not exists is_staff_account boolean not null default false;
comment on column public.members.is_staff_account is 'True while the member holds a staff role (scanner, referee, front_desk, manager, admin). Set by triggers; staff are left out of member lists.';

create or replace function core.is_staff_profile(p_profile_id text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.org_members om join public.roles r on r.id = om.role_id
    where om.profile_id = p_profile_id and om.deleted_at is null and om.is_active
      and r.code in ('scanner', 'referee', 'front_desk', 'manager', 'admin')
  )
$$;
revoke all on function core.is_staff_profile(text) from public, anon, authenticated;

-- a new member row takes the flag from the profile's current role
create or replace function core.tg_members_staff_flag_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.is_staff_account := new.profile_id is not null and core.is_staff_profile(new.profile_id);
  return new;
end $$;
create trigger c1_members_staff_flag before insert on public.members
  for each row execute function core.tg_members_staff_flag_insert();

-- a role change moves the flag
create or replace function core.tg_org_members_staff_flag() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.members m set is_staff_account = core.is_staff_profile(new.profile_id)
  where m.profile_id = new.profile_id and m.is_staff_account is distinct from core.is_staff_profile(new.profile_id);
  return new;
end $$;
create trigger z_org_members_staff_flag after insert or update on public.org_members
  for each row execute function core.tg_org_members_staff_flag();

update public.members m set is_staff_account = true
where m.profile_id is not null and core.is_staff_profile(m.profile_id) and not m.is_staff_account;

create or replace function core.public_member_rows() returns table (
  member_id text, display_name text, avatar_path text, category_name text, rank_name text, rank_idx integer
)
language sql stable security definer set search_path = '' as $$
  with club as (
    select o.id from public.orgs o
    where o.code = 'cpc' and o.deleted_at is null and core.setting_bool(o.id, 'public.members_enabled', true)
  )
  select m.id, p.display_name, p.avatar_path, c.name, r.name, ch.idx
  from public.members m
  join club on club.id = m.org_id
  join public.persons p on p.id = m.person_id and p.deleted_at is null
  left join public.member_ranks mr on mr.member_id = m.id and mr.deleted_at is null
  left join public.ranks r on r.id = mr.rank_id
  left join public.rank_ladders l on l.id = r.ladder_id
  left join public.categories c on c.id = l.category_id
  left join core.rank_chain(club.id) ch on ch.rank_id = r.id
  where m.deleted_at is null and not m.is_staff_account and m.status in ('active', 'imported', 'invited')
$$;

create or replace function core.ranking_list(p_category_id text default null)
returns table (member_id text, member_no text, display_name text, category_id text, category_name text, rank_id text,
  rank_name text, rank_idx integer, since timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_org text;
begin
  select pr.org_id into v_org from public.profiles pr where pr.auth_user_id = (select auth.uid()) and pr.is_active and pr.deleted_at is null limit 1;
  if v_org is null or not core.is_org_member(v_org) then
    raise exception 'sign in to see the ranking' using errcode = '42501';
  end if;
  return query
  select m.id, m.member_no, pe.display_name, c.id, c.name, r.id, r.name, ch.idx, mr.updated_at
  from public.member_ranks mr
  join public.members m on m.id = mr.member_id and m.deleted_at is null and m.status = 'active' and not m.is_staff_account
  join public.persons pe on pe.id = m.person_id
  join public.ranks r on r.id = mr.rank_id
  join public.rank_ladders l on l.id = r.ladder_id
  join public.categories c on c.id = l.category_id
  join core.rank_chain(v_org) ch on ch.rank_id = r.id
  where mr.deleted_at is null and m.org_id = v_org and (p_category_id is null or c.id = p_category_id)
  order by ch.idx desc, pe.display_name;
end $$;

create or replace function core.cpc_ranking_list(p_category_id text default null)
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
  where m.org_id = v_org and m.deleted_at is null and m.status = 'active' and not m.is_staff_account
    and (p_category_id is null or c.id = p_category_id)
  order by greatest(sr.points, dr.points) desc nulls last, ch.idx desc nulls last, pe.display_name;
end $$;

create or replace function core.eligible_partners(p_division_id text, p_term text)
returns table (member_id text, display_name text, member_no text)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_me public.members; dv public.divisions; v_term text := lower(btrim(coalesce(p_term, '')));
begin
  select m.* into v_me from public.members m join public.profiles pr on pr.id = m.profile_id
  where pr.auth_user_id = (select auth.uid()) and pr.is_active and pr.deleted_at is null and m.deleted_at is null limit 1;
  if v_me.id is null then
    raise exception 'sign in as a member to find a partner' using errcode = '42501';
  end if;
  select * into dv from public.divisions d where d.id = p_division_id and d.org_id = v_me.org_id;
  if not found then
    raise exception 'division not found' using errcode = '22023';
  end if;
  if dv.format <> 'doubles' then
    raise exception 'only a doubles division takes a partner' using errcode = '22023';
  end if;
  if char_length(v_term) < 2 then
    return;
  end if;
  return query
  with cand as materialized (
    select m.id as mid, pe.display_name as dname, m.member_no as mno
    from public.members m join public.persons pe on pe.id = m.person_id
    where m.org_id = v_me.org_id and m.deleted_at is null and m.status = 'active' and not m.is_staff_account and m.id <> v_me.id
      and (strpos(lower(pe.display_name), v_term) > 0 or strpos(lower(m.member_no), v_term) > 0)
      and not exists (
        select 1 from public.registrations r
        where r.division_id = dv.id and r.status in ('requested', 'confirmed', 'waitlisted')
          and (r.member_id = m.id or (r.meta ->> 'partner_member_id') = m.id))
    order by pe.display_name limit 100
  )
  select c.mid, c.dname, c.mno from cand c
  where core.registration_problem(c.mid, dv.id, true) is null
  order by c.dname limit 20;
end $$;

create or replace function core.eligible_event_partners(p_division_id text, p_guest_participant_id text default null)
returns table(id text, display_name text, member_id text, member_no text, is_guest boolean)
language plpgsql stable security definer set search_path = '' as $$
declare dv public.divisions; ev public.events; v_ratings boolean;
begin
  select * into dv from public.divisions d where d.id = p_division_id;
  if not found then raise exception 'division not found' using errcode = '22023'; end if;
  select * into ev from public.events e where e.id = dv.event_id;
  if core.current_profile_id() is null or not core.has_permission(ev.org_id,dv.unit_id,'events.admin_roster') then
    raise exception 'you do not have permission to register guests' using errcode = '42501';
  end if;
  if dv.format <> 'doubles' then return; end if;
  v_ratings := core.cpc_points_enabled(ev.org_id);
  if v_ratings and p_guest_participant_id is not null
    and core.guest_registration_problem(p_guest_participant_id,dv.id,null) is not null then return; end if;
  return query
  select q.pid,q.dname,q.mid,q.mno,q.guest from (
    select ep.id as pid,pe.display_name as dname,null::text as mid,null::text as mno,true as guest
    from public.event_participants ep join public.persons pe on pe.id = ep.person_id
    where ep.event_id = ev.id and ep.org_id = ev.org_id and ep.member_id is null
      and ep.deleted_at is null and pe.deleted_at is null and ep.id is distinct from p_guest_participant_id
      and (not v_ratings or core.guest_registration_problem(ep.id,dv.id,null) is null)
      and not exists(select 1 from public.registrations r where r.division_id = dv.id
        and r.status in ('requested','confirmed','waitlisted')
        and (r.guest_participant_id = ep.id or r.guest_partner_participant_id = ep.id))
    union all
    select ep.id,pe.display_name,m.id,m.member_no,false
    from public.members m join public.persons pe on pe.id = m.person_id
    left join public.event_participants ep on ep.event_id = ev.id and ep.member_id = m.id and ep.deleted_at is null
    where m.org_id = ev.org_id and m.status = 'active' and m.deleted_at is null and not m.is_staff_account and pe.deleted_at is null
      and core.registration_problem(m.id,dv.id,true) is null
      and not exists(select 1 from public.registrations r where r.division_id = dv.id
        and r.status in ('requested','confirmed','waitlisted')
        and (r.member_id = m.id or r.meta->>'partner_member_id' = m.id))
  ) q order by q.dname,q.mid,q.pid;
end $$;

create or replace function public.public_leaderboard(p_category_id text default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_org text;
begin
  select o.id into v_org from public.orgs o where o.code = 'cpc' and o.deleted_at is null;
  if v_org is null or not core.setting_bool(v_org, 'public.leaderboard_enabled', false) then
    return jsonb_build_object('enabled', false);
  end if;
  return jsonb_build_object('enabled', true,
    'categories', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.sort_order, c.name)
                            from public.categories c where c.org_id = v_org and c.deleted_at is null and c.is_active), '[]'::jsonb),
    'players', coalesce((
      select jsonb_agg(jsonb_build_object('name', q.display_name, 'category', q.category_name, 'rank', q.rank_name) order by q.idx desc, q.display_name)
      from (
        select pe.display_name, c.name as category_name, r.name as rank_name, ch.idx
        from public.member_ranks mr
        join public.members m on m.id = mr.member_id and m.deleted_at is null and m.status = 'active' and not m.is_staff_account
        join public.persons pe on pe.id = m.person_id
        join public.ranks r on r.id = mr.rank_id
        join public.rank_ladders l on l.id = r.ladder_id
        join public.categories c on c.id = l.category_id
        join core.rank_chain(v_org) ch on ch.rank_id = r.id
        where mr.deleted_at is null and m.org_id = v_org and (p_category_id is null or c.id = p_category_id)
        order by ch.idx desc, pe.display_name limit 200) q), '[]'::jsonb));
end $$;

create or replace function core.ranking_photos(p_member_ids text[])
returns table (member_id text, avatar_path text)
language plpgsql stable security definer set search_path = '' as $$
declare v_org text;
begin
  select pr.org_id into v_org from public.profiles pr
  where pr.auth_user_id = (select auth.uid()) and pr.is_active and pr.deleted_at is null limit 1;
  if v_org is null or not core.is_org_member(v_org) then
    raise exception 'sign in to see ranking photos' using errcode = '42501';
  end if;
  if cardinality(p_member_ids) > 1000 then
    raise exception 'request at most 1000 ranking photos' using errcode = '22023';
  end if;
  return query select distinct m.id, pe.avatar_path
  from public.members m
  join public.persons pe on pe.id = m.person_id and pe.deleted_at is null
  join public.member_ranks mr on mr.member_id = m.id and mr.deleted_at is null
  where m.org_id = v_org and m.id = any(p_member_ids)
    and m.status = 'active' and not m.is_staff_account and m.deleted_at is null and pe.avatar_path is not null;
end $$;

create or replace function public.club_home_stats() returns jsonb
language sql volatile security definer set search_path = '' as $$
  with club as (
    select o.id from public.orgs o where o.code = 'cpc' and o.deleted_at is null
  ), active_members as (
    select m.id, p.first_name, p.last_name, p.display_name, p.avatar_path
    from public.members m join club c on c.id = m.org_id
    join public.persons p on p.id = m.person_id and p.deleted_at is null
    where m.status = 'active' and m.deleted_at is null and not m.is_staff_account
  ), displayed_members as materialized (
    select *, random() as draw from active_members order by draw, id limit 15
  ), representative as (
    select * from displayed_members order by draw, id limit 1
  )
  select jsonb_build_object(
    'active_members', (select count(*) from active_members),
    'member_initials', (select coalesce(
      nullif(upper(left(btrim(coalesce(first_name, '')), 1) || left(btrim(coalesce(last_name, '')), 1)), ''),
      nullif(upper(left(btrim(coalesce(display_name, '')), 1)), ''), 'C') from representative),
    'member_badges', coalesce((select jsonb_agg(jsonb_build_object(
      'initials', coalesce(
        nullif(upper(left(btrim(coalesce(first_name, '')), 1) || left(btrim(coalesce(last_name, '')), 1)), ''),
        nullif(upper(left(btrim(coalesce(display_name, '')), 1)), ''), 'C'),
      'avatar_path', avatar_path) order by draw, id) from displayed_members), '[]'::jsonb)
  )
$$;

notify pgrst, 'reload schema';
