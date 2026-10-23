begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

-- tables exist with the standard columns, RLS on
select is(
  (select count(*)::int from information_schema.columns
    where table_schema = 'public'
      and table_name in ('orgs', 'org_units', 'persons', 'person_relations', 'profiles')
      and column_name in ('id', 'org_id', 'created_at', 'created_by', 'updated_at', 'updated_by', 'version', 'meta', 'deleted_at', 'deleted_by', 'delete_reason')),
  55, 'five tables carry all 11 standard columns');
select is(
  (select count(*)::int from pg_class
    where relnamespace = 'public'::regnamespace and relrowsecurity
      and relname in ('orgs', 'org_units', 'persons', 'person_relations', 'profiles')),
  5, 'RLS is enabled on all five tables');
select is(
  (select count(distinct tablename)::int from pg_policies
    where schemaname = 'public' and cmd = 'SELECT' and tablename in ('orgs', 'org_units', 'persons', 'person_relations', 'profiles')),
  5, 'every one of the five tables has a select policy (added in 0004)');
select is(
  (select count(*)::int from pg_trigger t join pg_class c on c.oid = t.tgrelid
    where c.relnamespace = 'public'::regnamespace and not t.tgisinternal and t.tgname = 'z_audit'
      and c.relname in ('orgs', 'org_units', 'persons', 'person_relations', 'profiles')),
  5, 'audit trigger attached to all five');

-- fixtures
create temp table fx as select core.ulid() as org_a, core.ulid() as org_b, core.ulid() as person_1, core.ulid() as person_2,
  gen_random_uuid() as u1, gen_random_uuid() as u2;
grant select on fx to public;

insert into public.orgs (id, code, name) values ((select org_a from fx), 'club-a', 'Club A'), ((select org_b from fx), 'club-b', 'Club B');
select is((select org_id from public.orgs where id = (select org_a from fx)), (select org_a from fx), 'orgs.org_id is set to the id');
select throws_ok($$update public.orgs set org_id = core.ulid() where code = 'club-a'$$, '42501', null, 'orgs.org_id cannot change');

-- partial unique: code reusable after soft delete
select throws_ok($$insert into public.orgs (code, name) values ('club-a', 'Dup')$$, '23505', null, 'active org code is unique');
select set_config('core.rpc', 'on', true);
update public.orgs set deleted_at = now(), delete_reason = 'test' where id = (select org_b from fx);
select set_config('core.rpc', 'off', true);
select lives_ok($$insert into public.orgs (code, name) values ('club-b', 'Club B again')$$, 'a deleted org code can be reused');

-- org_units
insert into public.org_units (org_id, code, name) values ((select org_a from fx), 'main', 'Main venue');
select throws_ok(
  format($f$insert into public.org_units (org_id, code, name) values (%L, 'main', 'Dup')$f$, (select org_a from fx)),
  '23505', null, 'unit code is unique per org');
select throws_ok(
  format($f$insert into public.org_units (org_id, code, name) values (%L, 'x', 'x')$f$, 'missing-org'),
  '23503', null, 'org_units.org_id must exist');
select throws_ok($$update public.org_units set parent_id = id$$, '23514', null, 'a unit cannot be its own parent');

-- persons and relations
insert into public.persons (id, org_id, display_name, email) values ((select person_1 from fx), (select org_a from fx), 'Person One', 'p1@example.test');
insert into public.persons (id, org_id, display_name) values ((select person_2 from fx), (select org_a from fx), 'Person Two');
select throws_ok(
  format($f$insert into public.persons (org_id, display_name, kind) values (%L, 'x', 'robot')$f$, (select org_a from fx)),
  '23514', null, 'person kind is validated');
select throws_ok(
  format($f$insert into public.person_relations (org_id, person_id, related_person_id, relation_type) values (%L, %L, %L, 'family')$f$,
    (select org_a from fx), (select person_1 from fx), (select person_1 from fx)),
  '23514', null, 'a person cannot relate to themself');
insert into public.person_relations (org_id, person_id, related_person_id, relation_type)
values ((select org_a from fx), (select person_1 from fx), (select person_2 from fx), 'guardian');
select throws_ok(
  format($f$insert into public.person_relations (org_id, person_id, related_person_id, relation_type) values (%L, %L, %L, 'guardian')$f$,
    (select org_a from fx), (select person_1 from fx), (select person_2 from fx)),
  '23505', null, 'duplicate relation refused');

-- profiles and current_profile_id()
insert into auth.users (id, email) values ((select u1 from fx), 'p1@example.test'), ((select u2 from fx), 'p2@example.test');
insert into public.profiles (id, org_id, auth_user_id, person_id) values (core.ulid(), (select org_a from fx), (select u1 from fx), (select person_1 from fx));
insert into public.profiles (id, org_id, auth_user_id, is_active) values (core.ulid(), (select org_a from fx), (select u2 from fx), false);
select throws_ok(
  format($f$insert into public.profiles (org_id, auth_user_id) values (%L, %L)$f$, (select org_a from fx), (select u1 from fx)),
  '23505', null, 'one profile per auth user');

select set_config('request.jwt.claims', json_build_object('sub', (select u1 from fx), 'role', 'authenticated')::text, true);
select is(core.current_profile_id(), (select id from public.profiles where auth_user_id = (select u1 from fx)), 'current_profile_id finds the active profile');
select set_config('request.jwt.claims', json_build_object('sub', (select u2 from fx), 'role', 'authenticated')::text, true);
select is(core.current_profile_id(), null, 'an inactive profile is not current');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
select is(core.current_profile_id(), null, 'an unknown user has no profile');

-- stamps use the current profile once there is one
select set_config('request.jwt.claims', json_build_object('sub', (select u1 from fx), 'role', 'authenticated')::text, true);
insert into public.org_units (org_id, code, name) values ((select org_a from fx), 'second', 'Second');
select is((select created_by from public.org_units where code = 'second'), (select id from public.profiles where auth_user_id = (select u1 from fx)), 'created_by is the caller profile');

-- anon sees none of them
set local role anon;
select throws_ok($$select count(*) from public.persons$$, '42501', null, 'anon has no privilege on persons');
reset role;

select * from finish();
rollback;
