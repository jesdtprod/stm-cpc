-- Editor role: a member the club trusts to correct other members' profiles and ratings, and nothing else.
--   members.read          see the member list and details
--   members.edit_profile  change another member's profile details (new; not member ID, status or role)
--   ranks.override        set a member's rating by hand (already checked by the rating functions)
-- An editor stays a normal member (no staff flag); an admin gives the role from the Staff screen like the other roles.
insert into public.roles (org_id, code, name, description, is_system)
select o.id, 'editor', 'Editor', 'Can edit member profiles and ratings. Cannot approve, suspend or delete members.', true
from public.orgs o where o.code = 'cpc' and o.deleted_at is null
on conflict (org_id, code) where deleted_at is null do nothing;

select core.add_permission('members.edit_profile', 'Edit another member''s profile details', array['editor']);

insert into public.role_permissions (org_id, role_id, permission_id)
select r.org_id, r.id, pe.id
from public.roles r
join public.orgs o on o.id = r.org_id and o.code = 'cpc'
join public.permissions pe on pe.code in ('members.read', 'ranks.override') and pe.deleted_at is null
where r.code = 'editor' and r.deleted_at is null
on conflict (role_id, permission_id) where deleted_at is null do nothing;

-- The role may be given from the Staff screen (the list of allowed codes grows by one).
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
  if p_role_code not in ('member', 'editor', 'referee', 'front_desk', 'manager', 'admin') then
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
    and (not coalesce(p_only_staff, false) or r.code in ('scanner', 'editor', 'referee', 'front_desk', 'manager', 'admin'))
    and (v_term is null or m.member_no ilike '%' || replace(replace(v_term, '%', ''), '_', '') || '%'
         or pe.display_name ilike '%' || replace(replace(v_term, '%', ''), '_', '') || '%')
    and (coalesce(p_only_staff, false) or m.status = 'active')
  order by (r.code = 'admin') desc, r.code, pe.display_name
  limit 25;
end $$;


-- Edit another member's profile. Null keeps the stored value, '' clears an optional one. Name, mobile and email are required.
create or replace function core.admin_update_member_profile(
  p_member_id text, p_display_name text, p_mobile text, p_email text, p_street_line text,
  p_first_name text, p_middle_name text, p_last_name text, p_suffix text, p_gender text,
  p_date_of_birth date, p_dupr_id text, p_reason text, p_key text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_me text := core.current_profile_id();
  mem public.members;
  per public.persons;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_name text := nullif(regexp_replace(btrim(coalesce(p_display_name, '')), '\s+', ' ', 'g'), '');
  v_mobile text := nullif(btrim(coalesce(p_mobile, '')), '');
  v_digits text;
  v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  v_street text;
  v_first text; v_middle text; v_last text; v_suffix text; v_gender text; v_dob date; v_dupr text;
  v_replay jsonb;
  v_response jsonb;
begin
  select m.* into mem from public.members m where m.id = p_member_id and m.deleted_at is null;
  if not found then
    raise exception 'member not found' using errcode = '22023';
  end if;
  if v_me is null or not core.has_permission(mem.org_id, null, 'members.edit_profile') then
    raise exception 'you do not have permission to edit member profiles' using errcode = '42501';
  end if;
  if v_reason is null or char_length(v_reason) < 3 then
    raise exception 'a reason is required' using errcode = '22023';
  end if;
  if char_length(v_reason) > 500 then
    raise exception 'the reason is too long' using errcode = '22023';
  end if;
  select * into per from public.persons where id = mem.person_id;

  if v_name is null or length(v_name) not between 2 and 120 then
    raise exception 'name must be 2 to 120 characters' using errcode = '22023';
  end if;
  if v_mobile is null then
    raise exception 'a mobile number is required' using errcode = '22023';
  end if;
  v_digits := regexp_replace(v_mobile, '\D', '', 'g');
  if v_digits ~ '^639\d{9}$' then
    v_mobile := '0' || substr(v_digits, 3);
  elsif v_digits ~ '^9\d{9}$' then
    v_mobile := '0' || v_digits;
  elsif v_digits ~ '^09\d{9}$' then
    v_mobile := v_digits;
  else
    raise exception 'enter a valid mobile number, for example 09171234567' using errcode = '22023';
  end if;
  if v_email is null or length(v_email) > 254 or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'enter a valid email address' using errcode = '22023';
  end if;
  v_street := case when p_street_line is null then per.street_line else nullif(btrim(p_street_line), '') end;
  if v_street is not null and length(v_street) > 200 then
    raise exception 'the street line is too long' using errcode = '22023';
  end if;
  v_first := case when p_first_name is null then per.first_name else nullif(regexp_replace(btrim(p_first_name), '\s+', ' ', 'g'), '') end;
  v_middle := case when p_middle_name is null then per.middle_name else nullif(regexp_replace(btrim(p_middle_name), '\s+', ' ', 'g'), '') end;
  v_last := case when p_last_name is null then per.last_name else nullif(regexp_replace(btrim(p_last_name), '\s+', ' ', 'g'), '') end;
  v_suffix := case when p_suffix is null then per.suffix else nullif(btrim(p_suffix), '') end;
  v_gender := case when p_gender is null then per.gender else nullif(lower(btrim(p_gender)), '') end;
  v_dob := coalesce(p_date_of_birth, per.date_of_birth);
  v_dupr := case when p_dupr_id is null then per.dupr_id else nullif(upper(btrim(p_dupr_id)), '') end;
  if v_dupr is not null and v_dupr !~ '^[A-Z0-9]{1,32}$' then
    raise exception 'enter a DUPR ID using 1 to 32 letters or numbers' using errcode = '22023';
  end if;
  if v_dob is not null and (v_dob < date '1920-01-01' or v_dob > (now() at time zone 'Asia/Manila')::date) then
    raise exception 'enter a valid date of birth' using errcode = '22023';
  end if;
  if coalesce(length(v_first), 0) > 60 or coalesce(length(v_middle), 0) > 60 or coalesce(length(v_last), 0) > 60 then
    raise exception 'each part of the name must be at most 60 characters' using errcode = '22023';
  end if;
  if v_suffix is not null and v_suffix not in ('Jr.', 'Sr.', 'II', 'III', 'IV', 'V') then
    raise exception 'choose a suffix from the list' using errcode = '22023';
  end if;
  if v_gender is not null and v_gender not in ('male', 'female') then
    raise exception 'choose male or female' using errcode = '22023';
  end if;

  v_replay := core.idem_begin(p_key, mem.org_id, 'member.edit_profile',
    jsonb_build_object('member_id', p_member_id, 'name', v_name, 'mobile', v_mobile, 'email', v_email, 'street', v_street,
      'first', v_first, 'middle', v_middle, 'last', v_last, 'suffix', v_suffix, 'gender', v_gender, 'dob', v_dob,
      'dupr', v_dupr, 'reason', v_reason));
  if v_replay is not null then
    return v_replay;
  end if;

  update public.persons set
    display_name = v_name, first_name = v_first, middle_name = v_middle, last_name = v_last, suffix = v_suffix,
    gender = v_gender, date_of_birth = v_dob, dupr_id = v_dupr, mobile = v_mobile, email = v_email, street_line = v_street
  where id = mem.person_id;
  -- The audit row names the fields changed, never their values (personal data stays out of the log).
  perform core.write_audit(mem.org_id, 'member.edit_profile', 'public.members', mem.id, null,
    jsonb_build_object('reason', v_reason, 'fields', (
      select coalesce(jsonb_agg(f.name order by f.name), '[]'::jsonb) from (values
        ('display_name', per.display_name is distinct from v_name), ('first_name', per.first_name is distinct from v_first),
        ('middle_name', per.middle_name is distinct from v_middle), ('last_name', per.last_name is distinct from v_last),
        ('suffix', per.suffix is distinct from v_suffix), ('gender', per.gender is distinct from v_gender),
        ('date_of_birth', per.date_of_birth is distinct from v_dob), ('dupr_id', per.dupr_id is distinct from v_dupr),
        ('mobile', per.mobile is distinct from v_mobile), ('email', per.email is distinct from v_email),
        ('street_line', per.street_line is distinct from v_street)
      ) as f(name, changed) where f.changed)));
  v_response := jsonb_build_object('ok', true, 'member_id', mem.id);
  perform core.idem_complete(p_key, v_response);
  return v_response;
end $$;

create or replace function public.admin_update_member_profile(
  p_member_id text, p_display_name text, p_mobile text, p_email text, p_street_line text,
  p_first_name text, p_middle_name text, p_last_name text, p_suffix text, p_gender text,
  p_date_of_birth date, p_dupr_id text, p_reason text, p_key text
) returns jsonb
language sql security invoker set search_path = '' as $$
  select core.admin_update_member_profile(p_member_id, p_display_name, p_mobile, p_email, p_street_line, p_first_name,
    p_middle_name, p_last_name, p_suffix, p_gender, p_date_of_birth, p_dupr_id, p_reason, p_key)
$$;

revoke all on function
  core.admin_update_member_profile(text, text, text, text, text, text, text, text, text, text, date, text, text, text),
  public.admin_update_member_profile(text, text, text, text, text, text, text, text, text, text, date, text, text, text)
  from public, anon;
grant execute on function
  core.admin_update_member_profile(text, text, text, text, text, text, text, text, text, text, date, text, text, text),
  public.admin_update_member_profile(text, text, text, text, text, text, text, text, text, text, date, text, text, text)
  to authenticated, service_role;

notify pgrst, 'reload schema';
