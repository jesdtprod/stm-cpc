-- 1190_import_enrich
-- Fills in details for members who are already imported (name parts, gender, emergency contact) from the club's
-- spreadsheet, WITHOUT overwriting anything: only empty (null) fields are filled, so whatever a member or an admin
-- has already entered stays. Service-only, like the rest of the import.

-- The member a reassigned row became (found by the ID it claimed, its name and birth date), or null.
create or replace function core.import_find_reassigned(p_claimed_no text, p_display_name text, p_dob date) returns text
language sql stable security definer set search_path = '' as $$
  select m.member_no
  from public.member_import_issues i
  join public.members m on m.id = i.member_id and m.deleted_at is null
  join public.persons p on p.id = m.person_id
  where i.issue_code = 'member_no_reassigned' and i.member_no_claimed = p_claimed_no and i.deleted_at is null
    and p.display_name = p_display_name and p.date_of_birth is not distinct from p_dob
  limit 1
$$;

-- Fills the empty fields of the person behind a member number. Returns true when anything changed.
create or replace function core.import_enrich_person(
  p_member_no text, p_first_name text, p_middle_name text, p_last_name text, p_suffix text, p_gender text,
  p_emergency_name text, p_emergency_relationship text, p_emergency_phone text
) returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  per public.persons;
  changed integer;
begin
  select p.* into per from public.members m join public.persons p on p.id = m.person_id
  where m.member_no = p_member_no and m.deleted_at is null;
  if not found then
    return false;
  end if;
  -- The emergency contact is filled as a pair, and only when none is stored yet.
  update public.persons set
    first_name = coalesce(first_name, p_first_name),
    middle_name = coalesce(middle_name, p_middle_name),
    last_name = coalesce(last_name, p_last_name),
    suffix = coalesce(suffix, p_suffix),
    gender = coalesce(gender, p_gender),
    emergency_name = case when emergency_name is null and emergency_phone is null and p_emergency_name is not null and p_emergency_phone is not null then p_emergency_name else emergency_name end,
    emergency_phone = case when emergency_name is null and emergency_phone is null and p_emergency_name is not null and p_emergency_phone is not null then p_emergency_phone else emergency_phone end,
    emergency_relationship = case when emergency_name is null and emergency_phone is null and p_emergency_name is not null and p_emergency_phone is not null then coalesce(emergency_relationship, p_emergency_relationship) else emergency_relationship end
  where id = per.id
    and (first_name is distinct from coalesce(first_name, p_first_name)
      or middle_name is distinct from coalesce(middle_name, p_middle_name)
      or last_name is distinct from coalesce(last_name, p_last_name)
      or suffix is distinct from coalesce(suffix, p_suffix)
      or gender is distinct from coalesce(gender, p_gender)
      or (emergency_name is null and emergency_phone is null and p_emergency_name is not null and p_emergency_phone is not null));
  get diagnostics changed = row_count;
  return changed > 0;
end $$;

create or replace function public.import_find_reassigned(p_claimed_no text, p_display_name text, p_dob date) returns text
language sql stable security invoker set search_path = '' as $$ select core.import_find_reassigned(p_claimed_no, p_display_name, p_dob) $$;
create or replace function public.import_enrich_person(
  p_member_no text, p_first_name text, p_middle_name text, p_last_name text, p_suffix text, p_gender text,
  p_emergency_name text, p_emergency_relationship text, p_emergency_phone text
) returns boolean
language sql security invoker set search_path = '' as $$
  select core.import_enrich_person(p_member_no, p_first_name, p_middle_name, p_last_name, p_suffix, p_gender, p_emergency_name, p_emergency_relationship, p_emergency_phone)
$$;

revoke all on function
  core.import_find_reassigned(text, text, date), public.import_find_reassigned(text, text, date),
  core.import_enrich_person(text, text, text, text, text, text, text, text, text),
  public.import_enrich_person(text, text, text, text, text, text, text, text, text)
  from public, anon, authenticated;
grant execute on function
  core.import_find_reassigned(text, text, date), public.import_find_reassigned(text, text, date),
  core.import_enrich_person(text, text, text, text, text, text, text, text, text),
  public.import_enrich_person(text, text, text, text, text, text, text, text, text)
  to service_role;
