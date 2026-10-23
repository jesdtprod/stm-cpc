begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create temp table fx as select (select id from public.orgs where code = 'cpc') as org, core.ulid() as p1, core.ulid() as p2, core.ulid() as m1, core.ulid() as m2;
grant select on fx to public;
insert into public.persons (id, org_id, display_name, date_of_birth) values
  ((select p1 from fx), (select org from fx), 'Fake Enrich One', '1990-01-01'),
  ((select p2 from fx), (select org from fx), 'Fake Enrich Two', '1991-01-01');
insert into public.members (id, org_id, person_id, member_no, status) values
  ((select m1 from fx), (select org from fx), (select p1 from fx), 'CPC-2026-97201', 'imported'),
  ((select m2 from fx), (select org from fx), (select p2 from fx), 'CPC-2026-97202', 'imported');

select is((select count(*)::int from unnest(array['public.import_enrich_person(text,text,text,text,text,text,text,text,text)', 'public.import_find_reassigned(text,text,date)']) f
  where has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute')), 0, 'no client or anonymous role can enrich or look up');

-- ---- fills empty fields
select is(core.import_enrich_person('CPC-2026-97201', 'Fake', 'Mid', 'One', 'Jr.', 'male', 'Fake Contact', 'Parent', '09175550001'), true, 'a member with empty details is enriched');
select is((select p.first_name || '|' || p.middle_name || '|' || p.last_name || '|' || p.suffix || '|' || p.gender from public.persons p where p.id = (select p1 from fx)), 'Fake|Mid|One|Jr.|male', 'name parts, suffix and gender are filled');
select is((select p.emergency_name || '|' || p.emergency_relationship || '|' || p.emergency_phone from public.persons p where p.id = (select p1 from fx)), 'Fake Contact|Parent|09175550001', 'and the emergency contact');
select is((select p.display_name from public.persons p where p.id = (select p1 from fx)), 'Fake Enrich One', 'the display name is never touched');

-- ---- never overwrites
select is(core.import_enrich_person('CPC-2026-97201', 'Other', 'Other', 'Other', 'Sr.', 'female', 'Other Contact', 'Friend', '09175550002'), false, 'a second run with different values changes nothing');
select is((select p.first_name from public.persons p where p.id = (select p1 from fx)), 'Fake', 'the stored first name is kept');
select is((select p.emergency_name from public.persons p where p.id = (select p1 from fx)), 'Fake Contact', 'and the stored emergency contact');

-- partial: only the empty fields are filled
update public.persons set first_name = 'Edited', gender = null where id = (select p2 from fx);
select is(core.import_enrich_person('CPC-2026-97202', 'Fake', null, 'Two', null, 'female', null, null, null), true, 'a partly filled member is topped up');
select is((select p.first_name || '|' || p.last_name || '|' || p.gender from public.persons p where p.id = (select p2 from fx)), 'Edited|Two|female', 'what the member entered stays, empty fields are filled');
select is((select emergency_name from public.persons where id = (select p2 from fx)), null, 'no emergency contact is invented');

-- emergency contact only as a pair
create temp table x as select core.import_enrich_person('CPC-2026-97202', null, null, null, null, null, 'Only Name', 'Friend', null) as r;
select is((select r from x), false, 'a name without a number is not stored');
select is((select emergency_name from public.persons where id = (select p2 from fx)), null, 'so the emergency name stays empty');

-- unknown or deleted members
select is(core.import_enrich_person('CPC-2026-99998', 'A', null, 'B', null, null, null, null, null), false, 'an unknown member number is ignored');

-- ---- bad values are refused by the table
select throws_ok($$select core.import_enrich_person('CPC-2026-97202', null, null, null, 'Esq', null, null, null, null)$$, '23514', null, 'a suffix outside the list is refused by the table');

-- ---- lookup of a reassigned member
create temp table b as select core.import_begin(repeat('d', 64), 1) as id;
grant select on b to public;
select core.import_member((select id from b), 9, 'CPC-2026-97299', 'Fake Moved Person', '1999-09-09', null, null, null, null, null, 'CPC-2026-97200');
select is(core.import_find_reassigned('CPC-2026-97200', 'Fake Moved Person', '1999-09-09'), 'CPC-2026-97299', 'a reassigned member is found by the ID it claimed, its name and birth date');
select is(core.import_find_reassigned('CPC-2026-97200', 'Fake Moved Person', '1999-09-10'), null, 'a different birth date finds nobody');
select is(core.import_find_reassigned('CPC-2026-97200', 'Someone Else', '1999-09-09'), null, 'and a different name finds nobody');

select * from finish();
rollback;
