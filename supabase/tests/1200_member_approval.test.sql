begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create function pg_temp.mk(p_org text, p_role text, p_person text default null) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := coalesce(p_person, core.ulid()); rid text;
begin
  select id into rid from public.roles where org_id = p_org and code = p_role;
  insert into auth.users (id, email) values (u, p_role || '-' || u || '@example.test');
  if p_person is null then
    insert into public.persons (id, org_id, display_name) values (per, p_org, 'Fake ' || p_role);
  end if;
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, p_org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (p_org, pid, rid);
  return u;
end $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as k1, core.ulid() as k2, core.ulid() as k3, core.ulid() as k4, core.ulid() as k5, core.ulid() as k6, core.ulid() as k7,
  core.ulid() as k8, core.ulid() as k9, core.ulid() as k10, core.ulid() as k11, core.ulid() as k12, core.ulid() as k13, core.ulid() as k14,
  core.ulid() as cat, core.ulid() as lad, core.ulid() as rk;
grant select on fx to public;

create temp table us(role text primary key, u uuid);
grant select on us to public;
insert into us values ('admin', pg_temp.mk((select org from fx), 'admin'));
insert into us values ('manager', pg_temp.mk((select org from fx), 'manager'));
insert into us values ('front_desk', pg_temp.mk((select org from fx), 'front_desk'));

-- applicants: each a pending member with an account and the pending role
create function pg_temp.applicant(n integer) returns text language plpgsql as $$
declare u uuid := gen_random_uuid(); per text := core.ulid(); prof text := core.ulid(); mem text := core.ulid(); org text := (select id from public.orgs where code = 'cpc');
begin
  insert into auth.users (id, email) values (u, 'app-' || n || '@members.example.test');
  insert into public.persons (id, org_id, display_name) values (per, org, 'Fake Applicant ' || n);
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (prof, org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (org, prof, (select id from public.roles where org_id = org and code = 'pending_member'));
  insert into public.members (id, org_id, person_id, profile_id, member_no, status) values (mem, org, per, prof, 'CPC-2026-9600' || n, 'pending_approval');
  return mem;
end $$;
create temp table ap as select pg_temp.applicant(1) as m1, pg_temp.applicant(2) as m2, pg_temp.applicant(3) as m3, pg_temp.applicant(4) as m4;
grant select on ap to public;
insert into public.categories (id, org_id, code, name) values ((select cat from fx), (select org from fx), 't5-cat', 'T5 Cat');
insert into public.rank_ladders (id, org_id, category_id) values ((select lad from fx), (select org from fx), (select cat from fx));
insert into public.ranks (id, org_id, ladder_id, code, name, sort_order, is_starting) values ((select rk from fx), (select org from fx), (select lad from fx), 't5-low', 'T5 Low', 0, true);

-- ---- access
select is(has_function_privilege('anon', 'public.decide_member(text,text,text,text,boolean,text)', 'execute'), false, 'anonymous callers cannot decide');
select is(has_function_privilege('authenticated', 'public.decide_member(text,text,text,text,boolean,text)', 'execute'), true, 'signed-in staff reach it (the function checks the permission)');

-- ---- permission checks
select pg_temp.as_user((select u from us where role = 'front_desk'));
set local role authenticated;
select throws_ok(format($f$select public.decide_member('approve', %L, null, %L)$f$, (select m1 from ap), (select k1 from fx)), '42501', null, 'front desk cannot approve');
reset role;
select pg_temp.as_user((select u from us where role = 'manager'));
set local role authenticated;
select throws_ok(format($f$select public.decide_member('approve', %L, null, %L)$f$, (select m1 from ap), (select k1 from fx)), '42501', null, 'a manager (no members.approve) cannot approve');
select throws_ok(format($f$select public.decide_member('suspend', %L, 'reason here', %L)$f$, (select m1 from ap), (select k1 from fx)), '42501', null, 'nor suspend');
reset role;
select is((select status from public.members where id = (select m1 from ap)), 'pending_approval', 'nothing changed');

-- ---- approve
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select throws_ok(format($f$select public.decide_member('dance', %L, null, %L)$f$, (select m1 from ap), (select k1 from fx)), '22023', null, 'an unknown action is refused');
select throws_ok(format($f$select public.decide_member('approve', %L, null, 'not-a-ulid')$f$, (select m1 from ap)), '22023', null, 'the idempotency key must be a ULID');
select throws_ok(format($f$select public.decide_member('approve', %L, null, %L)$f$, core.ulid(), (select k1 from fx)), '22023', null, 'an unknown member is refused');
select is((select public.decide_member('approve', (select m1 from ap), null, (select k1 from fx)) ->> 'status'), 'active', 'an admin approves a pending member');
reset role;
select is((select status from public.members where id = (select m1 from ap)), 'active', 'the member is active');
select is((select status_reason from public.members where id = (select m1 from ap)), 'approved', 'with a reason');
select is((select r.code from public.org_members om join public.members m on m.profile_id = om.profile_id join public.roles r on r.id = om.role_id where m.id = (select m1 from ap)), 'member', 'and now holds the member role');
select ok(exists(select 1 from core.audit_log where action = 'member.approve' and record_id = (select m1 from ap)), 'the approval is audited');
select is((select count(*)::int from public.member_status_events where member_id = (select m1 from ap) and to_status = 'active'), 1, 'and in the status history');

-- the same key replays; a new key finds nothing to do
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select is((select public.decide_member('approve', (select m1 from ap), null, (select k1 from fx)) ->> 'status'), 'active', 'the same key returns the same answer');
select is((select (public.decide_member('approve', (select m1 from ap), null, (select k2 from fx)) ->> 'unchanged')::boolean), true, 'approving twice with another key changes nothing');
select throws_ok(format($f$select public.decide_member('approve', %L, 'other reason', %L)$f$, (select m1 from ap), (select k1 from fx)), 'CP422', null, 'the same key with a different request is refused');
reset role;
select is((select count(*)::int from public.member_status_events where member_id = (select m1 from ap) and to_status = 'active'), 1, 'still one history row after the repeats');
select is((select count(*)::int from core.audit_log where action = 'member.approve' and record_id = (select m1 from ap)), 1, 'and one audit row');

-- ---- approval with a starting rank
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select throws_ok(format($f$select public.decide_member('approve', %L, null, %L, false, %L)$f$, (select m2 from ap), (select k3 from fx), core.ulid()), '22023', null, 'an unknown starting rank is refused');
select is((select public.decide_member('approve', (select m2 from ap), 'welcome', (select k4 from fx), false, (select rk from fx)) ->> 'status'), 'active', 'a member is approved with a starting rank');
reset role;
select is((select rank_id from public.member_ranks where member_id = (select m2 from ap)), (select rk from fx), 'the rank is set');
select is((select count(*)::int from public.rank_history where member_id = (select m2 from ap) and reason = 'starting rank at approval'), 1, 'and recorded in the rank history');
select is((select status_reason from public.members where id = (select m2 from ap)), 'welcome', 'the admin''s reason is kept');

-- ---- review flags must be acknowledged
insert into public.member_review_flags (org_id, member_id, kind) values ((select org from fx), (select m3 from ap), 'possible_duplicate_mobile');
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select throws_ok(format($f$select public.decide_member('approve', %L, null, %L)$f$, (select m3 from ap), (select k5 from fx)), '22023', null, 'open review flags stop an approval until acknowledged');
select is((select public.decide_member('approve', (select m3 from ap), 'checked the flag', (select k5 from fx), true) ->> 'status'), 'active', 'acknowledging the flags approves');
reset role;
select is((select count(*)::int from public.member_review_flags where member_id = (select m3 from ap) and resolved_at is not null), 1, 'and resolves them');

-- ---- reject and reconsider
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select throws_ok(format($f$select public.decide_member('reject', %L, '  ', %L)$f$, (select m4 from ap), (select k6 from fx)), '22023', null, 'a rejection needs a reason');
select is((select public.decide_member('reject', (select m4 from ap), 'duplicate of an existing member', (select k6 from fx)) ->> 'status'), 'rejected', 'a pending member is rejected');
select throws_ok(format($f$select public.decide_member('approve', %L, null, %L)$f$, (select m4 from ap), (select k7 from fx)), '22023', null, 'a rejected member cannot be approved directly');
select is((select public.decide_member('reconsider', (select m4 from ap), 'the club checked again', (select k8 from fx)) ->> 'status'), 'pending_approval', 'a rejected member can be reconsidered');
reset role;
select is((select status from public.members where id = (select m4 from ap)), 'pending_approval', 'back to waiting');
select is((select r.code from public.org_members om join public.members m on m.profile_id = om.profile_id join public.roles r on r.id = om.role_id where m.id = (select m4 from ap)), 'pending_member', 'a rejected applicant never held the member role');

-- ---- suspend and restore
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select throws_ok(format($f$select public.decide_member('suspend', %L, 'x', %L)$f$, (select m1 from ap), (select k9 from fx)), '22023', null, 'a suspension needs a real reason');
select throws_ok(format($f$select public.decide_member('suspend', %L, 'unpaid dues', %L)$f$, (select m4 from ap), (select k9 from fx)), '22023', null, 'only an active member can be suspended');
select is((select public.decide_member('suspend', (select m1 from ap), 'unpaid dues', (select k9 from fx)) ->> 'status'), 'suspended', 'an active member is suspended');
reset role;
select is((select om.is_active from public.org_members om join public.members m on m.profile_id = om.profile_id where m.id = (select m1 from ap)), false, 'their access is switched off');
select pg_temp.as_user((select auth_user_id from public.profiles p join public.members m on m.profile_id = p.id where m.id = (select m1 from ap)));
set local role authenticated;
select is((select count(*)::int from public.my_permissions()), 0, 'a suspended member has no permissions');
reset role;
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select is((select public.decide_member('restore', (select m1 from ap), 'dues paid', (select k10 from fx)) ->> 'status'), 'active', 'a suspended member is restored');
reset role;
select is((select om.is_active from public.org_members om join public.members m on m.profile_id = om.profile_id where m.id = (select m1 from ap)), true, 'and their access returns');
select pg_temp.as_user((select auth_user_id from public.profiles p join public.members m on m.profile_id = p.id where m.id = (select m1 from ap)));
set local role authenticated;
select cmp_ok((select count(*)::int from public.my_permissions()), '>', 0, 'with the member permissions');
reset role;
select is((select count(*)::int from core.audit_log where action in ('member.suspend', 'member.restore') and record_id = (select m1 from ap)), 2, 'both decisions are audited');
select is((select string_agg(to_status, '>' order by occurred_at, id) is not null from public.member_status_events where member_id = (select m1 from ap)), true, 'the history has every step');

-- ---- the member cannot do it to themselves, and cannot read other people's flags
select pg_temp.as_user((select auth_user_id from public.profiles p join public.members m on m.profile_id = p.id where m.id = (select m3 from ap)));
set local role authenticated;
select throws_ok(format($f$select public.decide_member('suspend', %L, 'trying it myself', %L)$f$, (select m3 from ap), (select k11 from fx)), '42501', null, 'a member cannot change their own status');
reset role;

select * from finish();
rollback;
