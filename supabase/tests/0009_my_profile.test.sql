begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create temp table fx as select (select id from public.orgs where code = 'cpc') as org, gen_random_uuid() as u1, gen_random_uuid() as u2, core.ulid() as per1;
grant select on fx to public;
insert into auth.users (id, email) values ((select u1 from fx), 'p1@example.test'), ((select u2 from fx), 'p2@example.test');
insert into public.persons (id, org_id, display_name) values ((select per1 from fx), (select org from fx), 'Fake One');
insert into public.profiles (id, org_id, auth_user_id, person_id) values ('01H0000000000000000000PRF1', (select org from fx), (select u1 from fx), (select per1 from fx));
insert into public.profiles (org_id, auth_user_id, is_active) values ((select org from fx), (select u2 from fx), false);

select is(has_function_privilege('anon', 'public.my_profile()', 'execute'), false, 'anon cannot call my_profile');
select is(has_function_privilege('authenticated', 'public.my_profile()', 'execute'), true, 'authenticated can call my_profile');
select is((select prosecdef from pg_proc where oid = 'public.my_profile()'::regprocedure), false, 'the public wrapper is SECURITY INVOKER');

select set_config('request.jwt.claims', json_build_object('sub', (select u1 from fx), 'role', 'authenticated')::text, true);
set local role authenticated;
select is((select profile_id from public.my_profile()), '01H0000000000000000000PRF1', 'returns the caller profile id');
select is((select org_id from public.my_profile()), (select org from fx), 'returns the caller org');
reset role;

select set_config('request.jwt.claims', json_build_object('sub', (select u2 from fx), 'role', 'authenticated')::text, true);
set local role authenticated;
select is((select count(*)::int from public.my_profile()), 0, 'an inactive profile returns nothing');
reset role;

select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
set local role authenticated;
select is((select count(*)::int from public.my_profile()), 0, 'an unknown user returns nothing');
reset role;

select * from finish();
rollback;
