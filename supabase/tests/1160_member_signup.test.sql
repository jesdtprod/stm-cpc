begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  gen_random_uuid() as u1, gen_random_uuid() as u2, gen_random_uuid() as u3, gen_random_uuid() as u4, gen_random_uuid() as u_staff,
  core.ulid() as per_old, core.ulid() as mem_old;
grant select on fx to public;
insert into auth.users (id, email) select u, 'signup-' || u || '@members.example.test' from (select u1 u from fx union all select u2 from fx union all select u3 from fx union all select u4 from fx union all select u_staff from fx) x;

-- ---- access
select is((select count(*)::int from unnest(array['public.signup_enabled()', 'public.signup_allocate_member_no()',
  'public.signup_create(text,text,text,text,text,text,text,date,text,text,uuid)']) f
  where has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute')), 0, 'no client or anonymous role can call the sign-up functions');
select is(has_function_privilege('service_role', 'public.signup_create(text,text,text,text,text,text,text,date,text,text,uuid)', 'execute'), true, 'the Edge Function (service_role) can');
select is(core.signup_enabled(), true, 'sign-up is on by default');

-- ---- allocation
create temp table n1 as select core.signup_allocate_member_no() as no;
grant select on n1 to public;
select matches((select no from n1), '^CPC-20[0-9]{2}-[0-9]{5}$', 'a member number in the current year is allocated');
select isnt(core.signup_allocate_member_no(), (select no from n1), 'the next one is different');
select is((select count(*)::int from public.members where member_no = (select no from n1)), 0, 'and not in use');
select is(substr((select no from n1), 5, 4), to_char(now() at time zone 'Asia/Manila', 'YYYY'), 'the year is the Manila year');

-- an existing member's number is never handed out: occupy the next two numbers, then allocate
insert into public.persons (id, org_id, display_name, date_of_birth, mobile) values
  ((select per_old from fx), (select org from fx), 'Fake Old Member', '1980-01-02', '09170000001'),
  ('01H0000000000000000000PRS2', (select org from fx), 'Fake Holder Two', '1981-01-02', '09170000002'),
  ('01H0000000000000000000PRS3', (select org from fx), 'Fake Holder Three', '1982-01-02', '09170000003');
insert into public.members (id, org_id, person_id, member_no, status) values
  ((select mem_old from fx), (select org from fx), (select per_old from fx), substr((select no from n1), 1, 9) || lpad(((substr((select no from n1), 10)::int) + 2)::text, 5, '0'), 'imported'),
  ('01H0000000000000000000MEM2', (select org from fx), '01H0000000000000000000PRS2', substr((select no from n1), 1, 9) || lpad(((substr((select no from n1), 10)::int) + 3)::text, 5, '0'), 'imported');
select is(core.signup_allocate_member_no(), substr((select no from n1), 1, 9) || lpad(((substr((select no from n1), 10)::int) + 4)::text, 5, '0'), 'numbers held by existing members are skipped');

-- ---- a sign-up
create temp table s1 as select core.signup_create((select no from n1), 'Fake', 'Mid', 'Applicant', 'Jr.', 'Fake Applicant', 'male', '1995-04-05', '09171112222', 'fake@example.test', (select u1 from fx)) as r;
grant select on s1 to public;
select ok((select (r ->> 'member_id') is not null from s1), 'the member is created');
select is((select status from public.members where member_no = (select no from n1)), 'pending_approval', 'with status pending_approval');
select is((select status_reason from public.members where member_no = (select no from n1)), 'new sign-up', 'and the reason');
select is((select joined_on from public.members where member_no = (select no from n1)), (now() at time zone 'Asia/Manila')::date, 'joined today (Manila)');
select is((select r.code from public.org_members om join public.profiles p on p.id = om.profile_id join public.roles r on r.id = om.role_id where p.auth_user_id = (select u1 from fx)), 'pending_member', 'the applicant holds only the pending role');
select is((select count(*)::int from public.role_permissions rp join public.roles r on r.id = rp.role_id where r.code = 'pending_member' and rp.deleted_at is null), 0, 'the pending role has no permissions');
select is((select must_change_password from public.member_access a join public.members m on m.id = a.member_id where m.member_no = (select no from n1)), false, 'the applicant chose their own password: no forced change');
select is((select p.first_name || '|' || p.middle_name || '|' || p.last_name || '|' || p.suffix || '|' || p.gender from public.persons p join public.members m on m.person_id = p.id where m.member_no = (select no from n1)), 'Fake|Mid|Applicant|Jr.|male', 'the name parts and gender are stored');
select is((select p.mobile from public.persons p join public.members m on m.person_id = p.id where m.member_no = (select no from n1)), '09171112222', 'and the mobile');
select is((select count(*)::int from public.consents c join public.persons p on p.id = c.person_id join public.members m on m.person_id = p.id where m.member_no = (select no from n1)), 2, 'a waiver and a privacy consent are recorded');
select is((select string_agg(c.kind || ':' || c.doc_version, ',' order by c.kind) from public.consents c join public.members m on m.person_id = c.person_id where m.member_no = (select no from n1)), 'privacy:2026-1,waiver:2026-1', 'with the versions from settings');
select is((select count(*)::int from public.member_review_flags where member_id = (select (r ->> 'member_id') from s1)), 0, 'a clean sign-up has no review flags');
select ok(exists(select 1 from core.audit_log where action = 'signup.created' and record_id = (select (r ->> 'member_id') from s1)), 'the sign-up is audited');
select is((select count(*)::int from core.audit_log where table_name = 'public.persons' and new_values ->> 'date_of_birth' is not null and new_values ->> 'date_of_birth' <> '***'), 0, 'birth dates are masked in the audit log');
select throws_ok(format($f$select core.signup_create(%L, 'X', null, 'Y', null, 'X Y', null, '1990-01-01', '09170000009', null, gen_random_uuid())$f$, (select no from n1)), '23505', null, 'the same member number cannot be used twice');

-- ---- duplicate flags
create temp table s2 as select core.signup_create(core.signup_allocate_member_no(), 'Fake', null, 'Old Member', null, 'Fake Old Member', null, '1980-01-02', '09179998888', null, (select u2 from fx)) as r;
grant select on s2 to public;
select is((select r -> 'flags' ->> 0 from s2), 'possible_duplicate_name_dob', 'the same name and birth date as a member is flagged');
select is((select count(*)::int from public.member_review_flags where member_id = (select (r ->> 'member_id') from s2) and related_member_id = (select mem_old from fx) and kind = 'possible_duplicate_name_dob'), 1, 'pointing at the existing member');
select is((select status from public.members where id = (select (r ->> 'member_id') from s2)), 'pending_approval', 'but the sign-up is still accepted for review');
create temp table s3 as select core.signup_create(core.signup_allocate_member_no(), 'Other', null, 'Person', null, 'Other Person', null, '1999-09-09', '09170000001', null, (select u3 from fx)) as r;
grant select on s3 to public;
select is((select r -> 'flags' ->> 0 from s3), 'possible_duplicate_mobile', 'the same mobile number as a member is flagged');
create temp table s4 as select core.signup_create(core.signup_allocate_member_no(), 'Young', null, 'Player', null, 'Young Player', null, ((now() at time zone 'Asia/Manila')::date - interval '12 years')::date, '09170000777', null, (select u4 from fx)) as r;
grant select on s4 to public;
select is((select count(*)::int from public.member_review_flags where member_id = (select (r ->> 'member_id') from s4) and kind = 'minor'), 1, 'a minor is flagged');
select is((select count(*)::int from public.member_review_flags where member_id = (select (r ->> 'member_id') from s1) and kind = 'minor'), 0, 'an adult is not');
select throws_ok(format($f$insert into public.member_review_flags (org_id, member_id, kind) values (%L, %L, 'unknown')$f$, (select org from fx), (select (r ->> 'member_id') from s4)), '23514', null, 'flag kinds are checked');
select throws_ok(format($f$insert into public.member_review_flags (org_id, member_id, kind) values (%L, %L, 'minor')$f$, (select org from fx), (select (r ->> 'member_id') from s4)), '23505', null, 'a flag is recorded once');

-- ---- who can read the flags
insert into public.profiles (id, org_id, auth_user_id) values (core.ulid(), (select org from fx), (select u_staff from fx));
insert into public.org_members (org_id, profile_id, role_id)
  select (select org from fx), p.id, r.id from public.profiles p, public.roles r where p.auth_user_id = (select u_staff from fx) and r.org_id = (select org from fx) and r.code = 'admin';
select pg_temp.as_user((select u_staff from fx));
set local role authenticated;
select cmp_ok((select count(*)::int from public.member_review_flags), '>=', 3, 'an admin (members.approve) reads the flags');
reset role;
select pg_temp.as_user((select u1 from fx));
set local role authenticated;
select is((select count(*)::int from public.member_review_flags), 0, 'an applicant cannot read the flags');
select throws_ok($$update public.member_review_flags set resolved_at = now()$$, '42501', null, 'or change them');
reset role;

-- ---- setting off
update public.settings set value = 'false'::jsonb where key = 'members.signup_enabled' and deleted_at is null;
select is(core.signup_enabled(), false, 'sign-up can be switched off in settings');

select * from finish();
rollback;
