begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as k1, core.ulid() as k2, core.ulid() as k3, core.ulid() as k4, core.ulid() as k5, core.ulid() as k6;
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
insert into us values ('manager', pg_temp.mk((select org from fx), 'manager'));
insert into us values ('member', pg_temp.mk((select org from fx), 'member'));

-- ---- the rules, key by key
select is(core.setting_valid('members.signup_enabled', 'true'), true, 'a switch takes true');
select is(core.setting_valid('members.signup_enabled', '"yes"'), false, 'but not text');
select is(core.setting_valid('session.idle_minutes', '15'), true, 'the idle timeout takes 15');
select is(core.setting_valid('session.idle_minutes', '2'), false, 'but not 2 minutes');
select is(core.setting_valid('session.idle_minutes', '15.5'), false, 'nor a fraction');
select is(core.setting_valid('session.idle_minutes', '"15"'), false, 'nor text');
select is(core.setting_valid('members.temp_password_days', '0'), true, 'zero days means no expiry');
select is(core.setting_valid('members.temp_password_days', '-1'), false, 'a negative number is refused');
select is(core.setting_valid('booking.slot_minutes', '60'), true, 'a 60 minute slot is allowed');
select is(core.setting_valid('booking.slot_minutes', '600'), false, 'a 10 hour slot is not');
select is(core.setting_valid('booking.cancel_fee', '150.50'), true, 'a fee with centavos is allowed');
select is(core.setting_valid('booking.cancel_fee', '1.234'), false, 'but not a third decimal');
select is(core.setting_valid('booking.cancel_fee', '-5'), false, 'nor a negative fee');
select is(core.setting_valid('payments.methods', '["cash", "gcash"]'), true, 'a list of known methods is allowed');
select is(core.setting_valid('payments.methods', '[]'), false, 'an empty list is not');
select is(core.setting_valid('payments.methods', '["cash", "cash"]'), false, 'nor a repeat');
select is(core.setting_valid('payments.methods', '["cheque"]'), false, 'nor an unknown method');
select is(core.setting_valid('payments.methods', '"cash"'), false, 'nor a bare word');
select is(core.setting_valid('members.id_prefix', '"CPC"'), true, 'the ID prefix takes capital letters');
select is(core.setting_valid('members.id_prefix', '"cpc-1"'), false, 'but not other text');
select is(core.setting_valid('club.name', '"  "'), false, 'the club name cannot be blank');
select is(core.setting_valid('payments.instructions', to_jsonb(repeat('x', 1001))), false, 'instructions have a length limit');
select is(core.setting_valid('some.new_key', '1'), true, 'a key the club adds itself keeps the generic rule');
select is(core.setting_valid('some.new_key', 'null'), false, 'but never null');
select is(core.setting_valid('timezone', '"Asia/Manila"'), true, 'a real time zone is allowed');

-- ---- the existing seed still satisfies the rules
select is((select count(*)::int from public.settings where deleted_at is null and not core.setting_valid(key, value)), 0, 'every stored setting passes its rule');

-- ---- access
select is(has_function_privilege('anon', 'public.update_setting(text,jsonb,text,text)', 'execute'), false, 'anonymous callers cannot change settings');
select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
select throws_ok(format($f$select public.update_setting('club.name', '"X Club"', null, %L)$f$, (select k1 from fx)), '42501', null, 'a member cannot change settings');
reset role;

-- ---- a manager changes a setting
select pg_temp.as_user((select u from us where role = 'manager'));
set local role authenticated;
create temp table r1 as select public.update_setting('booking.slot_minutes', '90', 'club decision', (select k2 from fx)) as r;
reset role;
grant select on r1 to public;
select is((select r ->> 'ok' from r1), 'true', 'the change is accepted');
select is((select value from public.settings where key = 'booking.slot_minutes' and deleted_at is null and unit_id is null), '90'::jsonb, 'and stored');
select is((select count(*)::int from core.audit_log where action = 'setting.update' and (new_values ->> 'key') = 'booking.slot_minutes' and (new_values ->> 'reason') = 'club decision'), 1, 'the old value, new value and reason are in the audit log');
select is((select (old_values -> 'value')::text from core.audit_log where action = 'setting.update' and (new_values ->> 'key') = 'booking.slot_minutes'), '60', 'the old value is kept');

set local role authenticated;
select is((select public.update_setting('booking.slot_minutes', '90', 'club decision', (select k2 from fx))), (select r from r1), 'the same key replays the first answer');
select throws_ok(format($f$select public.update_setting('booking.slot_minutes', '120', 'club decision', %L)$f$, (select k2 from fx)), 'CP422', null, 'the same key with another value is refused');
select is((select (public.update_setting('booking.slot_minutes', '90', null, (select k3 from fx))) ->> 'unchanged'), 'true', 'setting the same value again changes nothing');
select throws_ok(format($f$select public.update_setting('booking.slot_minutes', '5', null, %L)$f$, (select k4 from fx)), '22023', 'that value is not allowed for this setting', 'a value outside the range is refused');
select throws_ok(format($f$select public.update_setting('made.up_key', '1', null, %L)$f$, (select k5 from fx)), '22023', 'unknown setting', 'the app cannot create new keys');
select throws_ok(format($f$select public.update_setting('timezone', '"Asia/Tokyo"', null, %L)$f$, (select k6 from fx)), '22023', 'this setting is changed by the club developer, not in the app', 'the time zone cannot be changed here');
select throws_ok(format($f$select public.update_setting('members.id_pattern', '".*"', null, %L)$f$, core.ulid()), '22023', null, 'nor the member ID pattern');
select throws_ok(format($f$select public.update_setting('members.id_prefix', '"ABC"', null, %L)$f$, core.ulid()), '22023', 'this setting is changed by the club developer, not in the app', 'nor the member ID prefix');
select throws_ok(format($f$select public.update_setting('events.default_scoring_rule', '"No Such Rule"', null, %L)$f$, core.ulid()), '22023', 'there is no scoring rule with that name', 'the default scoring rule must exist');
select lives_ok(format($f$select public.update_setting('events.default_scoring_rule', %L, null, %L)$f$, (select to_jsonb(name)::text from public.scoring_rules where deleted_at is null order by name limit 1), core.ulid()), 'a rule that exists is accepted');
reset role;

select * from finish();
rollback;
