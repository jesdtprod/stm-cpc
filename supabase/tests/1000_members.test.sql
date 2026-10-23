begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

-- A user with a role, a person and a profile. Returns the auth user id.
create function pg_temp.mk(p_org text, p_role text, p_person text default null) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := coalesce(p_person, core.ulid()); rid text;
begin
  select id into rid from public.roles where org_id = p_org and code = p_role;
  insert into auth.users (id, email) values (u, p_role || '-' || u || '@example.test');
  if p_person is null then
    insert into public.persons (id, org_id, display_name) values (per, p_org, 'Fake ' || p_role);
  end if;
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, p_org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (p_org, pid, rid);
  return u;
end $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as per_a, core.ulid() as per_b, core.ulid() as per_c, core.ulid() as mem_a, core.ulid() as mem_b;
grant select on fx to public;

insert into public.persons (id, org_id, display_name) values
  ((select per_a from fx), (select org from fx), 'Fake Member A'),
  ((select per_b from fx), (select org from fx), 'Fake Member B'),
  ((select per_c from fx), (select org from fx), 'Fake Member C');

-- ---- structure
select is((select count(*)::int from pg_class where relnamespace = 'public'::regnamespace and relrowsecurity
  and relname in ('members', 'member_access', 'member_status_events', 'import_batches', 'member_import_issues', 'consents')),
  6, 'RLS is on for all six tables');
select is((select count(*)::int from pg_class c where c.relnamespace = 'public'::regnamespace
  and c.relname in ('members', 'member_access', 'member_status_events', 'import_batches', 'member_import_issues', 'consents')
  and obj_description(c.oid, 'pg_class') like 'class: %'), 6, 'every table has a class comment');

-- ---- members: format, uniqueness, soft delete frees the ID
insert into public.members (id, org_id, person_id, member_no, status, rfid_code)
  values ((select mem_a from fx), (select org from fx), (select per_a from fx), 'CPC-2026-00001', 'imported', 'RF-0001');
select throws_ok($$insert into public.members (org_id, person_id, member_no) select org_id, core.ulid(), 'cpc-2026-00002' from public.orgs where code = 'cpc'$$,
  '23514', null, 'a member number must be uppercase and trimmed');
select throws_ok(format($f$insert into public.members (org_id, person_id, member_no) values (%L, %L, 'CPC-2026-00009')$f$, (select org from fx), core.ulid()),
  '23503', null, 'a member needs an existing person');
select throws_ok(format($f$insert into public.members (org_id, person_id, member_no) values (%L, %L, 'CPC-2026-00001')$f$, (select org from fx), (select per_b from fx)),
  '23505', null, 'a member number is unique among active members');
select throws_ok(format($f$insert into public.members (org_id, person_id, member_no, rfid_code) values (%L, %L, 'CPC-2026-00002', 'RF-0001')$f$, (select org from fx), (select per_b from fx)),
  '23505', null, 'an RFID code is unique among active members');
select throws_ok(format($f$insert into public.members (org_id, person_id, member_no) values (%L, %L, 'CPC-2026-00003')$f$, (select org from fx), (select per_a from fx)),
  '23505', null, 'a person is a member only once');
select lives_ok(format($f$insert into public.members (id, org_id, person_id, member_no, status) values (%L, %L, %L, 'CPC-2026-00002', 'pending_approval')$f$,
  (select mem_b from fx), (select org from fx), (select per_b from fx)), 'two members without an RFID code are fine');
select lives_ok(format($f$insert into public.members (org_id, person_id, member_no) values (%L, %L, 'CPC-2026-00004')$f$, (select org from fx), (select per_c from fx)),
  'a third member without an RFID code is fine');

select set_config('core.rpc', 'on', true);
update public.members set deleted_at = now(), deleted_by = 'system', delete_reason = 'test' where id = (select mem_a from fx);
select set_config('core.rpc', 'off', true);
select lives_ok(format($f$update public.persons set display_name = display_name where id = %L$f$, (select per_a from fx)), 'person stays editable');
select throws_ok(format($f$update public.members set status_reason = 'x' where id = %L$f$, (select mem_a from fx)),
  '55000', null, 'a deleted member rejects updates');
select throws_ok(format($f$delete from public.members where id = %L$f$, (select mem_a from fx)),
  '42501', null, 'a member cannot be hard-deleted');
-- The number and the RFID code are free again while the row is deleted, and clash again on restore.
insert into public.persons (id, org_id, display_name) values ('01H0000000000000000000PER9', (select org from fx), 'Fake Reuse');
insert into public.members (id, org_id, person_id, member_no, rfid_code)
  values ('01H0000000000000000000MEM9', (select org from fx), '01H0000000000000000000PER9', 'CPC-2026-00001', 'RF-0001');
select pass('a deleted member frees its number and RFID code');
select set_config('core.rpc', 'on', true);
select throws_ok(format($f$update public.members set deleted_at = null, deleted_by = null, delete_reason = null where id = %L$f$, (select mem_a from fx)),
  '23505', null, 'restoring clashes with the new holder of the number');
update public.members set deleted_at = now(), deleted_by = 'system', delete_reason = 'test' where id = '01H0000000000000000000MEM9';
update public.members set deleted_at = null, deleted_by = null, delete_reason = null where id = (select mem_a from fx);
select set_config('core.rpc', 'off', true);
select is((select deleted_at is null from public.members where id = (select mem_a from fx)), true, 'a member can be restored once the number is free');

-- ---- status guard and history
select throws_ok(format($f$insert into public.members (org_id, person_id, member_no, status) values (%L, %L, 'CPC-2026-00007', 'active')$f$, (select org from fx), core.ulid()),
  '22023', null, 'a new member cannot start as active');
select throws_ok(format($f$update public.members set status = 'active' where id = %L$f$, (select mem_a from fx)),
  '22023', null, 'imported cannot jump to active');
select lives_ok(format($f$update public.members set status = 'invited' where id = %L$f$, (select mem_a from fx)), 'imported -> invited');
select lives_ok(format($f$update public.members set status = 'pending_approval' where id = %L$f$, (select mem_a from fx)), 'invited -> pending_approval');
select lives_ok(format($f$update public.members set status = 'active', status_reason = 'approved' where id = %L$f$, (select mem_a from fx)), 'pending_approval -> active');
select lives_ok(format($f$update public.members set status = 'suspended', status_reason = 'unpaid' where id = %L$f$, (select mem_a from fx)), 'active -> suspended');
select lives_ok(format($f$update public.members set status = 'active', status_reason = 'cleared' where id = %L$f$, (select mem_a from fx)), 'suspended -> active');
select throws_ok(format($f$update public.members set status = 'rejected' where id = %L$f$, (select mem_a from fx)),
  '22023', null, 'active cannot become rejected');
select lives_ok(format($f$update public.members set status = 'archived' where id = %L$f$, (select mem_a from fx)), 'active -> archived');
select throws_ok(format($f$update public.members set status = 'active' where id = %L$f$, (select mem_a from fx)),
  '22023', null, 'archived is final');
select is((select count(*)::int from public.member_status_events where member_id = (select mem_a from fx)), 7, 'every status change is written to member_status_events');
select is((select count(*)::int from public.member_status_events where member_id = (select mem_a from fx)
  and ((from_status is null and to_status = 'imported') or (from_status = 'active' and to_status = 'suspended')
    or (from_status = 'suspended' and to_status = 'active') or (from_status = 'active' and to_status = 'archived'))),
  4, 'the history records the first status and the later transitions');
select throws_ok(format($f$update public.member_status_events set reason = 'x' where member_id = %L$f$, (select mem_a from fx)),
  '42501', null, 'status events cannot be edited');
select throws_ok(format($f$delete from public.member_status_events where member_id = %L$f$, (select mem_a from fx)),
  '42501', null, 'status events cannot be deleted');

-- ---- member_access
insert into public.member_access (org_id, member_id) values ((select org from fx), (select mem_b from fx));
select is((select must_change_password from public.member_access where member_id = (select mem_b from fx)), true, 'must_change_password defaults to true');
select throws_ok(format($f$insert into public.member_access (org_id, member_id) values (%L, %L)$f$, (select org from fx), (select mem_b from fx)),
  '23505', null, 'one access row per member');
select throws_ok(format($f$update public.member_access set failed_attempts = -1 where member_id = %L$f$, (select mem_b from fx)),
  '23514', null, 'failed_attempts cannot be negative');

-- ---- import tables
insert into public.import_batches (id, org_id, file_sha256) values ('01H0000000000000000000BAT1', (select org from fx), repeat('a', 64));
select throws_ok(format($f$insert into public.import_batches (org_id, file_sha256) values (%L, 'not-a-hash')$f$, (select org from fx)),
  '23514', null, 'the file hash must be a sha-256 hex string');
select throws_ok(format($f$insert into public.import_batches (org_id, file_sha256, status) values (%L, %L, 'weird')$f$, (select org from fx), repeat('b', 64)),
  '23514', null, 'import batch status is checked');
insert into public.member_import_issues (org_id, batch_id, source_row, member_no_claimed, issue_code)
  values ((select org from fx), '01H0000000000000000000BAT1', 12, 'CPC-2026-00099', 'duplicate_member_no');
select throws_ok(format($f$insert into public.member_import_issues (org_id, batch_id, source_row, issue_code) values (%L, '01H0000000000000000000BAT1', 12, 'duplicate_member_no')$f$, (select org from fx)),
  '23505', null, 'the same issue is reported once per row');
select lives_ok(format($f$insert into public.member_import_issues (org_id, batch_id, source_row, issue_code) values (%L, '01H0000000000000000000BAT1', 12, 'invalid_email')$f$, (select org from fx)),
  'a different issue on the same row is allowed');
select throws_ok(format($f$insert into public.member_import_issues (org_id, batch_id, source_row, issue_code) values (%L, '01H0000000000000000000BAT1', 13, 'made_up')$f$, (select org from fx)),
  '23514', null, 'issue codes are checked');
select throws_ok(format($f$update public.member_import_issues set resolved_at = now() where source_row = 12 and issue_code = 'invalid_email' and org_id = %L$f$, (select org from fx)),
  '23514', null, 'resolved_at and resolved_by are set together');

-- ---- consents are append-only
insert into public.consents (id, org_id, person_id, kind, doc_version)
  values ('01H0000000000000000000CNS1', (select org from fx), (select per_a from fx), 'waiver', '2026-01');
select throws_ok($$update public.consents set doc_version = 'x'$$, '42501', null, 'consents cannot be edited');
select throws_ok($$delete from public.consents$$, '42501', null, 'consents cannot be deleted');
select throws_ok(format($f$insert into public.consents (org_id, person_id, kind, doc_version) values (%L, %L, 'other', '1')$f$, (select org from fx), (select per_a from fx)),
  '23514', null, 'consent kinds are checked');

-- ---- permissions
select is((select count(*)::int from public.role_permissions rp join public.roles r on r.id = rp.role_id join public.permissions pe on pe.id = rp.permission_id
  where r.code = 'admin' and pe.code in ('members.review_import', 'consents.read', 'consents.record')), 3, 'admin holds the three new permission codes');
select is((select count(*)::int from public.role_permissions rp join public.roles r on r.id = rp.role_id join public.permissions pe on pe.id = rp.permission_id
  where r.code <> 'admin' and pe.code in ('members.review_import', 'consents.read', 'consents.record')), 0, 'no other role holds them yet');
select lives_ok($$select core.add_permission('members.review_import', 'again')$$, 'add_permission is idempotent');

-- ---- row-level security, with real users
create temp table us(role text primary key, u uuid);
grant select on us to public;
insert into us values ('admin', pg_temp.mk((select org from fx), 'admin'));
insert into us values ('manager', pg_temp.mk((select org from fx), 'manager'));
insert into us values ('member_b', pg_temp.mk((select org from fx), 'member', (select per_b from fx)));
update public.members set profile_id = (select id from public.profiles where auth_user_id = (select u from us where role = 'member_b')) where id = (select mem_b from fx);

select pg_temp.as_user((select u from us where role = 'member_b'));
set local role authenticated;
select is((select count(*)::int from public.members), 1, 'a member sees only their own member row');
select is((select member_no from public.members), 'CPC-2026-00002', 'and it is the right one');
select is((select count(*)::int from public.consents), 0, 'a member sees only their own consents (none here)');
select is((select count(*)::int from public.import_batches), 0, 'a member sees no import batches');
select is((select count(*)::int from public.member_import_issues), 0, 'a member sees no import issues');
select throws_ok($$select * from public.member_access$$, '42501', null, 'a member cannot read member_access');
select throws_ok($$insert into public.members (org_id, person_id, member_no) values (core.ulid(), core.ulid(), 'CPC-2026-00500')$$, '42501', null, 'a member cannot create members');
select throws_ok($$update public.members set status = 'active'$$, '42501', null, 'a member cannot change their own status');
select throws_ok($$update public.members set rfid_code = 'RF-9999'$$, '42501', null, 'a member cannot change an RFID code directly');
select throws_ok($$insert into public.consents (org_id, person_id, kind, doc_version) values (core.ulid(), core.ulid(), 'waiver', '1')$$, '42501', null, 'a member cannot write consents directly');
reset role;

select pg_temp.as_user((select u from us where role = 'manager'));
set local role authenticated;
select is((select count(*)::int from public.members), 4, 'a manager (members.read) sees every member');
select is((select count(*)::int from public.member_status_events) > 0, true, 'a manager reads status history');
select is((select count(*)::int from public.import_batches), 0, 'a manager without members.import sees no import batches');
select is((select count(*)::int from public.consents), 0, 'a manager without consents.read sees no consents');
reset role;

select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select is((select count(*)::int from public.import_batches), 1, 'an admin sees the import batch');
select is((select count(*)::int from public.member_import_issues where source_row = 12), 2, 'an admin sees the import issues');
select is((select count(*)::int from public.consents), 1, 'an admin sees consents');
select throws_ok($$select * from public.member_access$$, '42501', null, 'even an admin cannot read member_access directly');
select throws_ok($$update public.members set status = 'suspended'$$, '42501', null, 'an admin cannot update members directly either (RPC only)');
reset role;

-- ---- audit
select ok(exists(select 1 from core.audit_log where table_name = 'public.members' and record_id = (select mem_a from fx) and action = 'update'),
  'member changes are audited');

select * from finish();
rollback;
