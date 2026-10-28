begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create function pg_temp.mk(p_org text, p_role text, p_unit text default null) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); rid text;
begin
  select id into rid from public.roles where org_id = p_org and code = p_role;
  insert into auth.users (id, email) values (u, p_role || '-' || u || '@example.test');
  insert into public.persons (id, org_id, display_name) values (per, p_org, 'Fake ' || p_role);
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, p_org, u, per);
  insert into public.org_members (org_id, profile_id, unit_id, role_id) values (p_org, pid, p_unit, rid);
  return u;
end $$;

-- ---- anonymous access is denied everywhere
select is(
  (select count(*)::int from pg_class c where c.relkind = 'r' and c.relnamespace in ('public'::regnamespace, 'core'::regnamespace)
    and (has_table_privilege('anon', c.oid, 'select') or has_table_privilege('anon', c.oid, 'insert')
      or has_table_privilege('anon', c.oid, 'update') or has_table_privilege('anon', c.oid, 'delete'))),
  0, 'anon has no privilege on any table in public or core');
-- except the public pages' read-only functions (1330, 1540, 1550, 1750), which return only what the club publishes,
-- and the yes/no photo check the public Members page's storage policy needs (1750)
select is(
  (select count(*)::int from pg_proc p where p.pronamespace in ('public'::regnamespace, 'core'::regnamespace)
    and has_function_privilege('anon', p.oid, 'execute')
    and p.oid::regprocedure::text not in ('club_home_stats()', 'public_landing_info()', 'public_results()',
                                          'public_leaderboard(text)', 'public_members()',
                                          'core.public_member_photo(text)')),
  0, 'anon cannot execute any function in public or core except the public page functions');
select is(has_function_privilege('authenticated', 'public.my_permissions()', 'execute'), true, 'authenticated can call my_permissions');
select is(has_function_privilege('authenticated', 'core.has_permission(text,text,text)', 'execute'), true, 'authenticated can evaluate policies (has_permission)');
select is(has_function_privilege('authenticated', 'core.attach_standard(regclass,text)', 'execute'), false, 'authenticated cannot run migration helpers');
select is(has_function_privilege('authenticated', 'core.write_audit(text,text,text,text,jsonb,jsonb)', 'execute'), false, 'authenticated cannot write audit rows directly');
select is(has_function_privilege('authenticated', 'core.next_number(text,text,text)', 'execute'), false, 'authenticated cannot bump counters directly');
select is(has_function_privilege('authenticated', 'core.idem_begin(text,text,text,jsonb)', 'execute'), false, 'authenticated cannot call idempotency helpers directly');

-- ---- authenticated: never delete or truncate; no write on security tables
select is(
  (select count(*)::int from pg_class c where c.relkind = 'r' and c.relnamespace = 'public'::regnamespace
    and (has_table_privilege('authenticated', c.oid, 'delete') or has_table_privilege('authenticated', c.oid, 'truncate'))),
  0, 'authenticated cannot delete or truncate any public table');
select is(
  (select count(*)::int from pg_class c where c.relkind = 'r' and c.relnamespace = 'core'::regnamespace
    and (has_any_column_privilege('authenticated', c.oid, 'select') or has_any_column_privilege('authenticated', c.oid, 'insert')
      or has_any_column_privilege('authenticated', c.oid, 'update'))),
  0, 'authenticated has no access to core tables');
select is(
  (select count(*)::int from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname in
      ('orgs', 'profiles', 'permissions', 'roles', 'role_permissions', 'org_members', 'notifications')
    and (has_any_column_privilege('authenticated', c.oid, 'insert') or has_any_column_privilege('authenticated', c.oid, 'update'))),
  0, 'security and service-written tables are read-only for clients');
select is(has_column_privilege('authenticated', 'public.persons', 'display_name', 'update'), true, 'clients may update ordinary columns');
select is(
  (select count(*)::int from unnest(array['id', 'org_id', 'unit_id', 'created_at', 'created_by', 'updated_at', 'updated_by', 'version', 'deleted_at', 'deleted_by', 'delete_reason']) c
    where has_column_privilege('authenticated', 'public.persons', c, 'update')),
  0, 'clients cannot update id, org, unit, stamps, version or deleted_* columns');
select is(
  (select count(*)::int from unnest(array['created_at', 'created_by', 'updated_at', 'updated_by', 'version', 'deleted_at', 'deleted_by', 'delete_reason']) c
    where has_column_privilege('authenticated', 'public.persons', c, 'insert')),
  0, 'clients cannot supply stamps, version or deleted_* on insert');
select is(has_column_privilege('authenticated', 'public.persons', 'version', 'select'), true, 'clients can read version (optimistic concurrency)');

-- ---- new objects are private by default
create table public.t_new (id text primary key, org_id text);
create function public.t_new_fn() returns int language sql as 'select 1';
select is(has_table_privilege('anon', 'public.t_new', 'select'), false, 'a new table is not readable by anon');
select is(has_table_privilege('authenticated', 'public.t_new', 'select'), false, 'a new table is not readable by authenticated');
select is(has_function_privilege('anon', 'public.t_new_fn()', 'execute'), false, 'a new function is not callable by anon');
select is(has_function_privilege('authenticated', 'public.t_new_fn()', 'execute'), false, 'a new function is not callable by authenticated');

-- ---- tenant isolation and escalation attempts, with real rows
create temp table fx as select (select id from public.orgs where code = 'cpc') as org_a, core.ulid() as org_b;
grant select on fx to public;
insert into public.orgs (id, code, name) values ((select org_b from fx), 'club-b', 'Club B');
insert into public.roles (org_id, code, name) values ((select org_b from fx), 'member', 'Member');
insert into public.role_permissions (org_id, role_id, permission_id)
  select (select org_b from fx), r.id, pe.id from public.roles r, public.permissions pe
  where r.org_id = (select org_b from fx) and pe.code in ('members.read', 'members.create', 'members.update', 'bookings.create');
create temp table us(role text primary key, u uuid);
grant select on us to public;
insert into us values ('a_admin', pg_temp.mk((select org_a from fx), 'admin'));
insert into us values ('a_member', pg_temp.mk((select org_a from fx), 'member'));
insert into us values ('b_member', pg_temp.mk((select org_b from fx), 'member'));
create temp table pid as select id from public.persons where org_id = (select org_b from fx);
grant select on pid to public;
create temp table opts as select id from public.persons where org_id = (select org_a from fx) and display_name = 'Fake admin';
grant select on opts to public;

select pg_temp.as_user((select u from us where role = 'a_admin'));
set local role authenticated;
select is((select count(*)::int from public.persons where id = (select id from pid)), 0, 'an admin of org A cannot read a person of org B, even by exact id');
select is((select count(*)::int from public.orgs where id = (select org_b from fx)), 0, 'an admin of org A cannot see org B');
select throws_ok(
  format($f$insert into public.persons (org_id, display_name) values (%L, 'intruder')$f$, (select org_b from fx)),
  '42501', null, 'an admin of org A cannot create a person in org B');
select lives_ok(
  format($f$update public.persons set display_name = 'hijacked' where id = %L$f$, (select id from pid)),
  'an update aimed at a person of org B runs but finds no visible row');
reset role;

select pg_temp.as_user((select u from us where role = 'a_member'));
set local role authenticated;
select throws_ok($$update public.profiles set is_active = false$$, '42501', null, 'a user cannot change profile status');
select throws_ok($$update public.org_members set role_id = role_id$$, '42501', null, 'a user cannot change their own role or unit');
select throws_ok($$update public.org_members set unit_id = null$$, '42501', null, 'a user cannot change their unit');
select throws_ok($$delete from public.org_members$$, '42501', null, 'a user cannot delete a membership');
select throws_ok($$insert into public.org_members (org_id, profile_id, role_id) select org_id, profile_id, role_id from public.org_members$$, '42501', null, 'a user cannot add a membership');
select throws_ok($$update public.persons set version = 99$$, '42501', null, 'a user cannot write the version column');
select throws_ok($$update public.persons set org_id = core.ulid()$$, '42501', null, 'a user cannot move a person to another org');
select throws_ok($$update public.persons set deleted_at = now()$$, '42501', null, 'a user cannot soft-delete directly');
select throws_ok($$insert into public.persons (org_id, display_name, created_by) values (core.ulid(), 'x', 'someone')$$, '42501', null, 'a user cannot forge created_by');
select throws_ok($$insert into public.roles (org_id, code, name) values (core.ulid(), 'root', 'Root')$$, '42501', null, 'a user cannot create roles');
select throws_ok($$insert into public.role_permissions (org_id, role_id, permission_id) values ('x', 'y', 'z')$$, '42501', null, 'a user cannot grant permissions');
select throws_ok($$select * from core.audit_log$$, '42501', null, 'a user cannot read the audit log');
reset role;
select is((select count(*)::int from public.persons where org_id = (select org_b from fx) and display_name = 'hijacked'), 0, 'the person of org B was not changed');
select is(
  (select r.code from public.org_members m join public.roles r on r.id = m.role_id join public.profiles p on p.id = m.profile_id
    where p.auth_user_id = (select u from us where role = 'a_member')),
  'member', 'the member is still a member after every escalation attempt');

-- ---- every client-reachable table has RLS and at least one policy
select is(
  (select count(*)::int from pg_class c where c.relkind = 'r' and c.relnamespace = 'public'::regnamespace
    and c.relname not like 't\_%' and not c.relrowsecurity),
  0, 'RLS is on for every real public table');
select is(
  (select count(*)::int from pg_class c where c.relkind = 'r' and c.relnamespace = 'public'::regnamespace
    and c.relname not like 't\_%'
    -- push_subscriptions hold device keys: no policy at all, so the browser can never read them (1560)
    and c.relname not in ('push_subscriptions')
    and not exists (select 1 from pg_policies p where p.schemaname = 'public' and p.tablename = c.relname and p.cmd in ('SELECT', 'INSERT'))),
  0, 'every real public table has a select or insert policy');
select is(
  (select count(*)::int from pg_policies p where p.schemaname = 'public' and p.cmd = 'DELETE'),
  0, 'there is no delete policy anywhere');
select is(
  (select count(*)::int from pg_policies p where p.schemaname = 'public' and p.qual = 'true' and p.tablename <> 'permissions'),
  0, 'no using (true) policy except the permission catalog');

select * from finish();
rollback;
