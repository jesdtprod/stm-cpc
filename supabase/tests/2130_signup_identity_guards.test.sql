begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

create temp table fx as select (select id from public.orgs where code = 'cpc' and deleted_at is null) org,
  core.ulid() per, core.ulid() mem;
insert into public.persons(id, org_id, kind, display_name, mobile)
select per, org, 'member', 'Testlastname, Testfirstname Middle', '+63 917 800 4321' from fx;
insert into public.members(id, org_id, person_id, member_no, status)
select mem, org, per, 'TEST-IDENTITY-IMPORTED', 'imported' from fx;

select is(core.member_mobile_key('+63 917 800 4321'), '09178004321', 'country prefix and spaces normalize');
select is(core.member_mobile_key('9178004321'), '09178004321', 'missing zero normalizes');
select is(core.signup_identity_conflict('09178004321','New','Person','New Person'), 'mobile_taken', 'mobile blocks even with a different name');
select is(core.signup_identity_conflict('09178004322','testfirstname','testlastname','testfirstname testlastname'), 'imported_member', 'reversed imported display name with a middle name blocks');
select is(core.signup_identity_conflict('09178004322','Other','Name','TESTLASTNAME TESTFIRSTNAME MIDDLE'), 'imported_member', 'display-name match ignores case punctuation and order');
select is(core.signup_identity_conflict('09178004322','Testfirst','Testlastname','Testfirst Testlastname'), null::text, 'partial name words do not match');
select is(core.signup_identity_conflict('09178004322','Unrelated','Applicant','Unrelated Applicant'), null::text, 'new identity can register');
select throws_ok($$insert into public.persons(org_id, kind, display_name, mobile)
  select org, 'member', 'Other Mobile Applicant', '9178004321' from fx$$,
  '23505', 'mobile_taken', 'direct writes cannot bypass duplicate mobile rule');
select lives_ok($$update public.persons set display_name = 'Testlastname, Testfirstname Middle' where id = (select per from fx)$$, 'unchanged legacy details can be saved');
select throws_ok($$select core.signup_create('TEST-IDENTITY-REJECTED', 'Testfirstname', null, 'Testlastname', null,
  'Testfirstname Testlastname', null, '1990-01-01', '09178004322', null, gen_random_uuid())$$,
  '23505', 'imported_member', 'signup_create enforces imported name rejection without Edge preflight');
select is((select count(*)::int from public.members where member_no = 'TEST-IDENTITY-REJECTED'), 0, 'rejection creates no member');
select is(has_function_privilege('anon','public.signup_identity_conflict(text,text,text,text)','execute'), false, 'anonymous cannot probe identities');
select is(has_function_privilege('authenticated','public.signup_identity_conflict(text,text,text,text)','execute'), false, 'members cannot probe identities');
select is(has_function_privilege('service_role','public.signup_identity_conflict(text,text,text,text)','execute'), true, 'only service can preflight');

-- Registration must ignore a missing or abbreviated middle name in imported display names.
-- Fake equivalents of the requested first + middle + last-name examples.
update public.persons set display_name = 'Testfirstname Testlastname' where id = (select per from fx);
select throws_ok($$select core.signup_create('TEST-MIDDLE-ABSENT', 'Testfirstname', 'Testmiddle', 'Testlastname', null,
  'Testfirstname Testlastname', null, '1990-01-01', '09178004322', null, gen_random_uuid())$$,
  '23505', 'imported_member', 'registration with a full middle name rejects imported First Last');
update public.persons set display_name = 'Testfirstname T. Testlastname' where id = (select per from fx);
select throws_ok($$select core.signup_create('TEST-MIDDLE-DOTTED', 'Testfirstname', 'Testmiddle', 'Testlastname', null,
  'Testfirstname Testlastname', null, '1990-01-01', '09178004322', null, gen_random_uuid())$$,
  '23505', 'imported_member', 'registration with a full middle name rejects imported First M. Last');
update public.persons set display_name = 'Testfirstname T Testlastname' where id = (select per from fx);
select throws_ok($$select core.signup_create('TEST-MIDDLE-INITIAL', 'Testfirstname', 'Testmiddle', 'Testlastname', null,
  'Testfirstname Testlastname', null, '1990-01-01', '09178004322', null, gen_random_uuid())$$,
  '23505', 'imported_member', 'registration with a full middle name rejects imported First M Last');
select is(core.signup_identity_conflict('09178004322','Testfirstname','Differentlastname','Testfirstname Differentlastname'), null::text, 'the same first name with a different last name is allowed');
select is(core.signup_identity_conflict('09178004322','Differentfirstname','Testlastname','Differentfirstname Testlastname'), null::text, 'the same last name with a different first name is allowed');

-- Structured imported names are checked even if the display name is a nickname.
update public.persons set first_name = 'Structuredfirst', last_name = 'Structuredlast', display_name = 'Test Nickname'
where id = (select per from fx);
select is(core.signup_identity_conflict('09178004322','Structuredfirst','Structuredlast','Structuredfirst Structuredlast'), 'imported_member', 'first and last names match independently of the display name');
select * from finish();
rollback;
