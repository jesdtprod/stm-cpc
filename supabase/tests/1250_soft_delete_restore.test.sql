begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as cat1, core.ulid() as cat2, core.ulid() as cat3, core.ulid() as lad,
  core.ulid() as k1, core.ulid() as k2, core.ulid() as k3, core.ulid() as k4, core.ulid() as k5, core.ulid() as k6,
  core.ulid() as k7, core.ulid() as k8, core.ulid() as k9;
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

insert into public.categories (id, org_id, code, name) values
  ((select cat1 from fx), (select org from fx), 't7-free', 'T7 Free'),
  ((select cat2 from fx), (select org from fx), 't7-used', 'T7 Used');
insert into public.rank_ladders (id, org_id, category_id) values ((select lad from fx), (select org from fx), (select cat2 from fx));

-- ---- access
select is(has_function_privilege('anon', 'public.soft_delete(text,text,text,text)', 'execute'), false, 'anonymous callers cannot delete');
select is(has_function_privilege('anon', 'public.restore_row(text,text,text)', 'execute'), false, 'nor restore');
select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
select throws_ok(format($f$select public.soft_delete('categories', %L, 'no longer used', %L)$f$, (select cat1 from fx), (select k1 from fx)), '42501', null, 'a member cannot delete a category');
reset role;

-- ---- a manager deletes and restores
select pg_temp.as_user((select u from us where role = 'manager'));
set local role authenticated;
select throws_ok(format($f$select public.soft_delete('categories', %L, '', %L)$f$, (select cat1 from fx), (select k2 from fx)), '22023', 'a reason is required', 'a reason is required');
select throws_ok(format($f$select public.soft_delete('settings', %L, 'no longer used', %L)$f$, (select cat1 from fx), (select k2 from fx)), '22023', null, 'only listed tables can be deleted this way');
select throws_ok(format($f$select public.soft_delete('categories', %L, 'no longer used', %L)$f$, core.ulid(), core.ulid()), '22023', 'record not found', 'an unknown record is refused');
select throws_ok(format($f$select public.soft_delete('categories', %L, 'no longer used', %L)$f$, (select cat2 from fx), (select k3 from fx)), '23503', null, 'a category that still has a ladder cannot be deleted');
create temp table d1 as select public.soft_delete('categories', (select cat1 from fx), 'no longer used', (select k4 from fx)) as r;
reset role;
grant select on d1 to public;
select is((select r ->> 'ok' from d1), 'true', 'an unused category can be deleted');
select isnt((select deleted_at from public.categories where id = (select cat1 from fx)), null, 'it is marked deleted');
select is((select delete_reason from public.categories where id = (select cat1 from fx)), 'no longer used', 'with the reason');
select is((select deleted_by is not null from public.categories where id = (select cat1 from fx)), true, 'and who did it');
select is((select count(*)::int from core.audit_log where action = 'soft_delete' and record_id = (select cat1 from fx)), 1, 'the deletion is in the audit log');

set local role authenticated;
select is((select public.soft_delete('categories', (select cat1 from fx), 'no longer used', (select k4 from fx))), (select r from d1), 'the same key replays the first answer');
select is((select (public.soft_delete('categories', (select cat1 from fx), 'no longer used', (select k5 from fx))) ->> 'unchanged'), 'true', 'deleting again changes nothing');

-- a live category with the same code blocks the restore
reset role;
insert into public.categories (id, org_id, code, name) values ((select cat3 from fx), (select org from fx), 't7-free', 'T7 Free again');
select pg_temp.as_user((select u from us where role = 'manager'));
set local role authenticated;
select throws_ok(format($f$select public.restore_row('categories', %L, %L)$f$, (select cat1 from fx), (select k6 from fx)), '23505', null, 'a clash with a live category is refused');
reset role;
update public.categories set code = 't7-other' where id = (select cat3 from fx);
select pg_temp.as_user((select u from us where role = 'manager'));
set local role authenticated;
select is((select public.restore_row('categories', (select cat1 from fx), (select k7 from fx)) ->> 'ok'), 'true', 'without the clash it comes back');
select is((select (public.restore_row('categories', (select cat1 from fx), (select k8 from fx))) ->> 'unchanged'), 'true', 'restoring again changes nothing');
reset role;
select is((select deleted_at is null and deleted_by is null and delete_reason is null from public.categories where id = (select cat1 from fx)), true, 'the deleted marks are cleared');

-- a client cannot set the deleted marks itself
select pg_temp.as_user((select u from us where role = 'manager'));
set local role authenticated;
select throws_ok(format($f$update public.categories set deleted_at = now() where id = %L$f$, (select cat1 from fx)), '42501', null, 'a direct update of deleted_at is refused');
reset role;

select * from finish();
rollback;
