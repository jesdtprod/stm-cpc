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
insert into auth.users (id, email) values ((select u1 from fx), 'dupr-1@members.example.test');
insert into public.persons (id, org_id, display_name, date_of_birth) values ((select per1 from fx), (select org from fx), 'Fake DUPR Person', '1990-02-03');
insert into public.profiles (id, org_id, auth_user_id, person_id) values ((select prof1 from fx), (select org from fx), (select u1 from fx), (select per1 from fx));
insert into public.org_members (org_id, profile_id, role_id)
  values ((select org from fx), (select prof1 from fx), (select id from public.roles where org_id = (select org from fx) and code = 'pending_member'));
insert into public.members (id, org_id, person_id, profile_id, member_no, status) values ((select mem1 from fx), (select org from fx), (select per1 from fx), (select prof1 from fx), 'CPC-2026-97101', 'imported');
insert into public.member_access (org_id, member_id, must_change_password) values ((select org from fx), (select mem1 from fx), false);
select core.member_login_succeeded((select mem1 from fx));
create temp table brgy as select code from public.psgc_areas where level = 'barangay' and region_code = '130000000' order by code limit 1;
grant select on brgy to public;


-- A second fake record checks uniqueness and ownership without any real member data.
insert into public.persons (org_id, display_name, dupr_id)
values ((select org from fx), 'Fake Other DUPR Person', 'TEST02');
select is(has_function_privilege('anon', 'public.my_access_state()', 'execute'), false, 'anonymous users cannot read the private profile');
select is(has_function_privilege('anon', 'public.update_my_profile(text,text,text,text,text,text,text,text,text,text,text,text,text,date,text)', 'execute'), false, 'anonymous users cannot save a profile');
select is(has_column_privilege('authenticated', 'public.persons', 'dupr_id', 'update'), false, 'the new column cannot be updated directly');
select pg_temp.as_user((select u1 from fx));
set local role authenticated;
select lives_ok(format($f$select public.update_my_profile('Fake DUPR Person', '09171234567', 'fake.dupr@example.test', null, %L, p_dupr_id => ' test01 ')$f$, (select code from brgy)), 'a member saves their own DUPR ID');
select is((select dupr_id from public.my_access_state()), 'TEST01', 'the private profile returns the normalized saved ID');
select lives_ok(format($f$select public.update_my_profile('Fake DUPR Person', '09171234567', 'fake.dupr@example.test', null, %L, p_dupr_id => ' test01 ')$f$, (select code from brgy)), 'retrying the same save succeeds');
select lives_ok(format($f$select public.update_my_profile('Fake DUPR Person', '09171234567', 'fake.dupr@example.test', null, %L)$f$, (select code from brgy)), 'older callers can omit the new argument');
select is((select dupr_id from public.my_access_state()), 'TEST01', 'an omitted argument preserves the ID');
select throws_ok(format($f$select public.update_my_profile('Fake DUPR Person', '09171234567', 'fake.dupr@example.test', null, %L, p_dupr_id => '<script>')$f$, (select code from brgy)), '22023', null, 'markup and punctuation are rejected');
select throws_ok(format($f$select public.update_my_profile('Fake DUPR Person', '09171234567', 'fake.dupr@example.test', null, %L, p_dupr_id => %L)$f$, (select code from brgy), repeat('A', 33)), '22023', null, 'overlong IDs are rejected');
select throws_ok(format($f$select public.update_my_profile('Fake DUPR Person', '09171234567', 'fake.dupr@example.test', null, %L, p_dupr_id => 'test02')$f$, (select code from brgy)), '23505', null, 'an ID on another active record is rejected');
select is((select dupr_id from public.my_access_state()), 'TEST01', 'failed changes preserve the original ID');
select lives_ok(format($f$select public.update_my_profile('Fake DUPR Person', '09171234567', 'fake.dupr@example.test', null, %L, p_dupr_id => 'TEST03')$f$, (select code from brgy)), 'the member can replace their ID');
select is((select dupr_id from public.my_access_state()), 'TEST03', 'the replacement persists');
select lives_ok(format($f$select public.update_my_profile('Fake DUPR Person', '09171234567', 'fake.dupr@example.test', null, %L, p_dupr_id => '   ')$f$, (select code from brgy)), 'the member can clear the optional ID');
select is((select dupr_id from public.my_access_state()), null, 'blank is stored as null');
reset role;
select is((select dupr_id from public.persons where display_name = 'Fake Other DUPR Person'), 'TEST02', 'saving never changes another person');
-- Use the existing privileged test setup to suspend the fake member.
update public.members set status = 'active' where id = (select mem1 from fx);
update public.members set status = 'suspended' where id = (select mem1 from fx);
set local role authenticated;
select throws_ok(format($f$select public.update_my_profile('Fake DUPR Person', '09171234567', 'fake.dupr@example.test', null, %L, p_dupr_id => 'TEST04')$f$, (select code from brgy)), '42501', null, 'a suspended member cannot edit the ID');
reset role;
select * from finish();
rollback;
