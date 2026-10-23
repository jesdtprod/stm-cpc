-- 1110_import_reassign
-- The club decided that spreadsheet rows sharing a member ID are not held back: the first row keeps the ID and
-- every other row gets a new one from the club's yearly sequence. These functions allocate the new number
-- (once per person, so a re-run finds the same member again) and record which old ID each new one replaced.

alter table public.member_import_issues drop constraint member_import_issues_code_chk;
alter table public.member_import_issues add constraint member_import_issues_code_chk check (issue_code in
  ('duplicate_member_no', 'invalid_member_no', 'member_no_normalized', 'invalid_birth_date',
   'duplicate_rfid_cleared', 'invalid_email', 'missing_name', 'member_no_reassigned'));

-- Returns {"member_no": ..., "existing": bool}. When this person (same claimed ID, name and birth date) was
-- already given a new number by an earlier run, that member is returned and nothing is allocated.
create or replace function core.import_allocate_member_no(p_batch_id text, p_claimed_no text, p_display_name text, p_dob date)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  org text;
  yr text;
  found_no text;
  n bigint;
  candidate text;
begin
  select org_id into org from public.import_batches where id = p_batch_id;
  if org is null then
    raise exception 'unknown import batch' using errcode = '22023';
  end if;
  select m.member_no into found_no
  from public.member_import_issues i
  join public.members m on m.id = i.member_id and m.deleted_at is null
  join public.persons p on p.id = m.person_id
  where i.org_id = org and i.issue_code = 'member_no_reassigned' and i.member_no_claimed = p_claimed_no
    and i.deleted_at is null and p.display_name = p_display_name and p.date_of_birth is not distinct from p_dob
  limit 1;
  if found_no is not null then
    return jsonb_build_object('member_no', found_no, 'existing', true);
  end if;
  yr := substr(p_claimed_no, 5, 4);
  loop
    n := core.next_number(org, null, 'member-' || yr);
    candidate := format('CPC-%s-%s', yr, lpad(n::text, 5, '0'));
    exit when not exists (select 1 from public.members m where m.org_id = org and m.member_no = candidate and m.deleted_at is null);
  end loop;
  return jsonb_build_object('member_no', candidate, 'existing', false);
end $$;

-- import_member gains p_claimed_no: the ID the row had in the spreadsheet when a new one was assigned.
drop function public.import_member(text, integer, text, text, date, text, text, text, uuid, timestamptz);
drop function core.import_member(text, integer, text, text, date, text, text, text, uuid, timestamptz);

create or replace function core.import_member(
  p_batch_id text, p_source_row integer, p_member_no text, p_display_name text, p_dob date,
  p_mobile text, p_email text, p_rfid text, p_auth_user_id uuid, p_password_expires_at timestamptz,
  p_claimed_no text default null
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
  if p_claimed_no is not null then
    insert into public.member_import_issues (org_id, batch_id, member_id, source_row, member_no_claimed, issue_code)
    values (org, p_batch_id, mem, p_source_row, p_claimed_no, 'member_no_reassigned')
    on conflict (batch_id, source_row, issue_code) where deleted_at is null do nothing;
  end if;
  return jsonb_build_object('outcome', 'created', 'member_id', mem, 'rfid_cleared', cleared);
end $$;

create or replace function public.import_member(
  p_batch_id text, p_source_row integer, p_member_no text, p_display_name text, p_dob date,
  p_mobile text, p_email text, p_rfid text, p_auth_user_id uuid, p_password_expires_at timestamptz,
  p_claimed_no text default null
) returns jsonb
language sql security invoker set search_path = '' as $$
  select core.import_member(p_batch_id, p_source_row, p_member_no, p_display_name, p_dob, p_mobile, p_email, p_rfid, p_auth_user_id, p_password_expires_at, p_claimed_no)
$$;
create or replace function public.import_allocate_member_no(p_batch_id text, p_claimed_no text, p_display_name text, p_dob date) returns jsonb
language sql security invoker set search_path = '' as $$ select core.import_allocate_member_no(p_batch_id, p_claimed_no, p_display_name, p_dob) $$;

revoke all on function
  core.import_member(text, integer, text, text, date, text, text, text, uuid, timestamptz, text),
  public.import_member(text, integer, text, text, date, text, text, text, uuid, timestamptz, text),
  core.import_allocate_member_no(text, text, text, date), public.import_allocate_member_no(text, text, text, date)
  from public, anon, authenticated;
grant execute on function
  core.import_member(text, integer, text, text, date, text, text, text, uuid, timestamptz, text),
  public.import_member(text, integer, text, text, date, text, text, text, uuid, timestamptz, text),
  core.import_allocate_member_no(text, text, text, date), public.import_allocate_member_no(text, text, text, date)
  to service_role;
