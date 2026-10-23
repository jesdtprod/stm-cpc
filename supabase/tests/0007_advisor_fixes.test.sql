begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

-- the public RPC is a SECURITY INVOKER wrapper; the privileged lookup stays in core
select is((select prosecdef from pg_proc where oid = 'public.my_permissions()'::regprocedure), false, 'public.my_permissions is SECURITY INVOKER');
select is((select prosecdef from pg_proc where oid = 'core.my_permissions()'::regprocedure), true, 'core.my_permissions is SECURITY DEFINER');
select is(
  (select count(*)::int from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prosecdef
    and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))),
  0, 'no SECURITY DEFINER function in public is callable by anon or authenticated');

select is(
  (select count(*)::int from pg_policies where schemaname = 'public' and tablename = 'persons' and cmd = 'SELECT'),
  1, 'persons has a single select policy');
select is(
  (select count(*)::int from pg_policies where schemaname = 'core' and policyname = 'deny_clients'),
  3, 'the three internal tables have an explicit deny policy');

-- behaviour is unchanged
create temp table fx as select (select id from public.orgs where code = 'cpc') as org, gen_random_uuid() as u1, gen_random_uuid() as u2, core.ulid() as p1, core.ulid() as p2;
grant select on fx to public;
insert into auth.users (id, email) values ((select u1 from fx), 'm1@example.test'), ((select u2 from fx), 'm2@example.test');
insert into public.persons (id, org_id, display_name) values ((select p1 from fx), (select org from fx), 'Fake One'), ((select p2 from fx), (select org from fx), 'Fake Two');
insert into public.profiles (org_id, auth_user_id, person_id) values ((select org from fx), (select u1 from fx), (select p1 from fx)), ((select org from fx), (select u2 from fx), (select p2 from fx));
insert into public.org_members (org_id, profile_id, role_id)
  select (select org from fx), p.id, (select id from public.roles where code = 'member' and org_id = (select org from fx))
  from public.profiles p where p.auth_user_id = (select u1 from fx);

select pg_temp.as_user((select u1 from fx));
set local role authenticated;
select is((select count(*)::int from public.my_permissions()), 3, 'my_permissions still returns the member grants');
select is((select count(*)::int from public.persons), 1, 'a member still sees only their own person');
reset role;

select * from finish();
rollback;
