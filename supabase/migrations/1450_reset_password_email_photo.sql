-- 1450_reset_password_email_photo: three things for member accounts.
--   1. An administrator can reset a member's password (members.reset_password) to the first-password rule: the last 5 digits
--      of the member ID followed by the birth date as MMDDYYYY. The reset makes the member change the password AND confirm
--      their profile and email at the next sign-in (must_confirm_profile). The Edge Function member-reset sets the password
--      in Auth; these functions check the caller, refuse administrators, the caller's own account and members with no
--      sign-in or birth date, and write the audit log.
--   2. An email address is always required: the profile is incomplete without one and update_my_profile refuses to clear it.
--      confirm_my_profile() clears the confirm flag once the profile is complete.
--   3. A profile photo in Supabase Storage: private bucket "avatars" (path <org_id>/<profile_id>/<file>), 2 MB, JPEG, PNG or
--      WebP. Members upload to their own folder only; staff who can read members can see the photos. set_my_avatar records
--      the path on the person (an old file stays in storage until a retention purge, there is no hard delete from the app).

select core.add_permission('members.reset_password', 'Reset a member''s password to the first-password rule');

alter table public.member_access add column must_confirm_profile boolean not null default false;
alter table public.persons add column avatar_path text constraint persons_avatar_path_chk check (avatar_path is null or length(avatar_path) <= 200);

-- A complete profile has an email as well.
create or replace function core.profile_complete(p_person_id text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select p.mobile is not null and length(btrim(p.mobile)) >= 7 and p.barangay_code is not null
            and p.email is not null and p.email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
     from public.persons p where p.id = p_person_id and p.deleted_at is null), false)
$$;

-- my_access_state() also says whether the member must confirm their profile, and returns the photo path.
drop function public.my_access_state();
drop function core.my_access_state();

create or replace function core.my_access_state()
returns table (
  member_id text, member_no text, status text, must_change_password boolean, profile_complete boolean, display_name text,
  mobile text, email text, street_line text, barangay_code text, city_muni_code text, province_code text, region_code text,
  first_name text, middle_name text, last_name text, suffix text, gender text, date_of_birth date,
  emergency_name text, emergency_relationship text, emergency_phone text, must_confirm_profile boolean, avatar_path text
)
language sql stable security definer set search_path = '' as $$
  select m.id, m.member_no, m.status, coalesce(a.must_change_password, false), core.profile_complete(m.person_id), p.display_name,
         p.mobile, p.email, p.street_line, p.barangay_code, p.city_muni_code, p.province_code, p.region_code,
         p.first_name, p.middle_name, p.last_name, p.suffix, p.gender, p.date_of_birth,
         p.emergency_name, p.emergency_relationship, p.emergency_phone, coalesce(a.must_confirm_profile, false), p.avatar_path
  from public.profiles pr
  join public.members m on m.profile_id = pr.id and m.deleted_at is null
  join public.persons p on p.id = m.person_id
  left join public.member_access a on a.member_id = m.id and a.deleted_at is null
  where pr.auth_user_id = (select auth.uid()) and pr.is_active and pr.deleted_at is null
  limit 1
$$;

create or replace function public.my_access_state()
returns table (
  member_id text, member_no text, status text, must_change_password boolean, profile_complete boolean, display_name text,
  mobile text, email text, street_line text, barangay_code text, city_muni_code text, province_code text, region_code text,
  first_name text, middle_name text, last_name text, suffix text, gender text, date_of_birth date,
  emergency_name text, emergency_relationship text, emergency_phone text, must_confirm_profile boolean, avatar_path text
)
language sql stable security invoker set search_path = '' as $$ select * from core.my_access_state() $$;

create or replace function core.update_my_profile(
  p_display_name text, p_mobile text, p_email text, p_street_line text, p_barangay_code text,
  p_first_name text default null, p_middle_name text default null, p_last_name text default null,
  p_suffix text default null, p_gender text default null,
  p_emergency_name text default null, p_emergency_relationship text default null, p_emergency_phone text default null
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  mem public.members;
  per public.persons;
  v_name text := nullif(regexp_replace(btrim(coalesce(p_display_name, '')), '\s+', ' ', 'g'), '');
  v_mobile text := nullif(btrim(coalesce(p_mobile, '')), '');
  v_digits text;
  v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  v_street text := nullif(btrim(coalesce(p_street_line, '')), '');
  v_first text;
  v_middle text;
  v_last text;
  v_suffix text;
  v_gender text;
  v_em_name text;
  v_em_rel text;
  v_em_phone text;
  v_em_digits text;
begin
  select m.* into mem
  from public.members m join public.profiles pr on pr.id = m.profile_id
  where pr.auth_user_id = (select auth.uid()) and pr.is_active and pr.deleted_at is null and m.deleted_at is null;
  if not found or mem.status not in ('invited', 'pending_approval', 'active') then
    raise exception 'profile cannot be edited in this state' using errcode = '42501';
  end if;
  select * into per from public.persons where id = mem.person_id;

  if v_name is not null and length(v_name) not between 2 and 120 then
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
  if v_email is null then
    raise exception 'an email address is required' using errcode = '22023';
  end if;
  if (length(v_email) > 254 or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') then
    raise exception 'enter a valid email address' using errcode = '22023';
  end if;
  if p_barangay_code is null or not exists (
    select 1 from public.psgc_areas a where a.org_id = mem.org_id and a.code = p_barangay_code and a.level = 'barangay' and a.deleted_at is null
  ) then
    raise exception 'choose a barangay' using errcode = '22023';
  end if;
  if v_street is not null and length(v_street) > 200 then
    raise exception 'the street line is too long' using errcode = '22023';
  end if;

  -- Optional details: null keeps the stored value, '' clears it.
  v_first := case when p_first_name is null then per.first_name else nullif(regexp_replace(btrim(p_first_name), '\s+', ' ', 'g'), '') end;
  v_middle := case when p_middle_name is null then per.middle_name else nullif(regexp_replace(btrim(p_middle_name), '\s+', ' ', 'g'), '') end;
  v_last := case when p_last_name is null then per.last_name else nullif(regexp_replace(btrim(p_last_name), '\s+', ' ', 'g'), '') end;
  v_suffix := case when p_suffix is null then per.suffix else nullif(btrim(p_suffix), '') end;
  v_gender := case when p_gender is null then per.gender else nullif(lower(btrim(p_gender)), '') end;
  v_em_name := case when p_emergency_name is null then per.emergency_name else nullif(regexp_replace(btrim(p_emergency_name), '\s+', ' ', 'g'), '') end;
  v_em_rel := case when p_emergency_relationship is null then per.emergency_relationship else nullif(btrim(p_emergency_relationship), '') end;
  v_em_phone := case when p_emergency_phone is null then per.emergency_phone else nullif(btrim(p_emergency_phone), '') end;

  if coalesce(length(v_first), 0) > 60 or coalesce(length(v_middle), 0) > 60 or coalesce(length(v_last), 0) > 60 then
    raise exception 'each part of the name must be at most 60 characters' using errcode = '22023';
  end if;
  if v_suffix is not null and v_suffix not in ('Jr.', 'Sr.', 'II', 'III', 'IV', 'V') then
    raise exception 'choose a suffix from the list' using errcode = '22023';
  end if;
  if v_gender is not null and v_gender not in ('male', 'female') then
    raise exception 'choose male or female' using errcode = '22023';
  end if;
  if v_em_phone is not null then
    v_em_digits := regexp_replace(v_em_phone, '\D', '', 'g');
    if length(v_em_digits) not between 7 and 13 then
      raise exception 'enter a valid emergency contact number' using errcode = '22023';
    end if;
  end if;
  if (v_em_name is null) <> (v_em_phone is null) then
    raise exception 'an emergency contact needs both a name and a number' using errcode = '22023';
  end if;
  if coalesce(length(v_em_name), 0) > 120 or coalesce(length(v_em_rel), 0) > 60 then
    raise exception 'the emergency contact details are too long' using errcode = '22023';
  end if;

  update public.persons set
    display_name = coalesce(v_name, display_name),
    first_name = v_first, middle_name = v_middle, last_name = v_last, suffix = v_suffix, gender = v_gender,
    mobile = v_mobile,
    email = v_email,
    street_line = v_street,
    barangay_code = p_barangay_code,
    city_muni_code = null, province_code = null, region_code = null,
    emergency_name = v_em_name, emergency_relationship = v_em_rel, emergency_phone = v_em_phone
  where id = mem.person_id;

  perform core.advance_member_if_ready(mem.id);
end $$;

-- Clears the confirm flag once the profile (including an email) is complete.
create or replace function core.confirm_my_profile() returns void
language plpgsql security definer set search_path = '' as $$
declare
  mem public.members;
begin
  select m.* into mem from public.members m join public.profiles pr on pr.id = m.profile_id
  where pr.auth_user_id = (select auth.uid()) and pr.is_active and pr.deleted_at is null and m.deleted_at is null limit 1;
  if not found then
    raise exception 'no member account' using errcode = '42501';
  end if;
  if not core.profile_complete(mem.person_id) then
    raise exception 'complete your profile, including your email, first' using errcode = '22023';
  end if;
  update public.member_access set must_confirm_profile = false where member_id = mem.id and deleted_at is null and must_confirm_profile;
end $$;
create or replace function public.confirm_my_profile() returns void
language sql security invoker set search_path = '' as $$ select core.confirm_my_profile() $$;

-- ---------------------------------------------------------------------------
-- reset a member's password (administrator)
-- ---------------------------------------------------------------------------
-- Step 1, called with the administrator's own session: may they, and for whom? Returns what the function needs.
create or replace function core.admin_prepare_member_reset(p_member_id text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  m public.members;
  per public.persons;
  prof public.profiles;
begin
  select * into m from public.members x where x.id = p_member_id and x.deleted_at is null;
  if not found then
    raise exception 'member not found' using errcode = '22023';
  end if;
  if not core.has_permission(m.org_id, null, 'members.reset_password') then
    raise exception 'you do not have permission to reset passwords' using errcode = '42501';
  end if;
  select * into prof from public.profiles p where p.id = m.profile_id and p.deleted_at is null and p.is_active;
  if not found or prof.auth_user_id is null then
    raise exception 'this member has no sign-in to reset' using errcode = '22023';
  end if;
  if prof.auth_user_id = (select auth.uid()) then
    raise exception 'use Change password for your own account' using errcode = '22023';
  end if;
  if m.status not in ('active', 'invited', 'pending_approval') then
    raise exception 'only an active member or an applicant can have the password reset (this one is %)', m.status using errcode = '22023';
  end if;
  if exists (
    select 1 from public.org_members om join public.roles r on r.id = om.role_id
    where om.profile_id = prof.id and om.deleted_at is null and om.is_active and r.deleted_at is null and r.code = 'admin'
  ) then
    raise exception 'an administrator account cannot be reset here' using errcode = '42501';
  end if;
  select * into per from public.persons p where p.id = m.person_id and p.deleted_at is null;
  if per.date_of_birth is null then
    raise exception 'this member has no birth date on file; add it first' using errcode = '22023';
  end if;
  if m.member_no !~ '^CPC-\d{4}-\d{5}$' then
    raise exception 'this member ID is not in the CPC-YYYY-NNNNN form' using errcode = '22023';
  end if;
  return jsonb_build_object('auth_user_id', prof.auth_user_id, 'member_no', m.member_no, 'date_of_birth', per.date_of_birth);
end $$;

-- Step 2, called after Auth has the new password: the member must change it and confirm their profile; audited.
create or replace function core.admin_finish_member_reset(p_member_id text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m public.members;
begin
  select * into m from public.members x where x.id = p_member_id and x.deleted_at is null;
  if not found then
    raise exception 'member not found' using errcode = '22023';
  end if;
  if not core.has_permission(m.org_id, null, 'members.reset_password') then
    raise exception 'you do not have permission to reset passwords' using errcode = '42501';
  end if;
  update public.member_access set must_change_password = true, must_confirm_profile = true, temp_password_expires_at = null,
    failed_attempts = 0, locked_until = null
  where member_id = m.id and deleted_at is null;
  perform core.write_audit(m.org_id, 'member.password_reset_by_admin', 'public.members', m.id);
end $$;

create or replace function public.admin_prepare_member_reset(p_member_id text) returns jsonb
language sql security invoker set search_path = '' as $$ select core.admin_prepare_member_reset(p_member_id) $$;
create or replace function public.admin_finish_member_reset(p_member_id text) returns void
language sql security invoker set search_path = '' as $$ select core.admin_finish_member_reset(p_member_id) $$;

-- ---------------------------------------------------------------------------
-- profile photo
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', false, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

create policy avatars_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[2] = core.current_profile_id()
    and core.is_org_member((storage.foldername(name))[1])
  );

create policy avatars_select on storage.objects for select to authenticated
  using (
    bucket_id = 'avatars'
    and (
      (storage.foldername(name))[2] = core.current_profile_id()
      or core.has_permission((storage.foldername(name))[1], null, 'members.read')
    )
  );

-- p_path null removes the photo from the profile (the file is purged later, never deleted from the app).
create or replace function core.set_my_avatar(p_path text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  mem public.members;
  v_path text := nullif(btrim(coalesce(p_path, '')), '');
begin
  select m.* into mem from public.members m join public.profiles pr on pr.id = m.profile_id
  where pr.auth_user_id = (select auth.uid()) and pr.is_active and pr.deleted_at is null and m.deleted_at is null limit 1;
  if not found then
    raise exception 'no member account' using errcode = '42501';
  end if;
  if v_path is not null then
    if split_part(v_path, '/', 1) <> mem.org_id or split_part(v_path, '/', 2) <> core.current_profile_id()
       or v_path !~ '^[A-Za-z0-9]+/[A-Za-z0-9]+/[A-Za-z0-9_-]+\.(jpg|jpeg|png|webp)$' then
      raise exception 'the photo must be uploaded to your own folder' using errcode = '42501';
    end if;
    if not exists (select 1 from storage.objects o where o.bucket_id = 'avatars' and o.name = v_path) then
      raise exception 'the photo was not found; upload it again' using errcode = '22023';
    end if;
  end if;
  update public.persons set avatar_path = v_path where id = mem.person_id;
  perform core.write_audit(mem.org_id, 'profile.photo', 'public.persons', mem.person_id);
end $$;
create or replace function public.set_my_avatar(p_path text) returns void
language sql security invoker set search_path = '' as $$ select core.set_my_avatar(p_path) $$;

revoke all on function
  core.profile_complete(text), core.confirm_my_profile(), public.confirm_my_profile(),
  core.admin_prepare_member_reset(text), core.admin_finish_member_reset(text),
  public.admin_prepare_member_reset(text), public.admin_finish_member_reset(text),
  core.set_my_avatar(text), public.set_my_avatar(text),
  core.my_access_state(), public.my_access_state(),
  core.update_my_profile(text, text, text, text, text, text, text, text, text, text, text, text, text),
  public.update_my_profile(text, text, text, text, text, text, text, text, text, text, text, text, text)
  from public, anon, authenticated;
grant execute on function core.profile_complete(text) to service_role;
grant execute on function
  core.confirm_my_profile(), public.confirm_my_profile(),
  core.admin_prepare_member_reset(text), core.admin_finish_member_reset(text),
  public.admin_prepare_member_reset(text), public.admin_finish_member_reset(text),
  core.set_my_avatar(text), public.set_my_avatar(text),
  core.my_access_state(), public.my_access_state(),
  core.update_my_profile(text, text, text, text, text, text, text, text, text, text, text, text, text),
  public.update_my_profile(text, text, text, text, text, text, text, text, text, text, text, text, text)
  to authenticated, service_role;
