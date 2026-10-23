begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as mt, core.ulid() as mp, core.ulid() as mi,
  core.ulid() as k1, core.ulid() as k2, core.ulid() as k3, core.ulid() as k4, core.ulid() as k5, core.ulid() as k6,
  core.ulid() as k7, core.ulid() as k8, core.ulid() as k9;
grant select on fx to public;

-- a person with an account, a member record and a role
create function pg_temp.mk(p_role text, p_member_id text, p_no text, p_final text) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); org text := (select id from public.orgs where code = 'cpc');
begin
  insert into auth.users (id, email) values (u, lower(p_no) || '@members.example.test');
  insert into public.persons (id, org_id, display_name) values (per, org, 'Fake Staff ' || p_no);
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (org, pid, (select id from public.roles where org_id = org and code = p_role));
  insert into public.members (id, org_id, person_id, profile_id, member_no) values (p_member_id, org, per, pid, p_no);
  update public.members set status = 'invited' where id = p_member_id;
  update public.members set status = 'pending_approval' where id = p_member_id;
  if p_final = 'active' then update public.members set status = 'active' where id = p_member_id; end if;
  return u;
end $$;
create temp table us(role text primary key, u uuid, mid text);
grant select on us to public;
insert into us select 'admin', pg_temp.mk('admin', core.ulid(), 'CPC-2026-9901', 'active'), null;
insert into us select 'member', pg_temp.mk('member', core.ulid(), 'CPC-2026-9902', 'active'), null;
insert into us select 'target', pg_temp.mk('member', (select mt from fx), 'CPC-2026-9903', 'active'), (select mt from fx);
insert into us select 'waiting', pg_temp.mk('pending_member', (select mp from fx), 'CPC-2026-9904', 'pending'), (select mp from fx);
insert into us select 'other_admin', pg_temp.mk('admin', core.ulid(), 'CPC-2026-9905', 'active'), null;

update us set mid = (select id from public.members m where m.member_no = case us.role
  when 'admin' then 'CPC-2026-9901' when 'member' then 'CPC-2026-9902' when 'other_admin' then 'CPC-2026-9905' end) where mid is null;

-- ---- access
select is(has_function_privilege('anon', 'public.assign_role(text,text,text,text)', 'execute'), false, 'anonymous callers cannot assign roles');
select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
select throws_ok(format($f$select public.assign_role(%L, 'referee', 'scorekeeper', %L)$f$, (select mt from fx), (select k1 from fx)), '42501', null, 'a member cannot assign roles');
select throws_ok($$select * from public.staff_directory(null, true)$$, '42501', null, 'nor read the staff list');
select throws_ok($$select public.role_catalog()$$, '42501', null, 'nor the role catalog');
reset role;

-- ---- an admin assigns a role
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select throws_ok(format($f$select public.assign_role(%L, 'referee', '', %L)$f$, (select mt from fx), (select k2 from fx)), '22023', 'a reason is required', 'a reason is required');
select throws_ok(format($f$select public.assign_role(%L, 'pending_member', 'back to waiting', %L)$f$, (select mt from fx), (select k2 from fx)), '22023', 'that role cannot be assigned here', 'the pending role cannot be assigned by hand');
select throws_ok(format($f$select public.assign_role(%L, 'superuser', 'because', %L)$f$, (select mt from fx), (select k2 from fx)), '22023', null, 'an unknown role is refused');
select throws_ok(format($f$select public.assign_role(%L, 'referee', 'scorekeeper', %L)$f$, (select mp from fx), (select k2 from fx)), '22023', 'only an active member with an account can be given a role', 'a member who is not active cannot be given a role');
select throws_ok(format($f$select public.assign_role(%L, 'manager', 'promotion', %L)$f$, (select mid from us where role = 'admin'), (select k2 from fx)), '42501', 'you cannot change your own role', 'an admin cannot change their own role');
create temp table a1 as select public.assign_role((select mt from fx), 'referee', 'scorekeeper at the club', (select k3 from fx)) as r;
reset role;
grant select on a1 to public;
select is((select r ->> 'ok' from a1), 'true', 'the role is assigned');
select is((select r.code from public.org_members om join public.roles r on r.id = om.role_id join public.members m on m.profile_id = om.profile_id where m.id = (select mt from fx)), 'referee', 'and stored');
select is((select count(*)::int from core.audit_log where action = 'role.assign' and (new_values ->> 'role') = 'referee' and (old_values ->> 'role') = 'member' and (new_values ->> 'reason') = 'scorekeeper at the club'), 1, 'the old role, the new role and the reason are in the audit log');
set local role authenticated;
select is((select public.assign_role((select mt from fx), 'referee', 'scorekeeper at the club', (select k3 from fx))), (select r from a1), 'the same key replays the first answer');
select is((select (public.assign_role((select mt from fx), 'referee', 'scorekeeper at the club', (select k4 from fx))) ->> 'unchanged'), 'true', 'assigning the same role again changes nothing');
reset role;
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select is((select count(*)::int from public.staff_directory('9903', true)), 1, 'the new referee is in the staff list');
select is((select count(*)::int from public.staff_directory('9902', true)), 0, 'a plain member is not');
select is((select count(*)::int from public.staff_directory('9902', false)), 1, 'but can be found when looking for someone to give a role to');
select is((select count(*)::int from public.staff_directory('9904', false)), 0, 'a member who is not active cannot be found for that');
select throws_ok($$select * from public.staff_directory('9', false)$$, '22023', null, 'a one-letter search is refused');
select is((select count(*)::int from public.staff_directory('9901', true) where is_self), 1, 'the staff list marks the caller');
select is((select jsonb_array_length(public.role_catalog()) >= 6), true, 'the role catalog lists the roles');
select is((select jsonb_path_exists(public.role_catalog(), '$[*] ? (@.code == "referee").permissions[*] ? (@.code == "scores.enter")')), true, 'with their permissions');
reset role;

-- ---- the last admin cannot be demoted
update public.org_members set is_active = false
where org_id = (select org from fx) and role_id = (select id from public.roles where org_id = (select org from fx) and code = 'admin')
  and profile_id not in (select profile_id from public.members where id = (select mid from us where role = 'other_admin'));
insert into public.role_permissions (org_id, role_id, permission_id)
select (select org from fx), (select id from public.roles where org_id = (select org from fx) and code = 'manager'), (select id from public.permissions where code = 'roles.manage' and deleted_at is null);
insert into us select 'boss', pg_temp.mk('manager', core.ulid(), 'CPC-2026-9906', 'active'), null;
update us set mid = (select id from public.members where member_no = 'CPC-2026-9906') where role = 'boss';
select pg_temp.as_user((select u from us where role = 'boss'));
set local role authenticated;
select throws_ok(format($f$select public.assign_role(%L, 'member', 'stepping down', %L)$f$, (select mid from us where role = 'other_admin'), (select k5 from fx)), '22023', 'the last admin cannot be demoted; make someone else an admin first', 'the last admin cannot be demoted');
select is((select public.assign_role((select mt from fx), 'manager', 'promotion', (select k6 from fx)) ->> 'ok'), 'true', 'a role can still be given to someone else');
reset role;

select * from finish();
rollback;
