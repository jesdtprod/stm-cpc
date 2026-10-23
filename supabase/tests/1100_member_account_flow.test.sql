begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  gen_random_uuid() as u1, gen_random_uuid() as u2, gen_random_uuid() as u3,
  core.ulid() as per1, core.ulid() as per2, core.ulid() as per3, core.ulid() as prof1, core.ulid() as prof2, core.ulid() as prof3,
  core.ulid() as mem1, core.ulid() as mem2, core.ulid() as mem3;
grant select on fx to public;

insert into auth.users (id, email) values ((select u1 from fx), 'flow-1@members.example.test'), ((select u2 from fx), 'flow-2@members.example.test'), ((select u3 from fx), 'flow-3@members.example.test');
insert into public.persons (id, org_id, display_name, date_of_birth) values
  ((select per1 from fx), (select org from fx), 'Fake Flow One', '2000-01-02'),
  ((select per2 from fx), (select org from fx), 'Fake Flow Two', '2000-01-03'),
  ((select per3 from fx), (select org from fx), 'Fake Flow Three', '2000-01-04');
insert into public.profiles (id, org_id, auth_user_id, person_id) values
  ((select prof1 from fx), (select org from fx), (select u1 from fx), (select per1 from fx)),
  ((select prof2 from fx), (select org from fx), (select u2 from fx), (select per2 from fx)),
  ((select prof3 from fx), (select org from fx), (select u3 from fx), (select per3 from fx));
insert into public.org_members (org_id, profile_id, role_id)
  select (select org from fx), p, (select id from public.roles where org_id = (select org from fx) and code = 'pending_member')
  from (values ((select prof1 from fx)), ((select prof2 from fx)), ((select prof3 from fx))) v(p);
insert into public.members (id, org_id, person_id, profile_id, member_no, status) values
  ((select mem1 from fx), (select org from fx), (select per1 from fx), (select prof1 from fx), 'CPC-2026-97001', 'imported'),
  ((select mem2 from fx), (select org from fx), (select per2 from fx), (select prof2 from fx), 'CPC-2026-97002', 'imported'),
  ((select mem3 from fx), (select org from fx), (select per3 from fx), (select prof3 from fx), 'CPC-2026-97003', 'pending_approval');
insert into public.member_access (org_id, member_id, must_change_password, temp_password_expires_at) values
  ((select org from fx), (select mem1 from fx), true, now() + interval '30 days'),
  ((select org from fx), (select mem2 from fx), true, now() + interval '30 days'),
  ((select org from fx), (select mem3 from fx), false, null);

-- ---- access
select is((select count(*)::int from unnest(array['public.member_password_changed(text)', 'public.member_password_context(uuid)']) f
  where has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute')), 0, 'the password hooks are service-only');
select is(has_function_privilege('authenticated', 'public.my_access_state()', 'execute'), true, 'a signed-in member can read their own state');
select is(has_function_privilege('authenticated', 'public.update_my_profile(text,text,text,text,text,text,text,text,text,text,text,text,text)', 'execute'), true, 'and edit their own profile');
select is(has_function_privilege('anon', 'public.my_access_state()', 'execute'), false, 'anonymous callers cannot');
select is(has_function_privilege('anon', 'public.update_my_profile(text,text,text,text,text,text,text,text,text,text,text,text,text)', 'execute'), false, 'nor edit');

-- ---- first sign-in: imported -> invited
select core.member_login_succeeded((select mem1 from fx));
select is((select status from public.members where id = (select mem1 from fx)), 'invited', 'the first sign-in turns imported into invited');
select is((select status_reason from public.members where id = (select mem1 from fx)), 'first sign-in', 'with the reason');
select core.member_login_succeeded((select mem3 from fx));
select is((select status from public.members where id = (select mem3 from fx)), 'pending_approval', 'a later sign-in does not move other statuses');
select core.member_login_succeeded((select mem1 from fx));
select is((select status from public.members where id = (select mem1 from fx)), 'invited', 'and does not change invited');

-- ---- my_access_state
select pg_temp.as_user((select u1 from fx));
set local role authenticated;
select is((select status from public.my_access_state()), 'invited', 'a member reads their own status');
select is((select member_no from public.my_access_state()), 'CPC-2026-97001', 'and member number');
select is((select must_change_password from public.my_access_state()), true, 'whether a password change is required');
select is((select profile_complete from public.my_access_state()), false, 'and that the profile is incomplete');
select is((select count(*)::int from public.my_access_state()), 1, 'only their own row comes back');
reset role;
select pg_temp.as_user(gen_random_uuid());
set local role authenticated;
select is((select count(*)::int from public.my_access_state()), 0, 'an unknown user gets nothing');
reset role;

-- ---- update_my_profile: validation
create temp table brgy as select code from public.psgc_areas where level = 'barangay' and region_code = '130000000' order by code limit 1;
grant select on brgy to public;
select pg_temp.as_user((select u1 from fx));
set local role authenticated;
select throws_ok(format($f$select public.update_my_profile(null, '12345', null, '1 Test St', %L)$f$, (select code from brgy)), '22023', null, 'a short mobile number is refused');
select throws_ok(format($f$select public.update_my_profile(null, null, null, '1 Test St', %L)$f$, (select code from brgy)), '22023', null, 'a mobile number is required');
select throws_ok(format($f$select public.update_my_profile(null, '09171234567', 'not-an-email', '1 Test St', %L)$f$, (select code from brgy)), '22023', null, 'a bad email is refused');
select throws_ok($$select public.update_my_profile(null, '09171234567', null, '1 Test St', null)$$, '22023', null, 'a barangay is required');
select throws_ok($$select public.update_my_profile(null, '09171234567', null, '1 Test St', '999999999')$$, '22023', null, 'an unknown barangay is refused');
select throws_ok(format($f$select public.update_my_profile(null, '09171234567', null, %L, %L)$f$, repeat('x', 201), (select code from brgy)), '22023', null, 'a long street line is refused');
select throws_ok(format($f$select public.update_my_profile('x', '09171234567', null, null, %L)$f$, (select code from brgy)), '22023', null, 'a one-letter name is refused');
select throws_ok(format($f$select public.update_my_profile(null, '09171234567', null, null, (select code from public.psgc_areas where level = 'city_muni' limit 1))$f$), '22023', null, 'a city code is not a barangay');
reset role;
select is((select status from public.members where id = (select mem1 from fx)), 'invited', 'a refused edit changes nothing');

-- ---- update_my_profile: success, no move yet because the password is not changed
select pg_temp.as_user((select u1 from fx));
set local role authenticated;
select lives_ok(format($f$select public.update_my_profile('  Fake   Flow  One ', '+63 917 123 4567', ' A@Example.TEST ', '  12 Sample St  ', %L)$f$, (select code from brgy)), 'a valid profile is saved');
select is((select profile_complete from public.my_access_state()), true, 'which completes the profile');
select is((select status from public.my_access_state()), 'invited', 'but the member stays invited until the password is changed');
reset role;
select is((select mobile from public.persons where id = (select per1 from fx)), '09171234567', 'the mobile number is normalized');
select is((select email from public.persons where id = (select per1 from fx)), 'a@example.test', 'the email is lower-cased');
select is((select display_name from public.persons where id = (select per1 from fx)), 'Fake Flow One', 'the name is tidied');
select is((select street_line from public.persons where id = (select per1 from fx)), '12 Sample St', 'the street line is trimmed');
select is((select region_code from public.persons where id = (select per1 from fx)), '130000000', 'the region is derived from the barangay');
select matches((select address_text from public.persons where id = (select per1 from fx)), '^12 Sample St, .*Metro Manila$', 'and the address text is built');
select is((select date_of_birth from public.persons where id = (select per1 from fx)), '2000-01-02'::date, 'the birth date is not touched');

-- the password is changed (service hook): now the member moves on
select core.member_password_changed((select mem1 from fx));
select is((select status from public.members where id = (select mem1 from fx)), 'pending_approval', 'password changed and profile complete: pending approval');
select is((select must_change_password from public.member_access where member_id = (select mem1 from fx)), false, 'the forced-change flag is cleared');
select is((select temp_password_expires_at from public.member_access where member_id = (select mem1 from fx)), null, 'and the first-password expiry');
select is((select count(*)::int from public.member_status_events where member_id = (select mem1 from fx) and to_status = 'pending_approval'), 1, 'the move is in the status history');
select ok(exists(select 1 from core.audit_log where action = 'password.changed' and record_id = (select mem1 from fx)), 'and the password change is audited');
select core.member_password_changed((select mem1 from fx));
select is((select count(*)::int from public.member_status_events where member_id = (select mem1 from fx) and to_status = 'pending_approval'), 1, 'repeating the hook changes nothing');

-- the other order: profile first, password later
select pg_temp.as_user((select u2 from fx));
set local role authenticated;
select throws_ok(format($f$select public.update_my_profile(null, '09171234567', null, null, %L)$f$, (select code from brgy)), '42501', null, 'a member who never signed in (still imported) cannot edit yet');
reset role;
select core.member_login_succeeded((select mem2 from fx));
select core.member_password_changed((select mem2 from fx));
select is((select status from public.members where id = (select mem2 from fx)), 'invited', 'password changed but profile incomplete: still invited');
select pg_temp.as_user((select u2 from fx));
set local role authenticated;
select lives_ok(format($f$select public.update_my_profile(null, '0917 123 4568', null, null, %L)$f$, (select code from brgy)), 'then the profile is completed');
select is((select status from public.my_access_state()), 'pending_approval', 'and the member moves to pending approval');
reset role;

-- an active member can edit their profile; nobody can edit someone else's
select pg_temp.as_user((select u3 from fx));
set local role authenticated;
select lives_ok(format($f$select public.update_my_profile(null, '09171234569', null, 'Block 1', %L)$f$, (select code from brgy)), 'an approved-stage member can edit their profile');
reset role;
select is((select mobile from public.persons where id = (select per3 from fx)), '09171234569', 'their own row changed');
select is((select mobile from public.persons where id = (select per2 from fx)), '09171234568', 'and no one else''s changed');
select is((select count(*)::int from public.persons where id in ((select per1 from fx), (select per2 from fx)) and mobile = '09171234569'), 0, 'the number did not leak onto another person');

-- password context for the Edge Function
select is((select member_no from core.member_password_context((select u1 from fx))), 'CPC-2026-97001', 'the password function can see the member number');
select is((select date_of_birth from core.member_password_context((select u1 from fx))), '2000-01-02'::date, 'and the birth date, to refuse passwords built from it');
select is((select count(*)::int from core.member_password_context(gen_random_uuid())), 0, 'nothing for an unknown user');

-- archived members cannot edit
update public.members set status = 'archived' where id = (select mem3 from fx);
select pg_temp.as_user((select u3 from fx));
set local role authenticated;
select throws_ok(format($f$select public.update_my_profile(null, '09171234569', null, null, %L)$f$, (select code from brgy)), '42501', null, 'an archived member cannot edit their profile');
reset role;

select * from finish();
rollback;
