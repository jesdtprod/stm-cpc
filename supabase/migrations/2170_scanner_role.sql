-- Scanner-only staff: a role that can do nothing except check members in (bookings.checkin), and the function that makes
-- such an account. Like create_admin_member, the Auth user is made by the member-import Edge Function (service role);
-- this function only writes the club records. The account must change its first password at the first sign-in.
insert into public.roles (org_id, code, name, description, is_system)
select o.id, 'scanner', 'Check-in scanner', 'Scans booking QR codes at the court. Can check members in and nothing else.', true
from public.orgs o
where o.code = 'cpc' and o.deleted_at is null
on conflict (org_id, code) where deleted_at is null do nothing;

insert into public.role_permissions (org_id, role_id, permission_id)
select r.org_id, r.id, pe.id
from public.roles r
join public.orgs o on o.id = r.org_id and o.code = 'cpc'
join public.permissions pe on pe.code = 'bookings.checkin' and pe.deleted_at is null
where r.code = 'scanner' and r.deleted_at is null
on conflict (role_id, permission_id) where deleted_at is null do nothing;

create or replace function core.create_scanner_member(p_member_no text, p_display_name text, p_auth_user_id uuid) returns text
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
  select r.id into rid from public.roles r where r.org_id = org and r.code = 'scanner' and r.deleted_at is null;
  if rid is null then
    raise exception 'the scanner role is missing' using errcode = '22023';
  end if;
  insert into public.persons (org_id, kind, display_name) values (org, 'member', p_display_name) returning id into per;
  insert into public.profiles (org_id, auth_user_id, person_id) values (org, p_auth_user_id, per) returning id into prof;
  insert into public.org_members (org_id, profile_id, role_id) values (org, prof, rid);
  insert into public.members (org_id, person_id, profile_id, member_no, status, joined_on)
  values (org, per, prof, p_member_no, 'pending_approval', (now() at time zone 'Asia/Manila')::date)
  returning id into mem;
  update public.members set status = 'active', status_reason = 'scanner account' where id = mem;
  insert into public.member_access (org_id, member_id, must_change_password) values (org, mem, true);
  perform core.write_audit(org, 'scanner.created', 'public.members', mem);
  return mem;
end $$;

create or replace function public.create_scanner_member(p_member_no text, p_display_name text, p_auth_user_id uuid) returns text
language sql security invoker set search_path = '' as $$ select core.create_scanner_member(p_member_no, p_display_name, p_auth_user_id) $$;

revoke all on function core.create_scanner_member(text, text, uuid), public.create_scanner_member(text, text, uuid)
  from public, anon, authenticated;
grant execute on function core.create_scanner_member(text, text, uuid), public.create_scanner_member(text, text, uuid)
  to service_role;

notify pgrst, 'reload schema';
