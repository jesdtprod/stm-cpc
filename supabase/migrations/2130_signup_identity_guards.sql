-- Registration rejects duplicate mobile numbers and identities already imported by the club.
-- Existing shared mobile numbers are preserved until changed, like the email rule in 1440.
create or replace function core.member_mobile_key(raw text) returns text
language sql immutable set search_path = '' as $$
  select case
    when d ~ '^639[0-9]{9}$' then '0' || substr(d, 3)
    when d ~ '^9[0-9]{9}$' then '0' || d
    else nullif(d, '') end
  from (select regexp_replace(coalesce(raw, ''), '[^0-9]', '', 'g') d) s
$$;

-- Word arrays ignore case, punctuation, spacing and name order, retaining accented letters.
create or replace function core.member_name_words(raw text) returns text[]
language sql immutable set search_path = '' as $$
  select array_remove(string_to_array(btrim(regexp_replace(lower(coalesce(raw, '')), '[^[:alnum:]]+', ' ', 'g')), ' '), '')
$$;

create or replace function core.signup_identity_conflict(
  p_mobile text, p_first_name text, p_last_name text, p_display_name text
) returns text
language plpgsql stable security definer set search_path = '' as $$
declare org text;
begin
  select id into org from public.orgs where code = 'cpc' and deleted_at is null;
  if exists (
    select 1 from public.persons p
    where p.org_id = org and p.kind = 'member' and p.deleted_at is null
      and core.member_mobile_key(p.mobile) = core.member_mobile_key(p_mobile)
  ) then return 'mobile_taken'; end if;
  if exists (
    select 1 from public.members m join public.persons p on p.id = m.person_id
    where m.org_id = org and m.deleted_at is null and p.deleted_at is null
      and (m.import_batch_id is not null or m.status in ('imported', 'invited'))
      and (
        (cardinality(core.member_name_words(p_display_name)) > 0
          and core.member_name_words(p.display_name) @> core.member_name_words(p_display_name)
          and core.member_name_words(p.display_name) <@ core.member_name_words(p_display_name))
        or (cardinality(core.member_name_words(p_first_name)) > 0
          and cardinality(core.member_name_words(p_last_name)) > 0
          and (core.member_name_words(p.display_name) @> core.member_name_words(p_first_name || ' ' || p_last_name)
            or (core.member_name_words(p.first_name) = core.member_name_words(p_first_name)
              and core.member_name_words(p.last_name) = core.member_name_words(p_last_name))))
      )
  ) then return 'imported_member'; end if;
  return null;
end $$;

create or replace function public.signup_identity_conflict(
  p_mobile text, p_first_name text, p_last_name text, p_display_name text
) returns text language sql stable security invoker set search_path = '' as $$
  select core.signup_identity_conflict(p_mobile, p_first_name, p_last_name, p_display_name)
$$;

create or replace function core.tg_persons_mobile_unique() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.kind = 'member' and new.deleted_at is null then
    -- Serialize identity writes in this club, including imports and profile edits.
    perform pg_advisory_xact_lock(hashtextextended('member-identity:' || new.org_id, 0));
    if (tg_op = 'INSERT' or new.mobile is distinct from old.mobile
      or new.kind is distinct from old.kind or new.org_id is distinct from old.org_id or old.deleted_at is not null)
      and exists (
        select 1 from public.persons p
        where p.org_id = new.org_id and p.kind = 'member' and p.deleted_at is null and p.id <> new.id
          and core.member_mobile_key(p.mobile) = core.member_mobile_key(new.mobile)
      ) then
      raise exception 'mobile_taken' using errcode = '23505';
    end if;
  end if;
  return new;
end $$;
create trigger a4_persons_mobile_unique before insert or update of mobile, kind, org_id, deleted_at on public.persons
  for each row execute function core.tg_persons_mobile_unique();

revoke all on function core.member_mobile_key(text), core.member_name_words(text),
  core.signup_identity_conflict(text,text,text,text), public.signup_identity_conflict(text,text,text,text),
  core.tg_persons_mobile_unique() from public, anon, authenticated;
grant execute on function core.signup_identity_conflict(text,text,text,text),
  public.signup_identity_conflict(text,text,text,text) to service_role;

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
  conflict text;
begin
  select id into org from public.orgs where code = 'cpc' and deleted_at is null;
  perform pg_advisory_xact_lock(hashtextextended('member-identity:' || org, 0));
  conflict := core.signup_identity_conflict(p_mobile, p_first_name, p_last_name, p_display_name);
  if conflict is not null then
    raise exception '%', conflict using errcode = '23505';
  end if;
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

  -- Remaining name/birth-date similarities among non-imported members are flagged for review.
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
  -- Minors need a guardian and a waiver before approval (decision D7).
  if p_dob > ((now() at time zone 'Asia/Manila')::date - interval '18 years')::date then
    insert into public.member_review_flags (org_id, member_id, kind) values (org, mem, 'minor') on conflict do nothing;
    flags := array_append(flags, 'minor'::text);
  end if;

  perform core.write_audit(org, 'signup.created', 'public.members', mem);
  return jsonb_build_object('member_id', mem, 'flags', to_jsonb(flags));
end $$;


