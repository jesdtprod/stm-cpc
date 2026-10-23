-- 1170_fix_signup_create (PLAN 3.3; fixes 1160)
-- 'flags || 'text'' reads the literal as an array in PL/pgSQL (same as 1007). Use array_append with a typed value.

create or replace function core.signup_create(
  p_member_no text, p_first_name text, p_middle_name text, p_last_name text, p_suffix text, p_display_name text,
  p_gender text, p_dob date, p_mobile text, p_email text, p_auth_user_id uuid
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  org text;
  per text;
  prof text;
  mem text;
  rid text;
  flags text[] := '{}';
  other text;
  waiver text;
  privacy text;
begin
  select id into org from public.orgs where code = 'cpc' and deleted_at is null;
  if exists (select 1 from public.members m where m.org_id = org and m.member_no = p_member_no) then
    raise exception 'that member number is already in use' using errcode = '23505';
  end if;

  insert into public.persons (org_id, kind, first_name, middle_name, last_name, suffix, display_name, gender, date_of_birth, mobile, email)
  values (org, 'member', p_first_name, p_middle_name, p_last_name, p_suffix, p_display_name, p_gender, p_dob, p_mobile, p_email)
  returning id into per;
  insert into public.profiles (org_id, auth_user_id, person_id) values (org, p_auth_user_id, per) returning id into prof;
  select r.id into rid from public.roles r where r.org_id = org and r.code = 'pending_member' and r.deleted_at is null;
  insert into public.org_members (org_id, profile_id, role_id) values (org, prof, rid);
  insert into public.members (org_id, person_id, profile_id, member_no, status, status_reason, joined_on)
  values (org, per, prof, p_member_no, 'pending_approval', 'new sign-up', (now() at time zone 'Asia/Manila')::date)
  returning id into mem;
  insert into public.member_access (org_id, member_id, must_change_password) values (org, mem, false);

  select coalesce((select s.value #>> '{}' from public.settings s where s.org_id = org and s.key = 'consents.waiver_version' and s.deleted_at is null), '1') into waiver;
  select coalesce((select s.value #>> '{}' from public.settings s where s.org_id = org and s.key = 'consents.privacy_version' and s.deleted_at is null), '1') into privacy;
  insert into public.consents (org_id, person_id, kind, doc_version) values (org, per, 'waiver', waiver), (org, per, 'privacy', privacy);

  -- Possible duplicates of existing members: flagged for the admin, never silently merged or refused.
  for other in
    select m.id from public.members m join public.persons p on p.id = m.person_id
    where m.org_id = org and m.id <> mem and m.deleted_at is null
      and lower(p.display_name) = lower(p_display_name) and p.date_of_birth = p_dob
    limit 3
  loop
    insert into public.member_review_flags (org_id, member_id, related_member_id, kind) values (org, mem, other, 'possible_duplicate_name_dob')
    on conflict do nothing;
    flags := array_append(flags, 'possible_duplicate_name_dob'::text);
  end loop;
  for other in
    select m.id from public.members m join public.persons p on p.id = m.person_id
    where m.org_id = org and m.id <> mem and m.deleted_at is null and p.mobile = p_mobile
    limit 3
  loop
    insert into public.member_review_flags (org_id, member_id, related_member_id, kind) values (org, mem, other, 'possible_duplicate_mobile')
    on conflict do nothing;
    flags := array_append(flags, 'possible_duplicate_mobile'::text);
  end loop;
  -- Minors need a guardian and a waiver before approval (decision D7).
  if p_dob > ((now() at time zone 'Asia/Manila')::date - interval '18 years')::date then
    insert into public.member_review_flags (org_id, member_id, kind) values (org, mem, 'minor') on conflict do nothing;
    flags := array_append(flags, 'minor'::text);
  end if;

  perform core.write_audit(org, 'signup.created', 'public.members', mem);
  return jsonb_build_object('member_id', mem, 'flags', to_jsonb(flags));
end $$;

