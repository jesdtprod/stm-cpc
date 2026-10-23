-- 1120_fix_update_my_profile (PLAN 3.4; fixes 1100)
-- 1100 named local variables like the persons columns (mobile, email) and tried to qualify them with the
-- function name, which PostgreSQL reads as a table. Renamed to v_*; behavior is as described in 1100.

create or replace function core.update_my_profile(
  p_display_name text, p_mobile text, p_email text, p_street_line text, p_barangay_code text
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  mem public.members;
  v_name text := nullif(regexp_replace(btrim(coalesce(p_display_name, '')), '\s+', ' ', 'g'), '');
  v_mobile text := nullif(btrim(coalesce(p_mobile, '')), '');
  v_digits text;
  v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  v_street text := nullif(btrim(coalesce(p_street_line, '')), '');
begin
  select m.* into mem
  from public.members m join public.profiles pr on pr.id = m.profile_id
  where pr.auth_user_id = (select auth.uid()) and pr.is_active and pr.deleted_at is null and m.deleted_at is null;
  if not found or mem.status not in ('invited', 'pending_approval', 'active') then
    raise exception 'profile cannot be edited in this state' using errcode = '42501';
  end if;
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
  if v_email is not null and (length(v_email) > 254 or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') then
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

  update public.persons set
    display_name = coalesce(v_name, display_name),
    mobile = v_mobile,
    email = v_email,
    street_line = v_street,
    barangay_code = p_barangay_code,
    city_muni_code = null, province_code = null, region_code = null
  where id = mem.person_id;

  perform core.advance_member_if_ready(mem.id);
end $$;

