-- 1290_staff_roles (PLAN 4.6): staff and role assignment, all behind roles.manage (admin).
--   staff_directory(term, only_staff)   members with an account and their current role, for the staff list and for
--                                       finding someone to give a role to (at most 25 rows)
--   role_catalog()                      the roles and the permissions each one holds (read-only reference)
--   assign_role(member, role, reason, key)
--       gives an active member one of the roles below. Rules: you cannot change your own role; the member must be
--       active and have an account; the last admin cannot be demoted; a role change is idempotent and audited, with
--       the old and new role. Assignable roles: member, referee, front_desk, manager, admin.
--       (pending_member is given by sign-up and removed by approval, never assigned by hand.)

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
    and (not coalesce(p_only_staff, false) or r.code in ('referee', 'front_desk', 'manager', 'admin'))
    and (v_term is null or m.member_no ilike '%' || replace(replace(v_term, '%', ''), '_', '') || '%'
         or pe.display_name ilike '%' || replace(replace(v_term, '%', ''), '_', '') || '%')
    and (coalesce(p_only_staff, false) or m.status = 'active')
  order by (r.code = 'admin') desc, r.code, pe.display_name
  limit 25;
end $$;

create or replace function core.role_catalog() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_org text;
begin
  select p.org_id into v_org from public.profiles p where p.id = core.current_profile_id();
  if v_org is null or not core.has_permission(v_org, null, 'roles.manage') then
    raise exception 'you do not have permission to see roles' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'code', r.code, 'name', r.name, 'description', r.description,
      'permissions', coalesce((
        select jsonb_agg(jsonb_build_object('code', pe.code, 'description', pe.description) order by pe.code)
        from public.role_permissions rp join public.permissions pe on pe.id = rp.permission_id
        where rp.role_id = r.id and rp.deleted_at is null and pe.deleted_at is null), '[]'::jsonb))
      order by array_position(array['pending_member', 'member', 'referee', 'front_desk', 'manager', 'admin'], r.code), r.code)
    from public.roles r where r.org_id = v_org and r.deleted_at is null), '[]'::jsonb);
end $$;

create or replace function core.assign_role(p_member_id text, p_role_code text, p_reason text, p_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_me text := core.current_profile_id();
  v_mem public.members;
  v_role public.roles;
  v_row public.org_members;
  v_old public.roles;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_admins integer;
  v_replay jsonb;
  v_response jsonb;
begin
  select * into v_mem from public.members m where m.id = p_member_id and m.deleted_at is null;
  if not found then
    raise exception 'member not found' using errcode = '22023';
  end if;
  if not core.has_permission(v_mem.org_id, null, 'roles.manage') then
    raise exception 'you do not have permission to assign roles' using errcode = '42501';
  end if;
  if v_mem.profile_id is not distinct from v_me then
    raise exception 'you cannot change your own role' using errcode = '42501';
  end if;
  if p_role_code not in ('member', 'referee', 'front_desk', 'manager', 'admin') then
    raise exception 'that role cannot be assigned here' using errcode = '22023';
  end if;
  if v_mem.profile_id is null or v_mem.status <> 'active' then
    raise exception 'only an active member with an account can be given a role' using errcode = '22023';
  end if;
  if v_reason is null or char_length(v_reason) < 3 then
    raise exception 'a reason is required' using errcode = '22023';
  end if;
  if char_length(v_reason) > 500 then
    raise exception 'the reason is too long' using errcode = '22023';
  end if;
  select * into v_role from public.roles r where r.org_id = v_mem.org_id and r.code = p_role_code and r.deleted_at is null;
  select * into v_row from public.org_members om
  where om.profile_id = v_mem.profile_id and om.org_id = v_mem.org_id and om.deleted_at is null and om.unit_id is null for update;
  if not found then
    raise exception 'the member has no club access record' using errcode = '22023';
  end if;
  select * into v_old from public.roles r where r.id = v_row.role_id;

  v_replay := core.idem_begin(p_key, v_mem.org_id, 'role.assign',
    jsonb_build_object('member_id', p_member_id, 'role', p_role_code, 'reason', v_reason));
  if v_replay is not null then
    return v_replay;
  end if;
  if v_row.role_id = v_role.id then
    v_response := jsonb_build_object('ok', true, 'member_id', v_mem.id, 'role', p_role_code, 'unchanged', true);
    perform core.idem_complete(p_key, v_response);
    return v_response;
  end if;
  if v_old.code = 'admin' then
    select count(*)::integer into v_admins from public.org_members om
    join public.roles r on r.id = om.role_id
    where om.org_id = v_mem.org_id and om.deleted_at is null and om.is_active and r.code = 'admin';
    if v_admins <= 1 then
      raise exception 'the last admin cannot be demoted; make someone else an admin first' using errcode = '22023';
    end if;
  end if;

  update public.org_members set role_id = v_role.id where id = v_row.id;
  perform core.write_audit(v_mem.org_id, 'role.assign', 'public.org_members', v_row.id,
    jsonb_build_object('member_id', v_mem.id, 'role', v_old.code),
    jsonb_build_object('member_id', v_mem.id, 'role', p_role_code, 'reason', v_reason));
  v_response := jsonb_build_object('ok', true, 'member_id', v_mem.id, 'role', p_role_code);
  perform core.idem_complete(p_key, v_response);
  return v_response;
end $$;

create or replace function public.staff_directory(p_term text, p_only_staff boolean) returns table (
  member_id text, member_no text, display_name text, status text, role_code text, role_name text, is_self boolean
)
language sql stable security invoker set search_path = '' as $$ select * from core.staff_directory(p_term, p_only_staff) $$;
create or replace function public.role_catalog() returns jsonb
language sql stable security invoker set search_path = '' as $$ select core.role_catalog() $$;
create or replace function public.assign_role(p_member_id text, p_role_code text, p_reason text, p_key text) returns jsonb
language sql security invoker set search_path = '' as $$ select core.assign_role(p_member_id, p_role_code, p_reason, p_key) $$;

revoke all on function core.staff_directory(text, boolean), core.role_catalog(), core.assign_role(text, text, text, text),
  public.staff_directory(text, boolean), public.role_catalog(), public.assign_role(text, text, text, text)
  from public, anon, authenticated;
-- The functions check roles.manage themselves.
grant execute on function core.staff_directory(text, boolean), core.role_catalog(), core.assign_role(text, text, text, text),
  public.staff_directory(text, boolean), public.role_catalog(), public.assign_role(text, text, text, text)
  to authenticated, service_role;
