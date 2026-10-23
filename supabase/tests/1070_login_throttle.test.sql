begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create temp table fx as select (select id from public.orgs where code = 'cpc') as org, gen_random_uuid() as u1,
  core.ulid() as per1, core.ulid() as prof1, core.ulid() as mem1;
grant select on fx to public;

-- ---- access
select is(has_function_privilege('anon', 'public.login_record_failure(text,integer,integer,integer)', 'execute'), false, 'anon cannot record login failures');
select is(has_function_privilege('authenticated', 'public.login_record_failure(text,integer,integer,integer)', 'execute'), false, 'members cannot record login failures');
select is(has_function_privilege('authenticated', 'public.login_is_locked(text[])', 'execute'), false, 'members cannot probe lockouts');
select is(has_function_privilege('authenticated', 'public.member_login_state(uuid)', 'execute'), false, 'members cannot read login state');
select is(has_function_privilege('authenticated', 'public.member_login_succeeded(text)', 'execute'), false, 'members cannot stamp a login');
select is(has_function_privilege('service_role', 'public.login_record_failure(text,integer,integer,integer)', 'execute'), true, 'the Edge Function (service_role) can');
select is(has_function_privilege('service_role', 'public.member_login_state(uuid)', 'execute'), true, 'and can read login state');
select is(has_table_privilege('authenticated', 'core.login_throttle', 'select'), false, 'the counters are not readable by clients');

-- ---- counters and lockout
create temp table k as select 'id:' || repeat('a', 64) as idk, 'ip:' || repeat('b', 64) as ipk;
grant select on k to public;
select throws_ok($$insert into core.login_throttle (key_hash) values ('plain-member-id')$$, '23514', null, 'only hashed keys are stored');
select is(core.login_is_locked(array[(select idk from k)]), false, 'an unseen key is not locked');
select is(core.login_record_failure((select idk from k), 3, 900, 900), false, 'failure 1 of 3 does not lock');
select is(core.login_record_failure((select idk from k), 3, 900, 900), false, 'failure 2 of 3 does not lock');
select is(core.login_is_locked(array[(select idk from k)]), false, 'still open before the limit');
select is(core.login_record_failure((select idk from k), 3, 900, 900), true, 'failure 3 of 3 locks the key');
select is(core.login_is_locked(array[(select idk from k)]), true, 'and it reads as locked');
select is(core.login_is_locked(array[(select ipk from k), (select idk from k)]), true, 'any locked key in the list locks the attempt');
select is(core.login_is_locked(array[(select ipk from k)]), false, 'while another key stays open');
select is(core.login_record_failure((select idk from k), 3, 900, 900), true, 'further failures keep it locked');
select is((select failures from core.login_throttle where key_hash = (select idk from k)), 4, 'and are counted');

select core.login_clear((select idk from k));
select is(core.login_is_locked(array[(select idk from k)]), false, 'clearing a key opens it');
select is((select count(*)::int from core.login_throttle where key_hash = (select idk from k)), 0, 'and removes its row');

-- the window: old failures stop counting
select core.login_record_failure((select ipk from k), 3, 900, 900);
select core.login_record_failure((select ipk from k), 3, 900, 900);
update core.login_throttle set window_started_at = now() - interval '1 hour' where key_hash = (select ipk from k);
select is(core.login_record_failure((select ipk from k), 3, 900, 900), false, 'failures older than the window start a new count');
select is((select failures from core.login_throttle where key_hash = (select ipk from k)), 1, 'which restarts at one');

-- a lock expires on its own
select core.login_record_failure('id:' || repeat('c', 64), 1, 900, 900);
select is(core.login_is_locked(array['id:' || repeat('c', 64)]), true, 'a limit of one locks at once');
update core.login_throttle set locked_until = now() - interval '1 second' where key_hash = 'id:' || repeat('c', 64);
select is(core.login_is_locked(array['id:' || repeat('c', 64)]), false, 'an expired lock no longer blocks');

-- purge removes only old, unlocked rows
insert into core.login_throttle (key_hash, failures, updated_at) values ('id:' || repeat('d', 64), 1, now() - interval '3 days');
insert into core.login_throttle (key_hash, failures, updated_at, locked_until) values ('id:' || repeat('e', 64), 5, now() - interval '3 days', now() + interval '1 hour');
select cmp_ok(core.login_purge_old(), '>=', 1, 'old unlocked rows are purged');
select is((select count(*)::int from core.login_throttle where key_hash = 'id:' || repeat('d', 64)), 0, 'the stale row is gone');
select is((select count(*)::int from core.login_throttle where key_hash = 'id:' || repeat('e', 64)), 1, 'a row that is still locked is kept');

-- ---- login state for an Auth user
select is((select count(*)::int from core.member_login_state((select u1 from fx))), 0, 'an unknown Auth user has no login state');
insert into auth.users (id, email) values ((select u1 from fx), 'cpc-2026-95001@members.example.test');
insert into public.persons (id, org_id, display_name) values ((select per1 from fx), (select org from fx), 'Fake Login Member');
insert into public.profiles (id, org_id, auth_user_id, person_id) values ((select prof1 from fx), (select org from fx), (select u1 from fx), (select per1 from fx));
insert into public.members (id, org_id, person_id, profile_id, member_no, status) values ((select mem1 from fx), (select org from fx), (select per1 from fx), (select prof1 from fx), 'CPC-2026-95001', 'imported');
insert into public.member_access (org_id, member_id, must_change_password, temp_password_expires_at) values ((select org from fx), (select mem1 from fx), true, now() + interval '30 days');
select is((select member_no from core.member_login_state((select u1 from fx))), 'CPC-2026-95001', 'the state finds the member by Auth user');
select is((select status from core.member_login_state((select u1 from fx))), 'imported', 'with the status');
select is((select must_change_password from core.member_login_state((select u1 from fx))), true, 'the forced-change flag');
select ok((select temp_password_expires_at from core.member_login_state((select u1 from fx))) > now() + interval '29 days', 'and the expiry');
select is((select count(*)::int from public.member_login_state((select u1 from fx))), 1, 'the public wrapper returns the same row');

update public.member_access set failed_attempts = 2 where member_id = (select mem1 from fx);
select core.member_login_succeeded((select mem1 from fx));
select ok((select last_login_at from public.member_access where member_id = (select mem1 from fx)) is not null, 'a successful sign-in stamps last_login_at');
select is((select failed_attempts from public.member_access where member_id = (select mem1 from fx)), 0, 'and resets failed_attempts');
select ok(exists(select 1 from core.audit_log where action = 'login.success' and record_id = (select mem1 from fx)), 'and is audited');
select is((select count(*)::int from core.audit_log where action = 'login.success' and record_id = (select mem1 from fx) and (old_values is not null or new_values is not null)), 0, 'with no personal data in the audit row');

update public.profiles set is_active = false where id = (select prof1 from fx);
select is((select count(*)::int from core.member_login_state((select u1 from fx))), 0, 'a deactivated profile has no login state');

select * from finish();
rollback;
