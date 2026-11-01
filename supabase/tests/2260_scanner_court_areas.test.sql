begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();
select is(has_function_privilege('anon', 'public.checkin_court_board()', 'execute'), false, 'visitors cannot read court names or bookings');
select is(has_function_privilege('authenticated', 'public.checkin_court_board()', 'execute'), true, 'authenticated callers reach the permission check');
select throws_ok($$select public.checkin_court_board()$$, '42501', 'you do not have permission to view the court board', 'no session is refused');
create temp table fx as select core.ulid() org, core.ulid() other_org, core.ulid() profile,
  core.ulid() person, core.ulid() member, core.ulid() role, gen_random_uuid() auth_user,
  core.ulid() court1, core.ulid() court2, core.ulid() booking1, core.ulid() booking2;
grant select on fx to public;
insert into public.orgs(id, org_id, code, name)
select org, org, 'fake-board-' || lower(right(org, 6)), 'Fake Court Board' from fx
union all select other_org, other_org, 'fake-other-' || lower(right(other_org, 6)), 'Fake Other Club' from fx;
insert into public.roles(id, org_id, code, name) select role, org, 'scanner', 'Fake Scanner' from fx;
insert into public.role_permissions(org_id, role_id, permission_id)
select fx.org, fx.role, pe.id from fx cross join public.permissions pe where pe.code = 'bookings.checkin' and pe.deleted_at is null;
insert into auth.users(id, email) select auth_user, 'fake-board-' || auth_user || '@example.test' from fx;
insert into public.persons(id, org_id, display_name) select person, org, 'Fake Board Player' from fx;
insert into public.profiles(id, org_id, auth_user_id, person_id) select profile, org, auth_user, person from fx;
insert into public.org_members(org_id, profile_id, role_id) select org, profile, role from fx;
insert into public.members(id, org_id, person_id, member_no, status) select member, org, person, 'CPC-2026-99881', 'pending_approval' from fx;
update public.members set status = 'active' where id = (select member from fx);
insert into public.courts(id, org_id, code, name) select court1, org, 'tennis-1', 'Tennis Court 1' from fx
union all select court2, org, 'tennis-2', 'Tennis Court 2' from fx;
insert into public.courts(org_id, code, name) select org, 'other-court', 'Other Court' from fx
union all select other_org, 'tennis-3', 'Tennis Court 3' from fx;
alter table fx add column back1 text default core.ulid(), add column back2 text default core.ulid();
insert into public.courts(id, org_id, code, name)
select back1, org, 'back-gate-court-4', 'Back Gate Court 4' from fx
union all select back2, org, 'back-gate-court-5', 'Back Gate Court 5' from fx;
insert into public.bookings(id, org_id, court_id, requested_by_member_id, during, payload_hash, rate_snapshot, price_snapshot, court_name_snapshot)
select booking1, org, court1, member, tstzrange(now() - interval '15 minutes', now() + interval '15 minutes', '[)'), repeat('a',64), 0, 0, 'Tennis Court 1' from fx
union all select booking2, org, back1, member, tstzrange(now() - interval '15 minutes', now() + interval '15 minutes', '[)'), repeat('b',64), 0, 0, 'Back Gate Court 4' from fx;
update public.bookings set status = 'confirmed', approved_at = now() where org_id = (select org from fx);
update public.profiles set checkin_court_scope = 'tennis' where id = (select profile from fx);
select is(has_column_privilege('authenticated', 'public.profiles', 'checkin_court_scope', 'UPDATE'), false, 'clients cannot grant themselves a different court scope');
select set_config('request.jwt.claims', json_build_object('sub', (select auth_user from fx), 'role', 'authenticated')::text, true);
set local role authenticated;
select ok(core.can_checkin_court((select court1 from fx)), 'tennis scanner may check in tennis bookings');
select ok(not core.can_checkin_court((select back1 from fx)), 'tennis scanner may not check in Back Gate bookings');
select is(public.checkin_court_board()->>'court_area', 'tennis', 'board identifies tennis scope');
select is(jsonb_array_length(public.checkin_court_board()->'courts'), 2, 'tennis board excludes Back Gate and other clubs');
select throws_ok($$update public.profiles set checkin_court_scope = 'backgate' where id = (select profile from fx)$$, '42501', null, 'scanner cannot change its own scope');
select throws_ok(format($q$select public.scan_check_in(%L, 'fake-cross-tennis')$q$, (select booking2 from fx)), '42501', 'this court is not assigned to your scanner account', 'QR/code endpoint refuses cross-area bookings');
select throws_ok(format($q$select public.decide_booking(%L, 'check_in', null, 'fake-direct-checkin')$q$, (select booking2 from fx)), '42501', 'this court is not assigned to your scanner account', 'direct decision endpoint cannot bypass the scope');
select throws_ok(format($q$select public.decide_booking(%L, 'complete', null, 'fake-direct-complete')$q$, (select booking2 from fx)), '42501', 'this court is not assigned to your scanner account', 'complete is also court-scoped');
select lives_ok(format($q$select public.scan_check_in(%L, %L)$q$, (select booking1 from fx), core.ulid()), 'own tennis booking checks in');
reset role;
update public.profiles set checkin_court_scope = 'backgate' where id = (select profile from fx);
set local role authenticated;
select ok(core.can_checkin_court((select back1 from fx)), 'Back Gate scanner may check in Back Gate bookings');
select ok(not core.can_checkin_court((select court1 from fx)), 'Back Gate scanner may not check in tennis bookings');
select is(public.checkin_court_board()->>'court_area', 'backgate', 'board identifies Back Gate scope');
select is(jsonb_array_length(public.checkin_court_board()->'courts'), 2, 'Back Gate board includes every configured Back Gate court');
select is(public.checkin_court_board()->'courts'->0->>'name', 'Back Gate Court 4', 'board uses actual Back Gate court names');
select throws_ok(format($q$select public.scan_check_in(%L, 'fake-cross-backgate')$q$, (select booking1 from fx)), '42501', 'this court is not assigned to your scanner account', 'already-checked-in bookings cannot bypass cross-area validation');
select lives_ok(format($q$select public.scan_check_in(%L, %L)$q$, (select booking2 from fx), core.ulid()), 'own Back Gate booking checks in');
reset role;
update public.profiles set checkin_court_scope = null where id = (select profile from fx);
set local role authenticated;
select ok(core.can_checkin_court((select back1 from fx)) and core.can_checkin_court((select court1 from fx)), 'unscoped permission-based access is preserved');
reset role;
update public.org_members set is_active = false where profile_id = (select profile from fx);
set local role authenticated;
select ok(not core.can_checkin_court((select court1 from fx)), 'inactive staff lose access regardless of scope');
select throws_ok($$select public.checkin_court_board()$$, '42501', 'you do not have permission to view the court board', 'inactive staff cannot read the board');
reset role;
select * from finish();
rollback;
