begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create function pg_temp.mk(p_role text, p_unit text default null) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); org text; rid text;
begin
  select id into org from public.orgs where code = 'cpc';
  select id into rid from public.roles where org_id = org and code = p_role;
  insert into auth.users (id, email) values (u, p_role || '-' || u || '@example.test');
  insert into public.persons (id, org_id, display_name) values (per, org, 'Fake ' || p_role);
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, org, u, per);
  insert into public.org_members (org_id, profile_id, unit_id, role_id) values (org, pid, p_unit, rid);
  return u;
end $$;

create temp table cx as select (select id from public.orgs where code = 'cpc') as org, core.ulid() as unit1, core.ulid() as k1, core.ulid() as k2, core.ulid() as k3, core.ulid() as k4;
grant select on cx to public;
insert into public.org_units (id, org_id, code, name) values ((select unit1 from cx), (select org from cx), 'u1', 'Unit 1');
create temp table us(role text primary key, u uuid);
grant select on us to public;
insert into us select r, pg_temp.mk(r) from unnest(array['member', 'manager', 'admin']) r;
insert into us values ('unit_manager', pg_temp.mk('manager', (select unit1 from cx)));
insert into us values ('member2', pg_temp.mk('member'));

-- every table is classified in its comment
select is(
  (select count(*)::int from pg_class c
    where c.relkind = 'r' and c.relnamespace in ('public'::regnamespace, 'core'::regnamespace)
      and (obj_description(c.oid, 'pg_class') is null or obj_description(c.oid, 'pg_class') not like 'class: %')),
  0, 'every table in public and core carries a class comment');
select is(
  (select count(*)::int from pg_class c
    where c.relkind = 'r' and c.relnamespace in ('public'::regnamespace, 'core'::regnamespace) and not c.relrowsecurity),
  0, 'RLS is enabled on every table in public and core');

-- idempotency: replay, changed payload, in progress, failed retry, expiry
select is(core.idem_begin((select k1 from cx), (select org from cx), 'booking.cancel', '{"id": 1, "reason": "x"}'), null, 'first call proceeds');
select core.idem_complete((select k1 from cx), '{"ok": true}');
select is(core.idem_begin((select k1 from cx), (select org from cx), 'booking.cancel', '{"reason": "x", "id": 1}'), '{"ok": true}'::jsonb, 'same key and payload replays the stored response (key order is irrelevant)');
select throws_ok(
  format($f$select core.idem_begin(%L, %L, 'booking.cancel', '{"id": 2}')$f$, (select k1 from cx), (select org from cx)),
  'CP422', 'idempotency key reused with a different request', 'same key with a different payload is rejected');
select throws_ok(
  format($f$select core.idem_begin(%L, %L, 'other.scope', '{"id": 1, "reason": "x"}')$f$, (select k1 from cx), (select org from cx)),
  'CP422', null, 'same key under a different scope is rejected');
select is(core.idem_begin((select k2 from cx), (select org from cx), 'booking.cancel', '{"id": 5}'), null, 'a new key proceeds');
select throws_ok(
  format($f$select core.idem_begin(%L, %L, 'booking.cancel', '{"id": 5}')$f$, (select k2 from cx), (select org from cx)),
  'CP409', 'request is still in progress, retry later', 'a duplicate while in progress returns retry later');
select core.idem_fail((select k2 from cx));
select is(core.idem_begin((select k2 from cx), (select org from cx), 'booking.cancel', '{"id": 5}'), null, 'a failed key may be retried');
select throws_ok($$select core.idem_begin('nope', null, 's', '{}')$$, '22023', 'invalid idempotency key', 'a malformed key is rejected');
select core.idem_complete((select k2 from cx), null);
select is(core.idem_begin((select k2 from cx), (select org from cx), 'booking.cancel', '{"id": 5}'), 'null'::jsonb, 'a null response replays as json null');
update core.idempotency_keys set expires_at = now() - interval '1 day' where id = (select k1 from cx);
select is(core.purge_expired_idempotency_keys(), 1, 'purge removes expired keys');
select is((select count(*)::int from core.idempotency_keys where id = (select k1 from cx)), 0, 'the expired key is gone');
set local role authenticated;
select throws_ok($$select count(*) from core.idempotency_keys$$, '42501', null, 'clients cannot read idempotency keys');
select throws_ok($$select core.idem_begin('01H00000000000000000000000', null, 's', '{}')$$, '42501', null, 'clients cannot call idem_begin');
reset role;

-- counters
select is(core.next_number((select org from cx), null, 'testmember-2026'), 1::bigint, 'counter starts at 1');
select is(core.next_number((select org from cx), null, 'testmember-2026'), 2::bigint, 'counter increments');
select is(core.next_number((select org from cx), null, 'testseries-2026'), 1::bigint, 'series are independent');
select is(core.next_number((select org from cx), (select unit1 from cx), 'testmember-2026'), 1::bigint, 'units are independent');
select is(core.next_number((select org from cx), null, 'testmember-2026'), 3::bigint, 'the org series continues');

-- settings: validation and uniqueness
select is((select value from public.settings where key = 'timezone' and org_id = (select org from cx) and unit_id is null), '"Asia/Manila"'::jsonb, 'timezone seeded as Asia/Manila');
select throws_ok(
  format($f$insert into public.settings (org_id, key, value) values (%L, 'timezone', '"Mars/Olympus"')$f$, (select org from cx)),
  '23514', null, 'an invalid timezone value is rejected');
select throws_ok(
  format($f$insert into public.settings (org_id, key, value) values (%L, 'timezone', '"Asia/Tokyo"')$f$, (select org from cx)),
  '23505', null, 'one active value per org and key');
select lives_ok(
  format($f$insert into public.settings (org_id, unit_id, key, value) values (%L, %L, 'timezone', '"Asia/Tokyo"')$f$, (select org from cx), (select unit1 from cx)),
  'a unit-level value is a separate row');
select throws_ok(
  format($f$insert into public.settings (org_id, key, value) values (%L, 'Bad Key', '1')$f$, (select org from cx)),
  '23514', null, 'setting keys are validated');
select ok(exists(select 1 from core.audit_log where table_name = 'public.settings' and action = 'insert'), 'settings changes are audited');

-- settings RLS
select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
select ok((select count(*)::int from public.settings) >= 1, 'a member can read settings');
select throws_ok(
  format($f$insert into public.settings (org_id, key, value) values (%L, 'test.club_name', '"x"')$f$, (select org from cx)),
  '42501', null, 'a member cannot write settings');
reset role;
select pg_temp.as_user((select u from us where role = 'manager'));
set local role authenticated;
select lives_ok(
  format($f$insert into public.settings (org_id, key, value) values (%L, 'test.club_name', '"Capitol Pickleball Club"')$f$, (select org from cx)),
  'a manager (settings.manage) can write org settings');
reset role;
select pg_temp.as_user((select u from us where role = 'unit_manager'));
set local role authenticated;
select lives_ok(
  format($f$insert into public.settings (org_id, unit_id, key, value) values (%L, %L, 'court.rules', '"x"')$f$, (select org from cx), (select unit1 from cx)),
  'a unit-bound manager can write their unit settings');
select throws_ok(
  format($f$insert into public.settings (org_id, key, value) values (%L, 'court.rules', '"x"')$f$, (select org from cx)),
  '42501', null, 'a unit-bound manager cannot write org-wide settings');
reset role;

-- lookups
insert into public.lookups (org_id, type, code, label) values ((select org from cx), 'bank', 'gcash', 'GCash');
select throws_ok(
  format($f$insert into public.lookups (org_id, type, code, label) values (%L, 'bank', 'gcash', 'Dup')$f$, (select org from cx)),
  '23505', null, 'lookup code is unique among active rows');
select set_config('core.rpc', 'on', true);
update public.lookups set deleted_at = now(), delete_reason = 'test' where code = 'gcash';
select set_config('core.rpc', 'off', true);
select lives_ok(
  format($f$insert into public.lookups (org_id, type, code, label) values (%L, 'bank', 'gcash', 'GCash again')$f$, (select org from cx)),
  'a lookup code can be reused after soft delete');
select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
select ok((select count(*)::int from public.lookups) >= 1, 'a member can read lookups');
select throws_ok(
  format($f$insert into public.lookups (org_id, type, code, label) values (%L, 'bank', 'maya', 'Maya')$f$, (select org from cx)),
  '42501', null, 'a member cannot write lookups');
reset role;

-- files
select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
select lives_ok(
  format($f$insert into public.files (org_id, owner_table, owner_id, kind, bucket, storage_path, size_bytes) values (%L, 'bookings', 'b1', 'payment_proof', 'proofs', 'a/1.png', 1200)$f$, (select org from cx)),
  'a member can register a file they uploaded');
select throws_ok(
  format($f$insert into public.files (org_id, owner_table, owner_id, kind, bucket, storage_path, size_bytes) values (%L, 'bookings', 'b1', 'payment_proof', 'proofs', 'a/2.png', -1)$f$, (select org from cx)),
  '23514', null, 'a negative size is rejected');
select is((select count(*)::int from public.files), 1, 'the uploader sees their own file');
reset role;
select pg_temp.as_user((select u from us where role = 'member2'));
set local role authenticated;
select is((select count(*)::int from public.files), 0, 'another member cannot see it');
reset role;
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select is((select count(*)::int from public.files), 1, 'an admin (payments.verify) can see it');
reset role;

-- notifications
insert into public.notifications (org_id, recipient_profile_id, channel, template)
values ((select org from cx), (select id from public.profiles where auth_user_id = (select u from us where role = 'member')), 'in_app', 'welcome');
select throws_ok(
  format($f$insert into public.notifications (org_id, recipient_profile_id, channel, template, status) values (%L, (select id from public.profiles limit 1), 'in_app', 't', 'weird')$f$, (select org from cx)),
  '23514', null, 'notification status is validated');
select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
select is((select count(*)::int from public.notifications), 1, 'a recipient sees their notification');
reset role;
select pg_temp.as_user((select u from us where role = 'member2'));
set local role authenticated;
select is((select count(*)::int from public.notifications), 0, 'another member does not');
reset role;

-- client_errors (append-only)
select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
select lives_ok(
  format($f$insert into public.client_errors (org_id, profile_id, message) values (%L, core.current_profile_id(), 'boom')$f$, (select org from cx)),
  'a user can report their own client error');
select throws_ok($$insert into public.client_errors (profile_id, message) values (core.ulid(), 'spoof')$$, '42501', null, 'a user cannot report as someone else');
select throws_ok($$update public.client_errors set message = 'changed'$$, '42501', null, 'clients cannot update client errors (no update privilege)');
select is((select count(*)::int from public.client_errors), 0, 'a member cannot read client errors');
reset role;
select throws_ok($$update public.client_errors set message = 'changed'$$, '42501', 'client_errors is append-only: corrections are new reversing rows', 'client_errors is append-only even for the owner');
select throws_ok(
  format($f$insert into public.client_errors (message) values (%L)$f$, repeat('x', 2001)),
  '23514', null, 'an oversized message is rejected');
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select is((select count(*)::int from public.client_errors), 1, 'an admin (audit.read) can read client errors');
reset role;

select * from finish();
rollback;
