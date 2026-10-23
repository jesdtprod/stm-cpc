-- 1080_member_import (PLAN 3.2)
-- Database side of the member import and of creating the first admin account. The Auth user itself is
-- created by the member-import Edge Function (Admin API); these functions create the rows around it in one
-- transaction. Service-only: clients and anon cannot call any of them. No password is ever passed to or
-- stored by the database.

-- One more reason a spreadsheet row can be held back.
alter table public.member_import_issues drop constraint member_import_issues_code_chk;
alter table public.member_import_issues add constraint member_import_issues_code_chk check (issue_code in
  ('duplicate_member_no', 'invalid_member_no', 'member_no_normalized', 'invalid_birth_date',
   'duplicate_rfid_cleared', 'invalid_email', 'missing_name'));

create or replace function core.import_begin(p_file_sha256 text, p_row_count integer) returns text
language plpgsql security definer set search_path = '' as $$
declare
  org text;
  bid text;
begin
  select id into org from public.orgs where code = 'cpc' and deleted_at is null;
  insert into public.import_batches (org_id, file_sha256, row_count, status, started_by)
  values (org, p_file_sha256, p_row_count, 'running', 'import')
  returning id into bid;
  return bid;
end $$;

create or replace function core.import_finish(
  p_batch_id text, p_created integer, p_skipped integer, p_held_back integer, p_failed integer
) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.import_batches
  set created_count = p_created, skipped_count = p_skipped, held_back_count = p_held_back,
      failed_count = p_failed, status = 'completed'
  where id = p_batch_id;
end $$;

create or replace function core.import_issue(
  p_batch_id text, p_source_row integer, p_member_no text, p_code text, p_member_id text default null
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  org text;
begin
  select org_id into org from public.import_batches where id = p_batch_id;
  if org is null then
    raise exception 'unknown import batch' using errcode = '22023';
  end if;
  insert into public.member_import_issues (org_id, batch_id, member_id, source_row, member_no_claimed, issue_code)
  values (org, p_batch_id, p_member_id, p_source_row, p_member_no, p_code)
  on conflict (batch_id, source_row, issue_code) where deleted_at is null do nothing;
end $$;

-- Which of these member numbers already exist (active rows)?
create or replace function core.import_existing(p_member_nos text[]) returns setof text
language sql stable security definer set search_path = '' as $$
  select m.member_no from public.members m where m.member_no = any (p_member_nos) and m.deleted_at is null
$$;

-- Creates the person, the member and (when an Auth user was made) the profile and the pending role.
-- Returns {"outcome": "created" | "existing", "member_id": ..., "rfid_cleared": bool}.
create or replace function core.import_member(
  p_batch_id text, p_source_row integer, p_member_no text, p_display_name text, p_dob date,
  p_mobile text, p_email text, p_rfid text, p_auth_user_id uuid, p_password_expires_at timestamptz
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  org text;
  per text;
  prof text;
  mem text;
  rid text;
  rfid text := p_rfid;
  cleared boolean := false;
begin
  select org_id into org from public.import_batches where id = p_batch_id;
  if org is null then
    raise exception 'unknown import batch' using errcode = '22023';
  end if;
  select id into mem from public.members where member_no = p_member_no and org_id = org and deleted_at is null;
  if mem is not null then
    return jsonb_build_object('outcome', 'existing', 'member_id', mem, 'rfid_cleared', false);
  end if;

  if rfid is not null and exists (select 1 from public.members m where m.org_id = org and m.rfid_code = rfid and m.deleted_at is null) then
    rfid := null;
    cleared := true;
  end if;

  insert into public.persons (org_id, kind, display_name, email, mobile, date_of_birth)
  values (org, 'member', p_display_name, p_email, p_mobile, p_dob)
  returning id into per;

  if p_auth_user_id is not null then
    insert into public.profiles (org_id, auth_user_id, person_id) values (org, p_auth_user_id, per) returning id into prof;
    select r.id into rid from public.roles r where r.org_id = org and r.code = 'pending_member' and r.deleted_at is null;
    insert into public.org_members (org_id, profile_id, role_id) values (org, prof, rid);
  end if;

  insert into public.members (org_id, person_id, profile_id, member_no, status, rfid_code, import_batch_id, import_row)
  values (org, per, prof, p_member_no, 'imported', rfid, p_batch_id, p_source_row)
  returning id into mem;

  insert into public.member_access (org_id, member_id, must_change_password, temp_password_expires_at)
  values (org, mem, true, case when p_auth_user_id is not null then p_password_expires_at end);

  if cleared then
    perform core.import_issue(p_batch_id, p_source_row, p_member_no, 'duplicate_rfid_cleared', mem);
  end if;
  return jsonb_build_object('outcome', 'created', 'member_id', mem, 'rfid_cleared', cleared);
end $$;

-- The first administrator: an active member with the admin role. The Auth user is made by the Edge Function.
create or replace function core.create_admin_member(p_member_no text, p_display_name text, p_auth_user_id uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare
  org text;
  per text;
  prof text;
  mem text;
  rid text;
begin
  select id into org from public.orgs where code = 'cpc' and deleted_at is null;
  select m.id into mem from public.members m where m.member_no = p_member_no and m.org_id = org and m.deleted_at is null;
  if mem is not null then
    raise exception 'that member number already exists' using errcode = '23505';
  end if;
  insert into public.persons (org_id, kind, display_name) values (org, 'member', p_display_name) returning id into per;
  insert into public.profiles (org_id, auth_user_id, person_id) values (org, p_auth_user_id, per) returning id into prof;
  select r.id into rid from public.roles r where r.org_id = org and r.code = 'admin' and r.deleted_at is null;
  insert into public.org_members (org_id, profile_id, role_id) values (org, prof, rid);
  insert into public.members (org_id, person_id, profile_id, member_no, status, joined_on)
  values (org, per, prof, p_member_no, 'pending_approval', (now() at time zone 'Asia/Manila')::date)
  returning id into mem;
  update public.members set status = 'active', status_reason = 'first administrator' where id = mem;
  insert into public.member_access (org_id, member_id, must_change_password) values (org, mem, true);
  perform core.write_audit(org, 'admin.created', 'public.members', mem);
  return mem;
end $$;

-- Is this Auth user allowed to run the import? (members.import in the club)
create or replace function core.import_authorized(p_auth_user_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.profiles p
    join public.org_members om on om.profile_id = p.id and om.is_active and om.deleted_at is null
    join public.role_permissions rp on rp.role_id = om.role_id and rp.deleted_at is null
    join public.permissions pe on pe.id = rp.permission_id and pe.deleted_at is null
    where p.auth_user_id = p_auth_user_id and p.is_active and p.deleted_at is null and pe.code = 'members.import'
  )
$$;

-- Service-only wrappers in public so the Edge Function can reach them through the API.
create or replace function public.import_begin(p_file_sha256 text, p_row_count integer) returns text
language sql security invoker set search_path = '' as $$ select core.import_begin(p_file_sha256, p_row_count) $$;
create or replace function public.import_finish(p_batch_id text, p_created integer, p_skipped integer, p_held_back integer, p_failed integer) returns void
language sql security invoker set search_path = '' as $$ select core.import_finish(p_batch_id, p_created, p_skipped, p_held_back, p_failed) $$;
create or replace function public.import_issue(p_batch_id text, p_source_row integer, p_member_no text, p_code text, p_member_id text default null) returns void
language sql security invoker set search_path = '' as $$ select core.import_issue(p_batch_id, p_source_row, p_member_no, p_code, p_member_id) $$;
create or replace function public.import_existing(p_member_nos text[]) returns setof text
language sql stable security invoker set search_path = '' as $$ select * from core.import_existing(p_member_nos) $$;
create or replace function public.import_member(
  p_batch_id text, p_source_row integer, p_member_no text, p_display_name text, p_dob date,
  p_mobile text, p_email text, p_rfid text, p_auth_user_id uuid, p_password_expires_at timestamptz
) returns jsonb
language sql security invoker set search_path = '' as $$
  select core.import_member(p_batch_id, p_source_row, p_member_no, p_display_name, p_dob, p_mobile, p_email, p_rfid, p_auth_user_id, p_password_expires_at)
$$;
create or replace function public.create_admin_member(p_member_no text, p_display_name text, p_auth_user_id uuid) returns text
language sql security invoker set search_path = '' as $$ select core.create_admin_member(p_member_no, p_display_name, p_auth_user_id) $$;
create or replace function public.import_authorized(p_auth_user_id uuid) returns boolean
language sql stable security invoker set search_path = '' as $$ select core.import_authorized(p_auth_user_id) $$;

revoke all on function
  core.import_begin(text, integer), core.import_finish(text, integer, integer, integer, integer),
  core.import_issue(text, integer, text, text, text), core.import_existing(text[]),
  core.import_member(text, integer, text, text, date, text, text, text, uuid, timestamptz),
  core.create_admin_member(text, text, uuid), core.import_authorized(uuid),
  public.import_begin(text, integer), public.import_finish(text, integer, integer, integer, integer),
  public.import_issue(text, integer, text, text, text), public.import_existing(text[]),
  public.import_member(text, integer, text, text, date, text, text, text, uuid, timestamptz),
  public.create_admin_member(text, text, uuid), public.import_authorized(uuid)
  from public, anon, authenticated;
grant execute on function
  core.import_begin(text, integer), core.import_finish(text, integer, integer, integer, integer),
  core.import_issue(text, integer, text, text, text), core.import_existing(text[]),
  core.import_member(text, integer, text, text, date, text, text, text, uuid, timestamptz),
  core.create_admin_member(text, text, uuid), core.import_authorized(uuid),
  public.import_begin(text, integer), public.import_finish(text, integer, integer, integer, integer),
  public.import_issue(text, integer, text, text, text), public.import_existing(text[]),
  public.import_member(text, integer, text, text, date, text, text, text, uuid, timestamptz),
  public.create_admin_member(text, text, uuid), public.import_authorized(uuid)
  to service_role;
