begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as m1, core.ulid() as m2, core.ulid() as m3, core.ulid() as batch, core.ulid() as issue,
  core.ulid() as k1, core.ulid() as k2, core.ulid() as k3, core.ulid() as k4, core.ulid() as k5, core.ulid() as k6,
  core.ulid() as court, core.ulid() as k7, core.ulid() as k8, core.ulid() as k9, core.ulid() as k10;
grant select on fx to public;

create function pg_temp.mk(p_org text, p_role text) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); rid text;
begin
  select id into rid from public.roles where org_id = p_org and code = p_role;
  insert into auth.users (id, email) values (u, p_role || '-' || u || '@example.test');
  insert into public.persons (id, org_id, display_name) values (per, p_org, 'Fake ' || p_role);
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, p_org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (p_org, pid, rid);
  return u;
end $$;
create temp table us(role text primary key, u uuid);
grant select on us to public;
insert into us values ('admin', pg_temp.mk((select org from fx), 'admin'));
insert into us values ('member', pg_temp.mk((select org from fx), 'member'));

-- three members with accounts: m1 active, m2 rejected (no account), m3 active with a booking
create function pg_temp.person_member(p_id text, p_no text, p_final text, p_account boolean) returns void language plpgsql as $$
declare per text := core.ulid(); prof text := core.ulid(); u uuid := gen_random_uuid(); org text := (select id from public.orgs where code = 'cpc');
begin
  insert into public.persons (id, org_id, display_name) values (per, org, 'Fake Member ' || p_no);
  if p_account then
    insert into auth.users (id, email) values (u, lower(p_no) || '@members.example.test');
    insert into public.profiles (id, org_id, auth_user_id, person_id) values (prof, org, u, per);
    insert into public.org_members (org_id, profile_id, role_id) values (org, prof, (select id from public.roles where org_id = org and code = 'member'));
  end if;
  insert into public.members (id, org_id, person_id, profile_id, member_no) values (p_id, org, per, case when p_account then prof end, p_no);
  update public.members set status = 'invited' where id = p_id;
  update public.members set status = 'pending_approval' where id = p_id;
  if p_final = 'rejected' then update public.members set status = 'rejected', status_reason = 'test' where id = p_id;
  else update public.members set status = 'active' where id = p_id; end if;
end $$;
select pg_temp.person_member((select m1 from fx), 'CPC-2026-9810', 'active', true);
select pg_temp.person_member((select m2 from fx), 'CPC-2026-9811', 'rejected', false);
select pg_temp.person_member((select m3 from fx), 'CPC-2026-9812', 'active', true);
insert into public.courts (id, org_id, code, name) values ((select court from fx), (select org from fx), 't10-court', 'T10 Court');
insert into public.bookings (org_id, doc_no, court_id, requested_by_member_id, during, rate_snapshot, price_snapshot, court_name_snapshot, payload_hash)
values ((select org from fx), 'T10-BK-1', (select court from fx), (select m3 from fx),
  tstzrange(now() + interval '2 days', now() + interval '2 days 1 hour', '[)'), 0, 0, 'T10 Court', repeat('c', 64));

-- ---- access
select is(has_function_privilege('anon', 'public.archive_member(text,text,text)', 'execute'), false, 'anonymous callers cannot archive');
select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
select throws_ok(format($f$select public.archive_member(%L, 'left the club', %L)$f$, (select m1 from fx), (select k1 from fx)), '42501', null, 'a member cannot archive anyone');
reset role;

-- ---- archive
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select throws_ok(format($f$select public.archive_member(%L, '', %L)$f$, (select m1 from fx), (select k2 from fx)), '22023', 'a reason is required', 'a reason is required');
create temp table a1 as select public.archive_member((select m1 from fx), 'left the club', (select k3 from fx)) as r;
reset role;
grant select on a1 to public;
select is((select status from public.members where id = (select m1 from fx)), 'archived', 'the member is archived');
select is((select bool_and(not om.is_active) from public.org_members om join public.members m on m.profile_id = om.profile_id where m.id = (select m1 from fx)), true, 'their access is switched off');
select is((select count(*)::int from public.member_status_events where member_id = (select m1 from fx) and to_status = 'archived' and reason = 'left the club'), 1, 'the status history has it');
select is((select count(*)::int from core.audit_log where action = 'member.archive' and record_id = (select m1 from fx)), 1, 'and the audit log');
set local role authenticated;
select is((select public.archive_member((select m1 from fx), 'left the club', (select k3 from fx))), (select r from a1), 'the same key replays the first answer');
select is((select (public.archive_member((select m1 from fx), 'left the club', (select k4 from fx))) ->> 'unchanged'), 'true', 'archiving again changes nothing');
reset role;

-- ---- delete and restore
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select throws_ok(format($f$select public.soft_delete('members', %L, 'duplicate record', %L)$f$, (select m3 from fx), (select k5 from fx)), '23503', null, 'an active member cannot be deleted');
select is((select public.soft_delete('members', (select m1 from fx), 'duplicate record', (select k6 from fx)) ->> 'ok'), 'true', 'an archived member can be deleted');
select is((select public.soft_delete('members', (select m2 from fx), 'duplicate record', (select k7 from fx)) ->> 'ok'), 'true', 'so can a rejected one');
select is((select public.restore_row('members', (select m1 from fx), (select k8 from fx)) ->> 'ok'), 'true', 'and it can be restored');
reset role;
select is((select status from public.members where id = (select m1 from fx)), 'archived', 'with the status it had');

-- archive the member with a booking: the booking blocks deletion
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select is((select public.archive_member((select m3 from fx), 'moved away', (select k9 from fx)) ->> 'ok'), 'true', 'a member with a booking can be archived');
select throws_ok(format($f$select public.soft_delete('members', %L, 'duplicate record', %L)$f$, (select m3 from fx), (select k10 from fx)), '23503', 'the member still has upcoming bookings or event registrations; cancel them first', 'but not deleted while the booking stands');
reset role;

-- ---- import issues
insert into public.import_batches (id, org_id, file_sha256) values ((select batch from fx), (select org from fx), repeat('d', 64));
insert into public.member_import_issues (id, org_id, batch_id, source_row, issue_code, detail)
values ((select issue from fx), (select org from fx), (select batch from fx), 7, 'invalid_birth_date', 'test');
select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
select throws_ok(format($f$select public.resolve_import_issue(%L, 'checked', %L)$f$, (select issue from fx), core.ulid()), '42501', null, 'a member cannot resolve import issues');
reset role;
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
create temp table i1 as select public.resolve_import_issue((select issue from fx), 'birth date confirmed by phone', (select k1 from fx)) as r;
reset role;
grant select on i1 to public;
select is((select r ->> 'ok' from i1), 'true', 'an admin resolves an issue');
select isnt((select resolved_at from public.member_import_issues where id = (select issue from fx)), null, 'it is marked resolved');
select is((select meta ->> 'resolution_note' from public.member_import_issues where id = (select issue from fx)), 'birth date confirmed by phone', 'with the note');
set local role authenticated;
select is((select public.resolve_import_issue((select issue from fx), 'birth date confirmed by phone', (select k1 from fx))), (select r from i1), 'the same key replays');
select is((select (public.resolve_import_issue((select issue from fx), null, core.ulid())) ->> 'unchanged'), 'true', 'resolving again changes nothing');
reset role;

select * from finish();
rollback;
