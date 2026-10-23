-- 1160_member_signup (PLAN 3.3)
-- Database side of the public sign-up for NEW members. The member-signup Edge Function allocates the next member
-- number, creates the Auth account with the applicant's own password, then calls signup_create to make the person,
-- profile, member (status pending_approval, no permissions), consents and any review flags in one transaction.
-- Everything here is service-only; the public never calls the database directly.

-- ---------------------------------------------------------------------------
-- member_review_flags: things an admin should look at before approving. class: master.
-- Holds codes only, no personal data.
-- ---------------------------------------------------------------------------
create table public.member_review_flags (
  id                text collate "C" primary key default core.ulid(),
  org_id            text not null references public.orgs (id) on delete restrict,
  unit_id           text collate "C" references public.org_units (id) on delete restrict,
  member_id         text collate "C" not null references public.members (id) on delete restrict,
  related_member_id text collate "C" references public.members (id) on delete restrict,
  kind              text not null constraint member_review_flags_kind_chk check (kind in
                      ('possible_duplicate_name_dob', 'possible_duplicate_mobile', 'minor')),
  resolved_at       timestamptz,
  resolved_by       text,
  created_at        timestamptz not null default now(),
  created_by        text,
  updated_at        timestamptz not null default now(),
  updated_by        text,
  version           integer not null default 1,
  deleted_at        timestamptz,
  deleted_by        text,
  delete_reason     text,
  meta              jsonb not null default '{}'::jsonb,
  constraint member_review_flags_resolved_chk check ((resolved_at is null) = (resolved_by is null)),
  constraint member_review_flags_not_self_chk check (related_member_id is distinct from member_id)
);
comment on table public.member_review_flags is 'class: master. permissions: members.approve (read). Written by member-signup (service). Codes only.';
create index member_review_flags_org_idx on public.member_review_flags (org_id);
create index member_review_flags_unit_idx on public.member_review_flags (unit_id);
create index member_review_flags_member_idx on public.member_review_flags (member_id);
create index member_review_flags_related_idx on public.member_review_flags (related_member_id);
create unique index member_review_flags_uq on public.member_review_flags (member_id, kind, coalesce(related_member_id, '')) where deleted_at is null;
create index member_review_flags_open_idx on public.member_review_flags (org_id, kind) where resolved_at is null and deleted_at is null;

select core.attach_standard('public.member_review_flags', 'master');
alter table public.member_review_flags enable row level security;
create policy member_review_flags_select on public.member_review_flags for select to authenticated
  using (core.has_permission(org_id, null, 'members.approve'));
select core.grant_client_dml('public.member_review_flags', false, false);
grant select, insert, update on public.member_review_flags to service_role;

-- Consent versions the sign-up form records (the club edits these when it changes its waiver or privacy notice).
insert into public.settings (org_id, key, value)
select o.id, v.key, v.value
from public.orgs o
cross join (values ('consents.waiver_version', '"2026-1"'::jsonb), ('consents.privacy_version', '"2026-1"')) as v(key, value)
where o.code = 'cpc' and o.deleted_at is null
on conflict (org_id, (coalesce(unit_id, '')), key) where deleted_at is null do nothing;

-- Is public sign-up switched on? (setting members.signup_enabled, default on)
create or replace function core.signup_enabled() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((
    select (s.value = 'true'::jsonb)
    from public.settings s join public.orgs o on o.id = s.org_id and o.code = 'cpc'
    where s.key = 'members.signup_enabled' and s.deleted_at is null and s.unit_id is null
  ), true)
$$;

-- The next free member number for the current year (Asia/Manila). Numbers already used by anyone are skipped,
-- so imported members keep their IDs and a new member can never collide with one.
create or replace function core.signup_allocate_member_no() returns text
language plpgsql security definer set search_path = '' as $$
declare
  org text;
  yr text := to_char(now() at time zone 'Asia/Manila', 'YYYY');
  n bigint;
  candidate text;
begin
  select id into org from public.orgs where code = 'cpc' and deleted_at is null;
  loop
    n := core.next_number(org, null, 'member-' || yr);
    candidate := format('CPC-%s-%s', yr, lpad(n::text, 5, '0'));
    exit when not exists (select 1 from public.members m where m.org_id = org and m.member_no = candidate);
  end loop;
  return candidate;
end $$;

-- Creates the applicant's rows. The Auth user already exists. Returns {"member_id": ..., "flags": [...]}.
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
    flags := flags || 'possible_duplicate_name_dob';
  end loop;
  for other in
    select m.id from public.members m join public.persons p on p.id = m.person_id
    where m.org_id = org and m.id <> mem and m.deleted_at is null and p.mobile = p_mobile
    limit 3
  loop
    insert into public.member_review_flags (org_id, member_id, related_member_id, kind) values (org, mem, other, 'possible_duplicate_mobile')
    on conflict do nothing;
    flags := flags || 'possible_duplicate_mobile';
  end loop;
  -- Minors need a guardian and a waiver before approval (decision D7).
  if p_dob > ((now() at time zone 'Asia/Manila')::date - interval '18 years')::date then
    insert into public.member_review_flags (org_id, member_id, kind) values (org, mem, 'minor') on conflict do nothing;
    flags := flags || 'minor';
  end if;

  perform core.write_audit(org, 'signup.created', 'public.members', mem);
  return jsonb_build_object('member_id', mem, 'flags', to_jsonb(flags));
end $$;

create or replace function public.signup_enabled() returns boolean
language sql stable security invoker set search_path = '' as $$ select core.signup_enabled() $$;
create or replace function public.signup_allocate_member_no() returns text
language sql security invoker set search_path = '' as $$ select core.signup_allocate_member_no() $$;
create or replace function public.signup_create(
  p_member_no text, p_first_name text, p_middle_name text, p_last_name text, p_suffix text, p_display_name text,
  p_gender text, p_dob date, p_mobile text, p_email text, p_auth_user_id uuid
) returns jsonb
language sql security invoker set search_path = '' as $$
  select core.signup_create(p_member_no, p_first_name, p_middle_name, p_last_name, p_suffix, p_display_name, p_gender, p_dob, p_mobile, p_email, p_auth_user_id)
$$;

revoke all on function
  core.signup_enabled(), core.signup_allocate_member_no(),
  core.signup_create(text, text, text, text, text, text, text, date, text, text, uuid),
  public.signup_enabled(), public.signup_allocate_member_no(),
  public.signup_create(text, text, text, text, text, text, text, date, text, text, uuid)
  from public, anon, authenticated;
grant execute on function
  core.signup_enabled(), core.signup_allocate_member_no(),
  core.signup_create(text, text, text, text, text, text, text, date, text, text, uuid),
  public.signup_enabled(), public.signup_allocate_member_no(),
  public.signup_create(text, text, text, text, text, text, text, date, text, text, uuid)
  to service_role;
