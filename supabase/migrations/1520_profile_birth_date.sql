-- 1520_profile_birth_date: allow members and administrators to set or update their date_of_birth in update_my_profile.

drop function public.update_my_profile(text, text, text, text, text, text, text, text, text, text, text, text, text);
drop function core.update_my_profile(text, text, text, text, text, text, text, text, text, text, text, text, text);

create or replace function core.update_my_profile(
  p_display_name text, p_mobile text, p_email text, p_street_line text, p_barangay_code text,
  p_first_name text default null, p_middle_name text default null, p_last_name text default null,
  p_suffix text default null, p_gender text default null,
  p_emergency_name text default null, p_emergency_relationship text default null, p_emergency_phone text default null,
  p_date_of_birth date default null
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
  v_dob date;
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
  v_dob := coalesce(p_date_of_birth, per.date_of_birth);

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
    date_of_birth = v_dob,
    mobile = v_mobile,
    email = v_email,
    street_line = v_street,
    barangay_code = p_barangay_code,
    city_muni_code = null, province_code = null, region_code = null,
    emergency_name = v_em_name, emergency_relationship = v_em_rel, emergency_phone = v_em_phone
  where id = mem.person_id;

  perform core.advance_member_if_ready(mem.id);
end $$;

create or replace function public.update_my_profile(
  p_display_name text, p_mobile text, p_email text, p_street_line text, p_barangay_code text,
  p_first_name text default null, p_middle_name text default null, p_last_name text default null,
  p_suffix text default null, p_gender text default null,
  p_emergency_name text default null, p_emergency_relationship text default null, p_emergency_phone text default null,
  p_date_of_birth date default null
) returns void
language sql security invoker set search_path = '' as $$
  select core.update_my_profile(p_display_name, p_mobile, p_email, p_street_line, p_barangay_code, p_first_name, p_middle_name,
    p_last_name, p_suffix, p_gender, p_emergency_name, p_emergency_relationship, p_emergency_phone, p_date_of_birth)
$$;

revoke all on function
  core.update_my_profile(text, text, text, text, text, text, text, text, text, text, text, text, text, date),
  public.update_my_profile(text, text, text, text, text, text, text, text, text, text, text, text, text, date)
  from public, anon, authenticated;
grant execute on function
  core.update_my_profile(text, text, text, text, text, text, text, text, text, text, text, text, text, date),
  public.update_my_profile(text, text, text, text, text, text, text, text, text, text, text, text, text, date)
  to authenticated, service_role;

