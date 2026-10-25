begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org, gen_random_uuid() as u1,
  core.ulid() as per1, core.ulid() as prof1, core.ulid() as mem1;
grant select on fx to public;
insert into auth.users (id, email) values ((select u1 from fx), 'detail-1@members.example.test');
insert into public.persons (id, org_id, display_name, date_of_birth) values ((select per1 from fx), (select org from fx), 'Fake Detail Person', '1990-02-03');
insert into public.profiles (id, org_id, auth_user_id, person_id) values ((select prof1 from fx), (select org from fx), (select u1 from fx), (select per1 from fx));
insert into public.org_members (org_id, profile_id, role_id)
  values ((select org from fx), (select prof1 from fx), (select id from public.roles where org_id = (select org from fx) and code = 'pending_member'));
insert into public.members (id, org_id, person_id, profile_id, member_no, status) values ((select mem1 from fx), (select org from fx), (select per1 from fx), (select prof1 from fx), 'CPC-2026-97101', 'imported');
insert into public.member_access (org_id, member_id, must_change_password) values ((select org from fx), (select mem1 from fx), false);
select core.member_login_succeeded((select mem1 from fx));
create temp table brgy as select code from public.psgc_areas where level = 'barangay' and region_code = '130000000' order by code limit 1;
grant select on brgy to public;

-- ---- columns and checks
select throws_ok($$update public.persons set suffix = 'Esq' where display_name = 'Fake Detail Person'$$, '23514', null, 'a suffix must be from the list');
select throws_ok($$update public.persons set gender = 'other' where display_name = 'Fake Detail Person'$$, '23514', null, 'gender is male or female');
select throws_ok(format($f$update public.persons set middle_name = %L where display_name = 'Fake Detail Person'$f$, repeat('x', 61)), '23514', null, 'a middle name is at most 60 characters');
select is(has_column_privilege('authenticated', 'public.persons', 'middle_name', 'update'), true, 'staff-style direct edits still use column grants (policies decide who)');

-- ---- the profile function with the new fields
select pg_temp.as_user((select u1 from fx));
set local role authenticated;
select lives_ok(format($f$select public.update_my_profile('Fake Detail Person', '09171234567', 'fake.profile@example.test', 'Block 1', %L,
  '  Fake  ', ' Middle ', 'Person', 'Jr.', 'female', 'Fake Contact', 'Parent', '0918 765 4321')$f$, (select code from brgy)), 'all the details can be saved');
select is((select first_name from public.my_access_state()), 'Fake', 'the first name is saved, tidied');
select is((select middle_name from public.my_access_state()), 'Middle', 'and the middle name');
select is((select last_name from public.my_access_state()), 'Person', 'and the last name');
select is((select suffix from public.my_access_state()), 'Jr.', 'and the suffix');
select is((select gender from public.my_access_state()), 'female', 'and the gender');
select is((select emergency_name from public.my_access_state()), 'Fake Contact', 'and the emergency contact name');
select is((select emergency_relationship from public.my_access_state()), 'Parent', 'relationship');
select is((select emergency_phone from public.my_access_state()), '0918 765 4321', 'and number');
select is((select date_of_birth from public.my_access_state()), '1990-02-03'::date, 'the birth date is returned for display');
select is((select profile_complete from public.my_access_state()), true, 'the profile is complete');

-- null keeps, empty string clears
select lives_ok(format($f$select public.update_my_profile('Fake Detail Person', '09171234567', 'fake.profile@example.test', 'Block 1', %L)$f$, (select code from brgy)), 'the original five arguments still work');
select is((select middle_name from public.my_access_state()), 'Middle', 'and leave the other details as they were');
select lives_ok(format($f$select public.update_my_profile('Fake Detail Person', '09171234567', 'fake.profile@example.test', 'Block 1', %L, null, '', null, '', '', '', '', '')$f$, (select code from brgy)), 'empty strings clear optional details');
select is((select middle_name from public.my_access_state()), null, 'the middle name is cleared');
select is((select suffix from public.my_access_state()), null, 'the suffix is cleared');
select is((select emergency_name from public.my_access_state()), null, 'the emergency contact is cleared');
select is((select first_name from public.my_access_state()), 'Fake', 'while null left the first name alone');

-- validation
select throws_ok(format($f$select public.update_my_profile('Fake Detail Person', '09171234567', 'fake.profile@example.test', null, %L, null, null, null, 'Esq')$f$, (select code from brgy)), '22023', null, 'an unknown suffix is refused');
select throws_ok(format($f$select public.update_my_profile('Fake Detail Person', '09171234567', 'fake.profile@example.test', null, %L, null, null, null, null, 'x')$f$, (select code from brgy)), '22023', null, 'an unknown gender is refused');
select throws_ok(format($f$select public.update_my_profile('Fake Detail Person', '09171234567', 'fake.profile@example.test', null, %L, null, null, null, null, null, 'Only A Name', null, '')$f$, (select code from brgy)), '22023', null, 'an emergency contact needs a number with the name');
select throws_ok(format($f$select public.update_my_profile('Fake Detail Person', '09171234567', 'fake.profile@example.test', null, %L, null, null, null, null, null, 'Name', null, '12')$f$, (select code from brgy)), '22023', null, 'a short emergency number is refused');
select throws_ok(format($f$select public.update_my_profile('Fake Detail Person', '09171234567', 'fake.profile@example.test', null, %L, %L)$f$, (select code from brgy), repeat('y', 61)), '22023', null, 'an over-long name part is refused');
reset role;

-- audit masks the emergency contact
select is((select count(*)::int from core.audit_log where table_name = 'public.persons' and record_id = (select per1 from fx)
  and (new_values ->> 'emergency_name' not in ('***') or new_values ->> 'emergency_phone' not in ('***'))), 0, 'the emergency contact is masked in audit_log');

select * from finish();
rollback;
