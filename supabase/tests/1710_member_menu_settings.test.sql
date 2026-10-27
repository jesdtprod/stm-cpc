begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org, core.ulid() as k1, core.ulid() as k2;
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

-- ---- seed: four switches, all on
select is((select count(*)::int from public.settings s where s.org_id = (select org from fx) and s.unit_id is null
  and s.deleted_at is null and s.key like 'member_menu.%' and s.value = 'true'::jsonb), 4, 'four member menu switches start on');

-- ---- rules
select is(core.setting_valid('member_menu.book', 'false'), true, 'a member menu switch takes false');
select is(core.setting_valid('member_menu.ranking', '"no"'), false, 'but not text');
select is(core.setting_valid('member_menu.events', '0'), false, 'nor a number');
select is(core.setting_valid('public.leaderboard_enabled', '"yes"'), false, 'earlier switches keep their rule');
select is(core.setting_valid('booking.slot_minutes', '600'), false, 'earlier ranges keep their rule');

-- ---- access
select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
select is((select count(*)::int from public.settings where key like 'member_menu.%'), 4, 'a member can read the switches');
select throws_ok(format($f$select public.update_setting('member_menu.book', 'false', null, %L)$f$, (select k1 from fx)),
  '42501', null, 'a member cannot change them');
reset role;

select pg_temp.as_user((select u from us where role = 'manager'));
set local role authenticated;
select lives_ok(format($f$select public.update_setting('member_menu.book', 'false', 'hide booking', %L)$f$, (select k2 from fx)),
  'a manager can hide a link');
select throws_ok(format($f$select public.update_setting('member_menu.book', '"off"', null, %L)$f$, core.ulid()),
  '22023', null, 'a non-boolean value is refused');
reset role;
select is((select value from public.settings where org_id = (select org from fx) and key = 'member_menu.book' and unit_id is null
  and deleted_at is null), 'false'::jsonb, 'the switch is stored off');

select * from finish();
rollback;
