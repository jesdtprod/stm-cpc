begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create temp table fx as select gen_random_uuid() as u1, gen_random_uuid() as u2;
grant select on fx to public;
insert into auth.users (id, email) values ((select u1 from fx), 'reassign-1@members.example.test'), ((select u2 from fx), 'reassign-2@members.example.test');

select is((select count(*)::int from unnest(array[
    'public.import_allocate_member_no(text,text,text,date,text[])',
    'public.import_member(text,integer,text,text,date,text,text,text,uuid,timestamptz,text)']) f
  where has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute')), 0, 'no client or anonymous role can allocate numbers or import');
select is((select count(*)::int from pg_proc where proname = 'import_member' and pronamespace = 'public'::regnamespace), 1, 'there is one import_member (the old signature was replaced)');

create temp table b as select core.import_begin(repeat('c', 64), 3) as id;
grant select on b to public;

-- ---- allocation
create temp table a1 as select core.import_allocate_member_no((select id from b), 'CPC-2026-00001', 'Fake Shared Person', '1999-05-06') as r;
grant select on a1 to public;
select matches((select r ->> 'member_no' from a1), '^CPC-2026-[0-9]{5}$', 'a new number in the same year is allocated');
select is((select (r ->> 'existing')::boolean from a1), false, 'for someone not yet reassigned');
select is((select count(*)::int from public.members where member_no = (select r ->> 'member_no' from a1)), 0, 'and it is not in use');
select isnt((core.import_allocate_member_no((select id from b), 'CPC-2026-00001', 'Another Person', null) ->> 'member_no'), (select r ->> 'member_no' from a1), 'the next allocation is a different number');
select matches((core.import_allocate_member_no((select id from b), 'CPC-2027-00005', 'Fake Next Year', null) ->> 'member_no'), '^CPC-2027-[0-9]{5}$', 'the year of the claimed ID is kept');
select throws_ok($$select core.import_allocate_member_no('01H0000000000000000000NOPE', 'CPC-2026-00001', 'x', null)$$, '22023', null, 'an unknown batch is refused');

-- a number taken by an existing member is skipped
insert into public.persons (id, org_id, display_name) values ('01H0000000000000000000PRS1', (select id from public.orgs where code = 'cpc'), 'Fake Holder');
insert into public.members (org_id, person_id, member_no, status) values ((select id from public.orgs where code = 'cpc'), '01H0000000000000000000PRS1', 'CPC-2028-00001', 'imported');
select is((core.import_allocate_member_no((select id from b), 'CPC-2028-00009', 'Fake Skip Test', null) ->> 'member_no'), 'CPC-2028-00002', 'allocation skips numbers that are already used');

-- ---- importing under the new number records the old one
select is((core.import_member((select id from b), 20, (select r ->> 'member_no' from a1), 'Fake Shared Person', '1999-05-06', null, null, null, (select u1 from fx), now() + interval '30 days', 'CPC-2026-00001') ->> 'outcome'), 'created', 'the member is created under the new number');
select is((select m.member_no from public.members m where m.import_row = 20 and m.import_batch_id = (select id from b)), (select r ->> 'member_no' from a1), 'with that number');
select is((select i.member_no_claimed from public.member_import_issues i join public.members m on m.id = i.member_id where m.import_row = 20 and i.issue_code = 'member_no_reassigned'), 'CPC-2026-00001', 'the issue list remembers the ID the row claimed');
select is((select count(*)::int from public.members where member_no = 'CPC-2026-00001' and import_row = 20), 0, 'and the original ID was not taken');

-- ---- a re-run finds the same person and allocates nothing
select is((core.import_allocate_member_no((select id from b), 'CPC-2026-00001', 'Fake Shared Person', '1999-05-06') ->> 'existing')::boolean, true, 'the same person is found again');
select is((core.import_allocate_member_no((select id from b), 'CPC-2026-00001', 'Fake Shared Person', '1999-05-06') ->> 'member_no'), (select r ->> 'member_no' from a1), 'with the same number');
select is((core.import_allocate_member_no((select id from b), 'CPC-2026-00001', 'Fake Shared Person', '1999-05-07') ->> 'existing')::boolean, false, 'a different birth date is a different person');
select is((core.import_allocate_member_no((select id from b), 'CPC-2026-00001', 'Fake Shared Person', null) ->> 'existing')::boolean, false, 'and so is a missing one');

-- ---- reserved numbers are never handed out; existing_people tells who holds a number
create temp table r1 as select core.import_allocate_member_no((select id from b), 'CPC-2029-00009', 'Fake Reserved Test', null, array['CPC-2029-00001', 'CPC-2029-00002', 'CPC-2029-00004']) as r;
grant select on r1 to public;
select is((select r ->> 'member_no' from r1), 'CPC-2029-00003', 'the allocator steps over reserved numbers');
select is((core.import_allocate_member_no((select id from b), 'CPC-2029-00009', 'Fake Reserved Test Two', null, array['CPC-2029-00001', 'CPC-2029-00002', 'CPC-2029-00004']) ->> 'member_no'), 'CPC-2029-00005', 'and the next one skips 00004 too');
select is((select count(*)::int from core.import_existing_people(array['CPC-2028-00001', 'CPC-2028-99999'])), 1, 'import_existing_people returns only numbers that exist');
select is((select display_name from core.import_existing_people(array['CPC-2028-00001'])), 'Fake Holder', 'with the holder''s name');
select is((select date_of_birth from core.import_existing_people(array['CPC-2028-00001'])), null, 'and birth date');
select is(has_function_privilege('authenticated', 'public.import_existing_people(text[])', 'execute'), false, 'clients cannot ask who holds a number');

-- ---- the issue code is accepted, others are still checked
select lives_ok(format($f$select core.import_issue(%L, 30, 'CPC-2026-00001', 'member_no_reassigned')$f$, (select id from b)), 'member_no_reassigned is a known issue code');
select throws_ok(format($f$select core.import_issue(%L, 31, null, 'something_else')$f$, (select id from b)), '23514', null, 'unknown codes are still refused');

select * from finish();
rollback;
