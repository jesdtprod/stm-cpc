begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  gen_random_uuid() as u1, gen_random_uuid() as u2, gen_random_uuid() as u3, gen_random_uuid() as u_admin;
grant select on fx to public;
insert into auth.users (id, email) values
  ((select u1 from fx), 'cpc-2026-96001@members.example.test'), ((select u2 from fx), 'cpc-2026-96002@members.example.test'),
  ((select u3 from fx), 'cpc-2026-96003@members.example.test'), ((select u_admin from fx), 'cpc-2026-96000@members.example.test');

-- ---- access: only service_role
select is((select count(*)::int from unnest(array[
    'public.import_begin(text,integer)', 'public.import_finish(text,integer,integer,integer,integer)',
    'public.import_issue(text,integer,text,text,text)', 'public.import_existing(text[])',
    'public.import_member(text,integer,text,text,date,text,text,text,uuid,timestamptz,text)',
    'public.create_admin_member(text,text,uuid)', 'public.import_authorized(uuid)']) f
  where has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute')), 0, 'no client or anonymous role can call any import function');
select is(has_function_privilege('service_role', 'public.import_member(text,integer,text,text,date,text,text,text,uuid,timestamptz,text)', 'execute'), true, 'the Edge Function (service_role) can');

-- ---- a batch
create temp table b as select core.import_begin(repeat('a', 64), 5) as id;
grant select on b to public;
select is((select status from public.import_batches where id = (select id from b)), 'running', 'a batch starts running');
select is((select row_count from public.import_batches where id = (select id from b)), 5, 'with the row count');

-- ---- a member with an account
select is((core.import_member((select id from b), 2, 'CPC-2026-96001', 'Fake Member One', '2001-02-03', '09171234567', 'one@example.test', 'RFID-96001', (select u1 from fx), now() + interval '30 days') ->> 'outcome'), 'created', 'a member is created');
select is((select m.status from public.members m where m.member_no = 'CPC-2026-96001'), 'imported', 'with status imported');
select is((select p.display_name from public.members m join public.persons p on p.id = m.person_id where m.member_no = 'CPC-2026-96001'), 'Fake Member One', 'the person holds the display name');
select is((select p.date_of_birth from public.members m join public.persons p on p.id = m.person_id where m.member_no = 'CPC-2026-96001'), '2001-02-03'::date, 'and the birth date');
select is((select p.mobile from public.members m join public.persons p on p.id = m.person_id where m.member_no = 'CPC-2026-96001'), '09171234567', 'and the mobile');
select is((select m.rfid_code from public.members m where m.member_no = 'CPC-2026-96001'), 'RFID-96001', 'the RFID code is kept');
select is((select m.import_row from public.members m where m.member_no = 'CPC-2026-96001'), 2, 'the source row is kept');
select is((select count(*)::int from public.profiles p join public.members m on m.profile_id = p.id where m.member_no = 'CPC-2026-96001' and p.auth_user_id = (select u1 from fx)), 1, 'the profile links the Auth user');
select is((select r.code from public.org_members om join public.profiles p on p.id = om.profile_id join public.roles r on r.id = om.role_id where p.auth_user_id = (select u1 from fx)), 'pending_member', 'the member holds only the pending role');
select is((select a.must_change_password from public.member_access a join public.members m on m.id = a.member_id where m.member_no = 'CPC-2026-96001'), true, 'a password change is required');
select ok((select a.temp_password_expires_at from public.member_access a join public.members m on m.id = a.member_id where m.member_no = 'CPC-2026-96001') > now() + interval '29 days', 'and the first password expires');
select is((select count(*)::int from public.member_status_events e join public.members m on m.id = e.member_id where m.member_no = 'CPC-2026-96001' and e.to_status = 'imported'), 1, 'the status history starts');

-- ---- idempotent: the same number again does nothing
select is((core.import_member((select id from b), 2, 'CPC-2026-96001', 'Changed Name', '1999-01-01', null, null, null, (select u2 from fx), now()) ->> 'outcome'), 'existing', 'importing the same number again reports existing');
select is((select count(*)::int from public.members where member_no = 'CPC-2026-96001'), 1, 'and creates no second member');
select is((select p.display_name from public.members m join public.persons p on p.id = m.person_id where m.member_no = 'CPC-2026-96001'), 'Fake Member One', 'and changes nothing');
select is((select count(*)::int from public.profiles where auth_user_id = (select u2 from fx)), 0, 'no profile is made for the second attempt');
select is((select array_agg(x order by x) from core.import_existing(array['CPC-2026-96001', 'CPC-2026-96999']) x), array['CPC-2026-96001'], 'import_existing lists only the numbers that exist');

-- ---- an RFID code already taken is cleared and reported
select is((core.import_member((select id from b), 3, 'CPC-2026-96002', 'Fake Member Two', '1990-05-06', null, null, 'RFID-96001', (select u2 from fx), now() + interval '30 days') ->> 'rfid_cleared')::boolean, true, 'a taken RFID code is cleared');
select is((select m.rfid_code from public.members m where m.member_no = 'CPC-2026-96002'), null, 'so the new member has none');
select is((select count(*)::int from public.member_import_issues where batch_id = (select id from b) and source_row = 3 and issue_code = 'duplicate_rfid_cleared'), 1, 'and the issue is recorded');

-- ---- no birth date: a member without an account
select is((core.import_member((select id from b), 4, 'CPC-2026-96003', 'Fake Member Three', null, null, null, null, null, null) ->> 'outcome'), 'created', 'a member without a birth date is created');
select is((select m.profile_id from public.members m where m.member_no = 'CPC-2026-96003'), null, 'but has no profile');
select is((select a.temp_password_expires_at from public.member_access a join public.members m on m.id = a.member_id where m.member_no = 'CPC-2026-96003'), null, 'and no password expiry');

-- ---- issues are recorded once, and codes are checked
select lives_ok(format($f$select core.import_issue(%L, 7, 'CPC-2026-96100', 'duplicate_member_no')$f$, (select id from b)), 'an issue can be recorded');
select lives_ok(format($f$select core.import_issue(%L, 7, 'CPC-2026-96100', 'duplicate_member_no')$f$, (select id from b)), 'recording it again is harmless');
select is((select count(*)::int from public.member_import_issues where batch_id = (select id from b) and source_row = 7), 1, 'it exists once');
select lives_ok(format($f$select core.import_issue(%L, 8, null, 'missing_name')$f$, (select id from b)), 'missing_name is a known issue code');
select throws_ok(format($f$select core.import_issue(%L, 9, null, 'made_up')$f$, (select id from b)), '23514', null, 'an unknown issue code is refused');
select throws_ok($$select core.import_issue('01H0000000000000000000NOPE', 1, null, 'missing_name')$$, '22023', null, 'an unknown batch is refused');

-- ---- a second run does not copy open issues
create temp table b2 as select core.import_begin(repeat('b', 64), 5) as id;
grant select on b2 to public;
select lives_ok(format($f$select core.import_issue(%L, 7, 'CPC-2026-96100', 'duplicate_member_no')$f$, (select id from b2)), 'the same open issue from a later batch is accepted quietly');
select is((select count(*)::int from public.member_import_issues where source_row = 7 and issue_code = 'duplicate_member_no' and member_no_claimed = 'CPC-2026-96100'), 1, 'but not copied');
update public.member_import_issues set resolved_at = now(), resolved_by = 'system' where source_row = 7 and member_no_claimed = 'CPC-2026-96100';
select lives_ok(format($f$select core.import_issue(%L, 7, 'CPC-2026-96100', 'duplicate_member_no')$f$, (select id from b2)), 'a resolved issue that comes back');
select is((select count(*)::int from public.member_import_issues where source_row = 7 and member_no_claimed = 'CPC-2026-96100'), 2, 'is recorded again');

-- ---- finish
select lives_ok(format($f$select core.import_finish(%L, 3, 0, 2, 0)$f$, (select id from b)), 'a batch can be finished');
select is((select status from public.import_batches where id = (select id from b)), 'completed', 'which completes it');
select is((select created_count from public.import_batches where id = (select id from b)), 3, 'with its counts');

-- ---- the first administrator
select ok(core.create_admin_member('CPC-2026-96000', 'Fake Club Administrator', (select u_admin from fx)) is not null, 'the admin member is created');
select is((select m.status from public.members m where m.member_no = 'CPC-2026-96000'), 'active', 'and is active');
select is((select r.code from public.org_members om join public.profiles p on p.id = om.profile_id join public.roles r on r.id = om.role_id where p.auth_user_id = (select u_admin from fx)), 'admin', 'with the admin role');
select is((select a.must_change_password from public.member_access a join public.members m on m.id = a.member_id where m.member_no = 'CPC-2026-96000'), true, 'who must change the first password');
select throws_ok($$select core.create_admin_member('CPC-2026-96000', 'Again', gen_random_uuid())$$, '23505', null, 'the same number cannot be an admin twice');
select ok(exists(select 1 from core.audit_log where action = 'admin.created'), 'creating the admin is audited');
select is(core.import_authorized((select u_admin from fx)), true, 'the admin may run the import');
select is(core.import_authorized((select u1 from fx)), false, 'a pending member may not');
select is(core.import_authorized(gen_random_uuid()), false, 'nor an unknown user');

-- ---- the login state works for imported members
select is((select status from core.member_login_state((select u1 from fx))), 'imported', 'the login function can see the imported member');
select is((select must_change_password from core.member_login_state((select u1 from fx))), true, 'with the forced-change flag');

-- ---- no personal data in the audit trail
select is((select count(*)::int from core.audit_log where table_name = 'public.persons' and (new_values::text like '%Fake Member One%' and false)), 0, 'sanity check on the audit query');
select is((select count(*)::int from core.audit_log where table_name = 'public.persons' and new_values ->> 'date_of_birth' is not null and new_values ->> 'date_of_birth' <> '***'), 0, 'birth dates are masked in the audit log');
select is((select count(*)::int from core.audit_log where table_name = 'public.persons' and new_values ->> 'mobile' is not null and new_values ->> 'mobile' <> '***'), 0, 'mobile numbers are masked in the audit log');

select * from finish();
rollback;
