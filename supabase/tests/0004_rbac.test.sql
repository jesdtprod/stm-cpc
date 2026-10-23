begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

-- helpers (temp, rolled back)
create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create function pg_temp.mk(p_role text, p_unit text default null) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); org text; rid text;
begin
  select id into org from public.orgs where code = 'cpc';
  select id into rid from public.roles where org_id = org and code = p_role;
  insert into auth.users (id, email) values (u, p_role || '-' || u || '@example.test');
  insert into public.persons (id, org_id, display_name) values (per, org, 'Fake ' || p_role);
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, org, u, per);
  insert into public.org_members (org_id, profile_id, unit_id, role_id) values (org, pid, p_unit, rid);
  return u;
end $$;

create function pg_temp.can(p_user uuid, p_code text, p_unit text default null) returns boolean language plpgsql as $$
declare v_org text;
begin
  perform pg_temp.as_user(p_user);
  select id into v_org from public.orgs where orgs.code = 'cpc';
  return core.has_permission(v_org, p_unit, p_code);
end $$;

create temp table cx as select (select id from public.orgs where code = 'cpc') as org, core.ulid() as unit1, core.ulid() as unit2, core.ulid() as org_b;
grant select on cx to public;
insert into public.org_units (id, org_id, code, name) values ((select unit1 from cx), (select org from cx), 'u1', 'Unit 1'), ((select unit2 from cx), (select org from cx), 'u2', 'Unit 2');
insert into public.orgs (id, code, name) values ((select org_b from cx), 'other-club', 'Other Club');

-- seed
select is((select count(*)::int from public.permissions where deleted_at is null), 33, 'permission catalog seeded (33 codes)');
select is((select count(*)::int from public.roles where org_id = (select org from cx)), 6, 'six default roles seeded');
select is(
  (select count(*)::int from public.role_permissions rp join public.roles r on r.id = rp.role_id where r.code = 'admin'),
  (select count(*)::int from public.permissions), 'admin holds every permission');
select is((select count(*)::int from public.role_permissions rp join public.roles r on r.id = rp.role_id where r.code = 'pending_member'), 0, 'pending member holds no permission');
create temp table seed_before as select (select count(*) from public.permissions) p, (select count(*) from public.roles) r, (select count(*) from public.role_permissions) rp, (select count(*) from public.orgs where code = 'cpc') o;
select core.seed_catalog();
select is(
  (select row((select count(*) from public.permissions), (select count(*) from public.roles), (select count(*) from public.role_permissions), (select count(*) from public.orgs where code = 'cpc'))::text),
  (select row(p, r, rp, o)::text from seed_before), 'seed is idempotent');

create temp table us(role text primary key, u uuid);
grant select on us to public;
insert into us select r, pg_temp.mk(r) from unnest(array['pending_member', 'member', 'referee', 'front_desk', 'manager', 'admin']) r;

-- permission matrix per role
select is(pg_temp.can((select u from us where role = 'member'), 'bookings.create'), true, 'member can request bookings');
select is(pg_temp.can((select u from us where role = 'member'), 'members.approve'), false, 'member cannot approve members');
select is(pg_temp.can((select u from us where role = 'member'), 'courts.manage'), false, 'member cannot manage courts');
select is(pg_temp.can((select u from us where role = 'referee'), 'scores.enter'), true, 'referee can enter scores');
select is(pg_temp.can((select u from us where role = 'referee'), 'bookings.create'), false, 'referee cannot book');
select is(pg_temp.can((select u from us where role = 'front_desk'), 'bookings.checkin'), true, 'front desk can check in');
select is(pg_temp.can((select u from us where role = 'front_desk'), 'bookings.approve'), false, 'front desk cannot approve bookings');
select is(pg_temp.can((select u from us where role = 'manager'), 'courts.manage'), true, 'manager can manage courts');
select is(pg_temp.can((select u from us where role = 'manager'), 'members.approve'), false, 'manager cannot approve members');
select is(pg_temp.can((select u from us where role = 'manager'), 'roles.manage'), false, 'manager cannot manage roles');
select is(pg_temp.can((select u from us where role = 'admin'), 'members.approve'), true, 'admin can approve members');
select is(pg_temp.can((select u from us where role = 'admin'), 'roles.manage'), true, 'admin can manage roles');
select is(pg_temp.can((select u from us where role = 'admin'), 'audit.read'), true, 'admin can read the audit log');
select is(pg_temp.can((select u from us where role = 'pending_member'), 'bookings.create'), false, 'pending member cannot book');
select is(pg_temp.can((select u from us where role = 'pending_member'), 'members.read'), false, 'pending member cannot read members');
select is(core.has_permission((select org_b from cx), null, 'bookings.create'), false, 'permission does not cross into another org');
select is(pg_temp.can(gen_random_uuid(), 'bookings.create'), false, 'an unknown user has no permission');

-- unit scoping
create temp table uu as select pg_temp.mk('manager', (select unit1 from cx)) as u;
grant select on uu to public;
select is(pg_temp.can((select u from uu), 'courts.manage', (select unit1 from cx)), true, 'unit-bound manager has the permission in their unit');
select is(pg_temp.can((select u from uu), 'courts.manage', (select unit2 from cx)), false, 'unit-bound manager has no permission in another unit');
select is(pg_temp.can((select u from uu), 'courts.manage', null), false, 'unit-bound manager has no org-wide permission');
select is(pg_temp.can((select u from us where role = 'manager'), 'courts.manage', (select unit2 from cx)), true, 'org-wide manager covers every unit');

-- inactive and removed access disappears at once
update public.org_members set is_active = false where profile_id = (select id from public.profiles where auth_user_id = (select u from us where role = 'member'));
select is(pg_temp.can((select u from us where role = 'member'), 'bookings.create'), false, 'inactive membership loses access');
update public.org_members set is_active = true where profile_id = (select id from public.profiles where auth_user_id = (select u from us where role = 'member'));
select is(pg_temp.can((select u from us where role = 'member'), 'bookings.create'), true, 'reactivated membership regains access');
update public.profiles set is_active = false where auth_user_id = (select u from us where role = 'member');
select is(pg_temp.can((select u from us where role = 'member'), 'bookings.create'), false, 'inactive profile loses access');
update public.profiles set is_active = true where auth_user_id = (select u from us where role = 'member');
select set_config('core.rpc', 'on', true);
update public.role_permissions set deleted_at = now(), delete_reason = 'test'
 where role_id = (select id from public.roles where code = 'member' and org_id = (select org from cx))
   and permission_id = (select id from public.permissions where code = 'bookings.create');
select set_config('core.rpc', 'off', true);
select is(pg_temp.can((select u from us where role = 'member'), 'bookings.create'), false, 'removing a permission from a role removes access');
select is(pg_temp.can((select u from us where role = 'member'), 'payments.submit'), true, 'other permissions of the role stay');

-- RLS as the member
select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
select is((select count(*)::int from public.org_members), 1, 'member sees only their own membership');
select is((select count(*)::int from public.profiles), 1, 'member sees only their own profile');
select is((select count(*)::int from public.persons), 1, 'member sees only their own person');
select is((select count(*)::int from public.orgs), 1, 'member sees only their own org');
select is((select count(*)::int from public.org_units), 2, 'member sees the units of their org');
select is((select count(*)::int from public.role_permissions), 0, 'member cannot read role bundles');
select is((select count(*)::int from public.permissions), 33, 'permission catalog is readable');
select is((select count(*)::int from public.my_permissions()), 2, 'my_permissions lists the member''s grants');
select throws_ok(
  format($f$insert into public.org_members (org_id, profile_id, role_id) values (%L, core.current_profile_id(), %L)$f$,
    (select org from cx), (select id from public.roles where code = 'admin' and org_id = (select org from cx))),
  '42501', null, 'member cannot add a membership');
select throws_ok(
  format($f$update public.org_members set role_id = %L$f$, (select id from public.roles where code = 'admin' and org_id = (select org from cx))),
  '42501', null, 'a role-change attempt is refused (no update privilege)');
reset role;
select is(
  (select r.code from public.org_members m join public.roles r on r.id = m.role_id
    where m.profile_id = (select id from public.profiles where auth_user_id = (select u from us where role = 'member'))),
  'member', 'the member role did not change');

-- RLS as admin
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select ok((select count(*)::int from public.org_members) >= 7, 'admin sees every membership of the org');
select ok((select count(*)::int from public.role_permissions) > 0, 'admin reads role bundles');
select lives_ok(
  format($f$insert into public.org_units (org_id, code, name) values (%L, 'u3', 'Unit 3')$f$, (select org from cx)),
  'admin can create a unit');
reset role;

-- standard RLS scopes on scratch tables
create table public.t_org (id text primary key default core.ulid(), org_id text not null, unit_id text, profile_id text, note text);
create table public.t_unit (like public.t_org including all);
create table public.t_own (like public.t_org including all);
select core.enable_standard_rls('public.t_org', 'org', 'members');
select core.enable_standard_rls('public.t_unit', 'unit', 'members');
select core.enable_standard_rls('public.t_own', 'own', 'bookings');
grant select, insert, update on public.t_org, public.t_unit, public.t_own to authenticated;
insert into public.t_org (org_id, note) values ((select org from cx), 'row');
insert into public.t_unit (org_id, unit_id, note) values ((select org from cx), (select unit1 from cx), 'u1 row'), ((select org from cx), (select unit2 from cx), 'u2 row');
insert into public.t_own (org_id, profile_id, note) values
  ((select org from cx), (select id from public.profiles where auth_user_id = (select u from us where role = 'member')), 'member row'),
  ((select org from cx), (select id from public.profiles where auth_user_id = (select u from us where role = 'referee')), 'referee row');

select pg_temp.as_user((select u from us where role = 'front_desk'));
set local role authenticated;
select is((select count(*)::int from public.t_org), 1, 'org scope: front desk has members.read org-wide');
select is((select count(*)::int from public.t_own), 2, 'own scope: bookings.read_all sees every row');
reset role;
select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
select is((select count(*)::int from public.t_org), 0, 'org scope: member without members.read sees none');
select is((select count(*)::int from public.t_own), 1, 'own scope: member sees only their own row');
reset role;
select pg_temp.as_user((select u from uu));
set local role authenticated;
select is((select array_agg(note) from public.t_unit), array['u1 row'], 'unit scope: unit-bound manager sees only their unit');
reset role;
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select is((select count(*)::int from public.t_unit), 2, 'unit scope: org-wide admin sees every unit');
select throws_ok(
  format($f$insert into public.t_unit (org_id, unit_id, note) values (%L, %L, 'x')$f$, (select org_b from cx), null),
  '42501', null, 'insert into another org is refused');
reset role;

-- anon
set local role anon;
select throws_ok($$select count(*) from public.permissions$$, '42501', null, 'anon has no privilege on permissions');
select throws_ok($$select count(*) from public.org_members$$, '42501', null, 'anon has no privilege on org_members');
reset role;

select * from finish();
rollback;
