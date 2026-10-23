begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create temp table fx as select (select id from public.orgs where code = 'cpc') as org, gen_random_uuid() as u1,
  core.ulid() as per1, core.ulid() as per2, core.ulid() as per3, core.ulid() as per4;
grant select on fx to public;

-- ---- the reference data (loaded by scripts/seed-psgc.mjs)
select cmp_ok((select count(*)::int from public.psgc_areas where level = 'region'), '>=', 17, 'regions are loaded');
select cmp_ok((select count(*)::int from public.psgc_areas where level = 'province'), '>=', 81, 'provinces are loaded');
select cmp_ok((select count(*)::int from public.psgc_areas where level = 'city_muni'), '>=', 1600, 'cities and municipalities are loaded');
select cmp_ok((select count(*)::int from public.psgc_areas where level = 'barangay'), '>=', 42000, 'barangays are loaded');
select is((select count(*)::int from public.psgc_areas c where c.level <> 'region'
  and not exists (select 1 from public.psgc_areas p where p.org_id = c.org_id and p.code = c.parent_code)), 0, 'every area has its parent');
select is((select count(*)::int from public.psgc_areas where level = 'barangay'
  and parent_code not in (select code from public.psgc_areas where level = 'city_muni')), 0, 'every barangay hangs under a city or municipality');
select is((select count(*)::int from public.psgc_areas where level = 'province' and parent_code <> region_code), 0, 'a province hangs under its region');
select is((select count(*)::int from public.psgc_areas where level = 'city_muni' and parent_code <> coalesce(province_code, region_code)), 0, 'a city hangs under its province, or its region when it has none');
select is((select count(*)::int from public.psgc_areas where region_code = '130000000' and level = 'province'), 0, 'Metro Manila has no provinces');
select is((select count(*)::int from pg_trigger where tgrelid = 'public.psgc_areas'::regclass and tgname = 'z_audit'), 0, 'bulk reference data is not audited row by row');
select throws_ok(format($f$insert into public.psgc_areas (org_id, code, level, name, parent_code, region_code) values (%L, 'abc', 'region', 'x', null, 'x')$f$, (select org from fx)),
  '23514', null, 'a PSGC code is nine digits');
select throws_ok(format($f$insert into public.psgc_areas (org_id, code, level, name, parent_code, region_code) values (%L, '130000000', 'region', 'again', null, '130000000')$f$, (select org from fx)),
  '23505', null, 'a code appears once per org');
select throws_ok(format($f$insert into public.psgc_areas (org_id, code, level, name, parent_code, region_code) values (%L, '991000000', 'barangay', 'orphan', null, '130000000')$f$, (select org from fx)),
  '23514', null, 'only a region may lack a parent');
select throws_ok(format($f$delete from public.psgc_areas where org_id = %L$f$, (select org from fx)), '42501', null, 'reference rows cannot be hard-deleted');

-- ---- address on persons: derived from the deepest code
insert into public.persons (id, org_id, display_name, street_line, barangay_code)
  values ((select per1 from fx), (select org from fx), 'Fake Address One', '  12 Sample St.  ', '137401001');
select is((select street_line from public.persons where id = (select per1 from fx)), '12 Sample St.', 'the street line is trimmed');
select is((select city_muni_code from public.persons where id = (select per1 from fx)), '137401000', 'the city is filled from the barangay');
select is((select region_code from public.persons where id = (select per1 from fx)), '130000000', 'the region is filled from the barangay');
select is((select province_code from public.persons where id = (select per1 from fx)), null, 'Metro Manila has no province code');
select is((select address_text from public.persons where id = (select per1 from fx)),
  '12 Sample St., Addition Hills, City of Mandaluyong, Metro Manila', 'the text snapshot reads street, barangay, city, Metro Manila');

-- a provincial address: pick any barangay that has a province
create temp table pb as select b.code as brgy, b.parent_code as city, b.province_code as prov, b.region_code as reg
  from public.psgc_areas b where b.level = 'barangay' and b.province_code is not null order by b.code limit 1;
grant select on pb to public;
insert into public.persons (id, org_id, display_name, barangay_code) values ((select per2 from fx), (select org from fx), 'Fake Address Two', (select brgy from pb));
select is((select province_code from public.persons where id = (select per2 from fx)), (select prov from pb), 'the province is filled from the barangay');
select is((select city_muni_code from public.persons where id = (select per2 from fx)), (select city from pb), 'the city is filled from the barangay (provincial)');
select ok((select address_text from public.persons where id = (select per2 from fx)) = (
  select concat_ws(', ', b.name, c.name, p.name) from public.psgc_areas b
  join public.psgc_areas c on c.code = b.parent_code join public.psgc_areas p on p.code = b.province_code where b.code = (select brgy from pb)), 'the text snapshot names barangay, city and province');

-- city only and street only
insert into public.persons (id, org_id, display_name, city_muni_code) values ((select per3 from fx), (select org from fx), 'Fake Address Three', '137401000');
select is((select address_text from public.persons where id = (select per3 from fx)), 'City of Mandaluyong, Metro Manila', 'a city-level address is allowed');
select is((select barangay_code from public.persons where id = (select per3 from fx)), null, 'and leaves the barangay empty');
insert into public.persons (id, org_id, display_name, street_line) values ((select per4 from fx), (select org from fx), 'Fake Address Four', 'Unit 5, Somewhere');
select is((select address_text from public.persons where id = (select per4 from fx)), 'Unit 5, Somewhere', 'a street-only address is allowed');

-- bad combinations
select throws_ok(format($f$insert into public.persons (org_id, display_name, barangay_code, city_muni_code) values (%L, 'x', '137401001', %L)$f$, (select org from fx), (select city from pb)),
  '22023', null, 'a city that does not contain the barangay is rejected');
select throws_ok(format($f$insert into public.persons (org_id, display_name, barangay_code, province_code) values (%L, 'x', '137401001', %L)$f$, (select org from fx), (select prov from pb)),
  '22023', null, 'a province that does not contain the barangay is rejected');
select throws_ok(format($f$insert into public.persons (org_id, display_name, barangay_code) values (%L, 'x', '999999999')$f$, (select org from fx)),
  '22023', null, 'an unknown code is rejected');
select throws_ok(format($f$insert into public.persons (org_id, display_name, street_line) values (%L, 'x', %L)$f$, (select org from fx), repeat('x', 201)),
  '23514', null, 'a street line is at most 200 characters');

-- changes re-derive; unrelated edits leave the address alone
update public.persons set barangay_code = (select brgy from pb) where id = (select per1 from fx);
select is((select region_code from public.persons where id = (select per1 from fx)), (select reg from pb), 'changing the barangay moves the higher codes with it');
select lives_ok(format($f$update public.persons set barangay_code = '137401001' where id = %L$f$, (select per1 from fx)), 'changing only the barangay re-derives the stale higher codes');
select is((select city_muni_code from public.persons where id = (select per1 from fx)), '137401000', 'and the city follows the new barangay');
select is((select province_code from public.persons where id = (select per1 from fx)), null, 'and the province is cleared for Metro Manila');
update public.persons set barangay_code = (select brgy from pb) where id = (select per1 from fx);
select throws_ok(format($f$update public.persons set barangay_code = '137401001', city_muni_code = '133900000' where id = %L$f$, (select per1 from fx)),
  '22023', null, 'changing the barangay and the city to values that do not match is rejected');
update public.persons set city_muni_code = '137401000' where id = (select per1 from fx);
select is((select barangay_code from public.persons where id = (select per1 from fx)), null, 'changing only the city clears the barangay that no longer fits');
update public.persons set barangay_code = null, city_muni_code = null, province_code = null, region_code = null where id = (select per1 from fx);
select is((select address_text from public.persons where id = (select per1 from fx)), '12 Sample St.', 'clearing the codes leaves the street line');
update public.persons set display_name = 'Fake Renamed' where id = (select per1 from fx);
select is((select address_text from public.persons where id = (select per1 from fx)), '12 Sample St.', 'an unrelated edit keeps the address text');

-- ---- audit masks the address
select ok(not exists(select 1 from core.audit_log where table_name = 'public.persons' and record_id = (select per1 from fx)
  and (new_values ->> 'address_text' not in ('***') or new_values ->> 'street_line' not in ('***'))), 'address and street are masked in audit_log');
select ok(exists(select 1 from core.audit_log where table_name = 'public.persons' and record_id = (select per1 from fx)
  and new_values ->> 'address_text' = '***'), 'and the audit row exists');

-- ---- access
select is(has_table_privilege('anon', 'public.psgc_areas', 'select'), false, 'anon cannot read psgc_areas');
select is(has_any_column_privilege('authenticated', 'public.psgc_areas', 'insert') or has_any_column_privilege('authenticated', 'public.psgc_areas', 'update'),
  false, 'clients cannot write psgc_areas');
select is(has_column_privilege('authenticated', 'public.persons', 'barangay_code', 'update'), true, 'clients may update the address codes');
select is(has_column_privilege('authenticated', 'public.persons', 'address_text', 'insert'), true, 'the address text column is in the client grant (the trigger overwrites it)');

insert into auth.users (id, email) values ((select u1 from fx), 'addr@example.test');
insert into public.profiles (id, org_id, auth_user_id) values (core.ulid(), (select org from fx), (select u1 from fx));
insert into public.org_members (org_id, profile_id, role_id)
  select (select org from fx), p.id, r.id from public.profiles p, public.roles r where p.auth_user_id = (select u1 from fx) and r.org_id = (select org from fx) and r.code = 'member';
select set_config('request.jwt.claims', json_build_object('sub', (select u1 from fx), 'role', 'authenticated')::text, true);
set local role authenticated;
select cmp_ok((select count(*)::int from public.psgc_areas where level = 'region'), '>=', 17, 'an org member can read the address list');
select throws_ok($$insert into public.psgc_areas (org_id, code, level, name, region_code) values (core.ulid(), '123456789', 'region', 'x', 'x')$$, '42501', null, 'a member cannot add areas');
reset role;

select * from finish();
rollback;
