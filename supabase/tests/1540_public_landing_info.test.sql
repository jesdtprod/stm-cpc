begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as e1, core.ulid() as e2, core.ulid() as e3, core.ulid() as e4, core.ulid() as e5,
  core.ulid() as c1, core.ulid() as c2, core.ulid() as c3,
  current_date as today;
grant select on fx to public;

-- events: a draft and a cancelled one stay private; a finished one is gone; the rest are public
insert into public.events (id, org_id, doc_no, name, starts_on, ends_on, location, fee, payload_hash)
select e, (select org from fx), '', n, (select today from fx) + d, (select today from fx) + d + 1, 'Zzyzx Hall', f, repeat('a', 64)
from (values ((select e1 from fx), 'Zzyzx Open', 10, 250), ((select e2 from fx), 'Zzyzx Draft', 11, 0), ((select e3 from fx), 'Zzyzx Cancelled', 12, 0),
             ((select e4 from fx), 'Zzyzx Past', -10, 0)) v(e, n, d, f);
update public.events set status = 'registration_open' where id = (select e1 from fx);
update public.events set status = 'cancelled', cancelled_at = now(), cancel_reason = 'test' where id = (select e3 from fx);
update public.events set status = 'registration_open' where id = (select e4 from fx);

-- courts: one open with hours, one closed, one deleted
insert into public.courts (id, org_id, code, name, status, surface, indoor, sort_order) values
  ((select c1 from fx), (select org from fx), 'zz-open', 'Zzyzx Court 1', 'available', 'Acrylic', true, 900),
  ((select c2 from fx), (select org from fx), 'zz-shut', 'Zzyzx Court 2', 'closed', 'Acrylic', true, 901),
  ((select c3 from fx), (select org from fx), 'zz-gone', 'Zzyzx Court 3', 'available', 'Acrylic', true, 902);
set local session_replication_role = replica;
update public.courts set deleted_at = now(), deleted_by = 'test', delete_reason = 'test' where id = (select c3 from fx);
set local session_replication_role = origin;
insert into public.court_hours (org_id, court_id, weekday, opens_at, closes_at, valid_from)
select (select org from fx), (select c1 from fx), d, '07:00', '22:00', '2000-01-01' from generate_series(0, 6) d;

-- a member whose private details must never appear
insert into public.persons (id, org_id, kind, display_name, email, mobile)
values (core.ulid(), (select org from fx), 'member', 'Zzyzx Privateperson', 'zzyzx.private@example.test', '09170000099');

set local role anon;
create temp table li as select public.public_landing_info() as j;
reset role;
grant select on li to public;

select is(has_function_privilege('anon', 'public.public_landing_info()', 'execute'), true, 'anyone can read the landing information');
select is((select array_agg(k order by k) from li, jsonb_object_keys(j) k), array['courts', 'events', 'leaderboard_public', 'results_public'], 'it has four parts: events, courts and two flags for the public pages');
select is((select count(*)::int from li, jsonb_array_elements(j -> 'events') e where e ->> 'name' = 'Zzyzx Open'), 1, 'an event open to the club is shown');
select is((select count(*)::int from li, jsonb_array_elements(j -> 'events') e where e ->> 'name' in ('Zzyzx Draft', 'Zzyzx Cancelled', 'Zzyzx Past')), 0, 'a draft, a cancelled and a past event are not');
select is((select array_agg(k order by k) from li, jsonb_array_elements(j -> 'events') e, jsonb_object_keys(e) k where e ->> 'name' = 'Zzyzx Open'),
  array['ends_on', 'fee', 'location', 'name', 'starts_on', 'status'], 'an event shows only its name, dates, place, status and fee');
select is((select (e ->> 'fee')::numeric from li, jsonb_array_elements(j -> 'events') e where e ->> 'name' = 'Zzyzx Open'), 250::numeric, 'the fee is public');
select is((select count(*)::int from li, jsonb_array_elements(j -> 'courts') c where c ->> 'name' = 'Zzyzx Court 1'), 1, 'a bookable court is shown');
select is((select count(*)::int from li, jsonb_array_elements(j -> 'courts') c where c ->> 'name' in ('Zzyzx Court 2', 'Zzyzx Court 3')), 0, 'a closed and a deleted court are not');
select is((select c -> 'hours' ->> 'opens' || '-' || (c -> 'hours' ->> 'closes') || ' ' || (c -> 'hours' ->> 'days') from li, jsonb_array_elements(j -> 'courts') c where c ->> 'name' = 'Zzyzx Court 1'), '07:00-22:00 7', 'with its opening hours');
select is((select array_agg(k order by k) from li, jsonb_array_elements(j -> 'courts') c, jsonb_object_keys(c) k where c ->> 'name' = 'Zzyzx Court 1'),
  array['hours', 'indoor', 'name', 'surface'], 'a court shows only its name, setting, surface and hours');
select is(position('zzyzx.private' in (select j::text from li)), 0, 'no email address anywhere in it');
select is(position('09170000099' in (select j::text from li)), 0, 'no phone number');
select is(position('Privateperson' in (select j::text from li)), 0, 'no member name');
select ok((select length(j::text) from li) < 20000, 'and it is small enough to load fast');

select * from finish();
rollback;
