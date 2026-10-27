-- 1630_profile_dupr_id: optional, self-reported DUPR ID (no account verification or rating sync).
alter table public.persons add column dupr_id text
  constraint persons_dupr_id_chk check (dupr_id is null or dupr_id ~ '^[A-Z0-9]{1,32}$');
comment on column public.persons.dupr_id is 'Self-reported DUPR ID; not proof of account ownership or an official rating.';
create unique index persons_dupr_id_active_uq on public.persons (org_id, dupr_id)
  where deleted_at is null and dupr_id is not null;
-- Existing persons RLS remains in force. Only the profile RPC can write the new column.

drop function public.update_my_profile(text, text, text, text, text, text, text, text, text, text, text, text, text, date);
drop function core.update_my_profile(text, text, text, text, text, text, text, text, text, text, text, text, text, date);

create or replace function core.update_my_profile(
  p_display_name text, p_mobile text, p_email text, p_street_line text, p_barangay_code text,
  p_first_name text default null, p_middle_name text default null, p_last_name text default null,
  p_suffix text default null, p_gender text default null,
  p_emergency_name text default null, p_emergency_relationship text default null, p_emergency_phone text default null,
  p_date_of_birth date default null, p_dupr_id text default null
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
  v_dupr_id text;
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
  v_dupr_id := case when p_dupr_id is null then per.dupr_id else nullif(upper(btrim(p_dupr_id)), '') end;
  if v_dupr_id is not null and v_dupr_id !~ '^[A-Z0-9]{1,32}$' then
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
    date_of_birth = v_dob, dupr_id = v_dupr_id,
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
  p_date_of_birth date default null, p_dupr_id text default null
) returns void
language sql security invoker set search_path = '' as $$
  select core.update_my_profile(p_display_name, p_mobile, p_email, p_street_line, p_barangay_code, p_first_name, p_middle_name,
    p_last_name, p_suffix, p_gender, p_emergency_name, p_emergency_relationship, p_emergency_phone, p_date_of_birth, p_dupr_id)
$$;

revoke all on function
  core.update_my_profile(text, text, text, text, text, text, text, text, text, text, text, text, text, date, text),
  public.update_my_profile(text, text, text, text, text, text, text, text, text, text, text, text, text, date, text)
  from public, anon, authenticated;
grant execute on function
  core.update_my_profile(text, text, text, text, text, text, text, text, text, text, text, text, text, date, text),
  public.update_my_profile(text, text, text, text, text, text, text, text, text, text, text, text, text, date, text)
  to authenticated, service_role;


drop function public.my_access_state();
drop function core.my_access_state();

create or replace function core.my_access_state()
returns table (
  member_id text, member_no text, status text, must_change_password boolean, profile_complete boolean, display_name text,
  mobile text, email text, street_line text, barangay_code text, city_muni_code text, province_code text, region_code text,
  first_name text, middle_name text, last_name text, suffix text, gender text, date_of_birth date,
  emergency_name text, emergency_relationship text, emergency_phone text, must_confirm_profile boolean, avatar_path text, dupr_id text
)
language sql stable security definer set search_path = '' as $$
  select m.id, m.member_no, m.status, coalesce(a.must_change_password, false), core.profile_complete(m.person_id), p.display_name,
         p.mobile, p.email, p.street_line, p.barangay_code, p.city_muni_code, p.province_code, p.region_code,
         p.first_name, p.middle_name, p.last_name, p.suffix, p.gender, p.date_of_birth,
         p.emergency_name, p.emergency_relationship, p.emergency_phone, coalesce(a.must_confirm_profile, false), p.avatar_path, p.dupr_id
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
  emergency_name text, emergency_relationship text, emergency_phone text, must_confirm_profile boolean, avatar_path text, dupr_id text
)
language sql stable security invoker set search_path = '' as $$ select * from core.my_access_state() $$;


revoke all on function core.my_access_state(), public.my_access_state() from public, anon, authenticated;
grant execute on function core.my_access_state(), public.my_access_state() to authenticated, service_role;
