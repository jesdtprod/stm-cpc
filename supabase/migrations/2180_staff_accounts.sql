-- Staff accounts for people who are not members (a court scanner, a referee, front desk, a manager).
--   staff_account_prepare(role, name)   caller must hold roles.manage; checks the role and name and reserves the next staff ID
--                                       (CPC-YYYY-9NNNN, a range real member numbers do not use)
--   create_staff_member(...)            service role only, called by the staff-create Edge Function after it has made the
--                                       Auth user. Writes the club records and gives the role. The account must change its
--                                       first password at the first sign-in.
create or replace function core.staff_account_prepare(p_role_code text, p_display_name text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_me text := core.current_profile_id();
  v_org text;
  v_name text := btrim(coalesce(p_display_name, ''));
  v_yr text := to_char(now() at time zone 'Asia/Manila', 'YYYY');
  v_no text;
begin
  select p.org_id into v_org from public.profiles p where p.id = v_me;
  if v_org is null or not core.has_permission(v_org, null, 'roles.manage') then
    raise exception 'you do not have permission to add staff' using errcode = '42501';
  end if;
  if p_role_code not in ('scanner', 'referee', 'front_desk', 'manager') then
    raise exception 'that role cannot be given to a new staff account' using errcode = '22023';
  end if;
  if char_length(v_name) < 2 or char_length(v_name) > 120 then
    raise exception 'enter the staff member''s name (2 to 120 characters)' using errcode = '22023';
  end if;
  v_no := format('CPC-%s-%s', v_yr, lpad((90000 + core.next_number(v_org, null, 'staff-' || v_yr))::text, 5, '0'));
  return jsonb_build_object('member_no', v_no, 'actor', v_me);
end $$;

create or replace function core.create_staff_member(p_member_no text, p_display_name text, p_role_code text, p_auth_user_id uuid, p_actor text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  org text;
  per text;
  prof text;
  mem text;
  rid text;
begin
  select id into org from public.orgs where code = 'cpc' and deleted_at is null;
  if p_role_code not in ('scanner', 'referee', 'front_desk', 'manager') then
    raise exception 'that role cannot be given to a new staff account' using errcode = '22023';
  end if;
  select m.id into mem from public.members m where m.member_no = p_member_no and m.org_id = org and m.deleted_at is null;
  if mem is not null then
    raise exception 'that member number already exists' using errcode = '23505';
  end if;
  select r.id into rid from public.roles r where r.org_id = org and r.code = p_role_code and r.deleted_at is null;
  if rid is null then
    raise exception 'that role is missing' using errcode = '22023';
  end if;
  insert into public.persons (org_id, kind, display_name) values (org, 'member', btrim(p_display_name)) returning id into per;
  insert into public.profiles (org_id, auth_user_id, person_id) values (org, p_auth_user_id, per) returning id into prof;
  insert into public.org_members (org_id, profile_id, role_id) values (org, prof, rid);
  insert into public.members (org_id, person_id, profile_id, member_no, status, joined_on)
  values (org, per, prof, p_member_no, 'pending_approval', (now() at time zone 'Asia/Manila')::date)
  returning id into mem;
  update public.members set status = 'active', status_reason = 'staff account' where id = mem;
  insert into public.member_access (org_id, member_id, must_change_password) values (org, mem, true);
  perform core.write_audit(org, 'staff.created', 'public.members', mem, null,
    jsonb_build_object('role', p_role_code, 'created_by_profile', p_actor));
  return mem;
end $$;

create or replace function public.staff_account_prepare(p_role_code text, p_display_name text) returns jsonb
language sql security invoker set search_path = '' as $$ select core.staff_account_prepare(p_role_code, p_display_name) $$;
create or replace function public.create_staff_member(p_member_no text, p_display_name text, p_role_code text, p_auth_user_id uuid, p_actor text) returns text
language sql security invoker set search_path = '' as $$ select core.create_staff_member(p_member_no, p_display_name, p_role_code, p_auth_user_id, p_actor) $$;

revoke all on function core.staff_account_prepare(text, text), public.staff_account_prepare(text, text),
  core.create_staff_member(text, text, text, uuid, text), public.create_staff_member(text, text, text, uuid, text)
  from public, anon, authenticated;
-- The prepare function checks roles.manage itself; the create function is for the service role only.
grant execute on function core.staff_account_prepare(text, text), public.staff_account_prepare(text, text) to authenticated, service_role;
grant execute on function core.create_staff_member(text, text, text, uuid, text), public.create_staff_member(text, text, text, uuid, text) to service_role;

-- The staff list also shows scanner accounts.
create or replace function core.staff_directory(p_term text, p_only_staff boolean) returns table (
  member_id text, member_no text, display_name text, status text, role_code text, role_name text, is_self boolean
)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_org text;
  v_me text := core.current_profile_id();
  v_term text := nullif(btrim(coalesce(p_term, '')), '');
begin
  select p.org_id into v_org from public.profiles p where p.id = v_me;
  if v_org is null or not core.has_permission(v_org, null, 'roles.manage') then
    raise exception 'you do not have permission to see staff roles' using errcode = '42501';
  end if;
  if not coalesce(p_only_staff, false) and (v_term is null or char_length(v_term) < 2) then
    raise exception 'type at least 2 characters to search' using errcode = '22023';
  end if;
  return query
  select m.id, m.member_no, pe.display_name, m.status, r.code, r.name, (m.profile_id = v_me)
  from public.members m
  join public.persons pe on pe.id = m.person_id
  join public.org_members om on om.profile_id = m.profile_id and om.org_id = m.org_id and om.deleted_at is null and om.unit_id is null
  join public.roles r on r.id = om.role_id
  where m.org_id = v_org and m.deleted_at is null and m.profile_id is not null
    and (not coalesce(p_only_staff, false) or r.code in ('scanner', 'referee', 'front_desk', 'manager', 'admin'))
    and (v_term is null or m.member_no ilike '%' || replace(replace(v_term, '%', ''), '_', '') || '%'
         or pe.display_name ilike '%' || replace(replace(v_term, '%', ''), '_', '') || '%')
    and (coalesce(p_only_staff, false) or m.status = 'active')
  order by (r.code = 'admin') desc, r.code, pe.display_name
  limit 25;
end $$;

notify pgrst, 'reload schema';
