-- 1130_import_id_conflicts
-- Two safety nets for the import when spreadsheet rows share a member ID:
--   * the allocator takes a list of IDs it must not hand out (every ID the file itself uses), so a new number
--     never lands on an ID that a later row in the same file claims;
--   * the import can ask who holds an ID, so a row whose ID is held by a DIFFERENT person is given a new number
--     instead of being skipped as "already there".

drop function public.import_allocate_member_no(text, text, text, date);
drop function core.import_allocate_member_no(text, text, text, date);

create or replace function core.import_allocate_member_no(
  p_batch_id text, p_claimed_no text, p_display_name text, p_dob date, p_reserved text[] default '{}'
) returns jsonb
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
    exit when not candidate = any (p_reserved)
      and not exists (select 1 from public.members m where m.org_id = org and m.member_no = candidate and m.deleted_at is null);
  end loop;
  return jsonb_build_object('member_no', candidate, 'existing', false);
end $$;

create or replace function core.import_existing_people(p_member_nos text[])
returns table (member_no text, display_name text, date_of_birth date)
language sql stable security definer set search_path = '' as $$
  select m.member_no, p.display_name, p.date_of_birth
  from public.members m join public.persons p on p.id = m.person_id
  where m.member_no = any (p_member_nos) and m.deleted_at is null
$$;

create or replace function public.import_allocate_member_no(
  p_batch_id text, p_claimed_no text, p_display_name text, p_dob date, p_reserved text[] default '{}'
) returns jsonb
language sql security invoker set search_path = '' as $$
  select core.import_allocate_member_no(p_batch_id, p_claimed_no, p_display_name, p_dob, p_reserved)
$$;
create or replace function public.import_existing_people(p_member_nos text[])
returns table (member_no text, display_name text, date_of_birth date)
language sql stable security invoker set search_path = '' as $$ select * from core.import_existing_people(p_member_nos) $$;

revoke all on function
  core.import_allocate_member_no(text, text, text, date, text[]), public.import_allocate_member_no(text, text, text, date, text[]),
  core.import_existing_people(text[]), public.import_existing_people(text[])
  from public, anon, authenticated;
grant execute on function
  core.import_allocate_member_no(text, text, text, date, text[]), public.import_allocate_member_no(text, text, text, date, text[]),
  core.import_existing_people(text[]), public.import_existing_people(text[])
  to service_role;
