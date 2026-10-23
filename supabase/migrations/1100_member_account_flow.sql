-- 1100_member_account_flow (PLAN 3.4)
-- What the sign-in, forced-password-change, profile and pending pages need from the database:
--   * my_access_state(): the caller's member status, whether a password change is required, and whether
--     the profile is complete (members cannot read member_access directly).
--   * update_my_profile(): a member edits only their own contact and address, through one validated function.
--   * member_password_changed(): service-only; called by the member-password Edge Function after Auth accepted
--     the new password. Clears the forced-change flag and moves the member forward.
-- Lifecycle: imported -> (first sign-in) invited -> (password changed AND profile complete) pending_approval.
-- An admin then approves (step 3.5). Nothing here grants permissions: an unapproved member keeps the
-- pending role, which holds none.

-- The first sign-in turns "imported" into "invited" (credentials issued).
create or replace function core.member_login_succeeded(p_member_id text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  org text;
begin
  update public.member_access set last_login_at = now(), failed_attempts = 0, locked_until = null
  where member_id = p_member_id and deleted_at is null;
  update public.members set status = 'invited', status_reason = 'first sign-in'
  where id = p_member_id and status = 'imported' and deleted_at is null;
  select m.org_id into org from public.members m where m.id = p_member_id;
  if org is not null then
    insert into core.audit_log (org_id, actor_id, action, table_name, record_id)
    values (org, 'system', 'login.success', 'public.members', p_member_id);
  end if;
end $$;

-- A profile is complete when the member has a mobile number and an address down to the barangay.
create or replace function core.profile_complete(p_person_id text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select p.mobile is not null and length(btrim(p.mobile)) >= 7 and p.barangay_code is not null
     from public.persons p where p.id = p_person_id and p.deleted_at is null), false)
$$;

-- Moves invited -> pending_approval once the password is changed and the profile is complete.
create or replace function core.advance_member_if_ready(p_member_id text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.members m set status = 'pending_approval', status_reason = 'password changed and profile completed'
  where m.id = p_member_id and m.status = 'invited' and m.deleted_at is null
    and core.profile_complete(m.person_id)
    and exists (select 1 from public.member_access a where a.member_id = m.id and a.deleted_at is null and not a.must_change_password);
end $$;

create or replace function core.my_access_state()
returns table (member_id text, member_no text, status text, must_change_password boolean, profile_complete boolean, display_name text)
language sql stable security definer set search_path = '' as $$
  select m.id, m.member_no, m.status, coalesce(a.must_change_password, false), core.profile_complete(m.person_id), p.display_name
  from public.profiles pr
  join public.members m on m.profile_id = pr.id and m.deleted_at is null
  join public.persons p on p.id = m.person_id
  left join public.member_access a on a.member_id = m.id and a.deleted_at is null
  where pr.auth_user_id = (select auth.uid()) and pr.is_active and pr.deleted_at is null
  limit 1
$$;

-- A member edits only their own contact details and address. The address trigger on persons derives the
-- province, city and region from the barangay and writes the text snapshot.
create or replace function core.update_my_profile(
  p_display_name text, p_mobile text, p_email text, p_street_line text, p_barangay_code text
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  mem public.members;
  name text := nullif(regexp_replace(btrim(coalesce(p_display_name, '')), '\s+', ' ', 'g'), '');
  mobile text := nullif(btrim(coalesce(p_mobile, '')), '');
  digits text;
  email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  street text := nullif(btrim(coalesce(p_street_line, '')), '');
begin
  select m.* into mem
  from public.members m join public.profiles pr on pr.id = m.profile_id
  where pr.auth_user_id = (select auth.uid()) and pr.is_active and pr.deleted_at is null and m.deleted_at is null;
  if not found or mem.status not in ('invited', 'pending_approval', 'active') then
    raise exception 'profile cannot be edited in this state' using errcode = '42501';
  end if;
  if name is not null and length(name) not between 2 and 120 then
    raise exception 'name must be 2 to 120 characters' using errcode = '22023';
  end if;
  if mobile is null then
    raise exception 'a mobile number is required' using errcode = '22023';
  end if;
  digits := regexp_replace(mobile, '\D', '', 'g');
  if digits ~ '^639\d{9}$' then
    mobile := '0' || substr(digits, 3);
  elsif digits ~ '^9\d{9}$' then
    mobile := '0' || digits;
  elsif digits ~ '^09\d{9}$' then
    mobile := digits;
  else
    raise exception 'enter a valid mobile number, for example 09171234567' using errcode = '22023';
  end if;
  if email is not null and (length(email) > 254 or email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') then
    raise exception 'enter a valid email address' using errcode = '22023';
  end if;
  if p_barangay_code is null or not exists (
    select 1 from public.psgc_areas a where a.org_id = mem.org_id and a.code = p_barangay_code and a.level = 'barangay' and a.deleted_at is null
  ) then
    raise exception 'choose a barangay' using errcode = '22023';
  end if;
  if street is not null and length(street) > 200 then
    raise exception 'the street line is too long' using errcode = '22023';
  end if;

  update public.persons set
    display_name = coalesce(name, display_name),
    mobile = update_my_profile.mobile,
    email = update_my_profile.email,
    street_line = street,
    barangay_code = p_barangay_code,
    city_muni_code = null, province_code = null, region_code = null
  where id = mem.person_id;

  perform core.advance_member_if_ready(mem.id);
end $$;

-- Called by the member-password Edge Function after Auth accepted the new password.
create or replace function core.member_password_changed(p_member_id text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  org text;
begin
  update public.member_access set must_change_password = false, temp_password_expires_at = null
  where member_id = p_member_id and deleted_at is null;
  perform core.advance_member_if_ready(p_member_id);
  select m.org_id into org from public.members m where m.id = p_member_id;
  if org is not null then
    insert into core.audit_log (org_id, actor_id, action, table_name, record_id)
    values (org, 'system', 'password.changed', 'public.members', p_member_id);
  end if;
end $$;

-- Context the password function needs to refuse passwords built from the member's own details.
create or replace function core.member_password_context(p_auth_user_id uuid)
returns table (member_id text, member_no text, status text, date_of_birth date)
language sql stable security definer set search_path = '' as $$
  select m.id, m.member_no, m.status, p.date_of_birth
  from public.profiles pr
  join public.members m on m.profile_id = pr.id and m.deleted_at is null
  join public.persons p on p.id = m.person_id
  where pr.auth_user_id = p_auth_user_id and pr.is_active and pr.deleted_at is null
  limit 1
$$;

create or replace function public.my_access_state()
returns table (member_id text, member_no text, status text, must_change_password boolean, profile_complete boolean, display_name text)
language sql stable security invoker set search_path = '' as $$ select * from core.my_access_state() $$;
create or replace function public.update_my_profile(p_display_name text, p_mobile text, p_email text, p_street_line text, p_barangay_code text) returns void
language sql security invoker set search_path = '' as $$ select core.update_my_profile(p_display_name, p_mobile, p_email, p_street_line, p_barangay_code) $$;
create or replace function public.member_password_changed(p_member_id text) returns void
language sql security invoker set search_path = '' as $$ select core.member_password_changed(p_member_id) $$;
create or replace function public.member_password_context(p_auth_user_id uuid)
returns table (member_id text, member_no text, status text, date_of_birth date)
language sql stable security invoker set search_path = '' as $$ select * from core.member_password_context(p_auth_user_id) $$;

revoke all on function core.profile_complete(text), core.advance_member_if_ready(text), core.my_access_state(),
  core.update_my_profile(text, text, text, text, text), core.member_password_changed(text), core.member_password_context(uuid),
  public.my_access_state(), public.update_my_profile(text, text, text, text, text),
  public.member_password_changed(text), public.member_password_context(uuid) from public, anon, authenticated;
-- Members call these two through the API (and the wrappers call the core ones as the member).
grant execute on function core.my_access_state(), core.update_my_profile(text, text, text, text, text),
  public.my_access_state(), public.update_my_profile(text, text, text, text, text) to authenticated, service_role;
-- Service-only.
grant execute on function core.profile_complete(text), core.advance_member_if_ready(text), core.member_password_changed(text),
  core.member_password_context(uuid), public.member_password_changed(text), public.member_password_context(uuid) to service_role;
