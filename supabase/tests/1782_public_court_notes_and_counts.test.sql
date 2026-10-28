begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();
create temp table fx as select (select id from public.orgs where code='cpc') as org,
 core.ulid() as court,core.ulid() as closed,core.ulid() as gone,core.ulid() as person,core.ulid() as member,core.ulid() as booking;
grant select on fx to public;
insert into public.courts(id,org_id,code,name,notes) select court,org,'fake-public-counts','Fake Public Counts Court',E'Bring non-marking shoes.\nKeep the gate closed.' from fx;
insert into public.courts(id,org_id,code,name,status) select closed,org,'fake-closed-counts','Fake Closed Counts Court','closed' from fx;
insert into public.courts(id,org_id,code,name,deleted_at,deleted_by,delete_reason) select gone,org,'fake-deleted-counts','Fake Deleted Counts Court',now(),'test','fake fixture' from fx;
insert into public.court_hours(org_id,court_id,weekday,opens_at,closes_at,valid_from)
select org,court,n,'08:00','23:59','2000-01-01' from fx cross join generate_series(0,6) n;
update public.settings set value='60' where org_id=(select org from fx) and key='booking.slot_minutes' and unit_id is null and deleted_at is null;
create function pg_temp.counts(p_asof timestamptz) returns table(vacant integer,occupied integer) language sql as $$
 select * from core.public_court_slot_counts((select org from fx),(select court from fx),'2030-01-07',p_asof)
$$;
select is((select vacant from pg_temp.counts('2030-01-07T00:00:00+08:00')),16,'midnight closing includes the final 11 PM slot');
select is((select vacant from pg_temp.counts('2030-01-07T09:30:00+08:00')),14,'vacancy excludes elapsed slots');
select is((select vacant from pg_temp.counts('2030-01-07T23:00:00+08:00')),0,'a slot starting now is no longer vacant');
insert into public.persons(id,org_id,display_name) select person,org,'Fake Private Booker' from fx;
insert into public.members(id,org_id,person_id,member_no) select member,org,person,'CPC-2097-00001' from fx;
update public.members set status='invited' where id=(select member from fx);
update public.members set status='pending_approval' where id=(select member from fx);
update public.members set status='active' where id=(select member from fx);
insert into public.bookings(id,org_id,doc_no,court_id,requested_by_member_id,during,rate_snapshot,price_snapshot,court_name_snapshot,payload_hash)
select booking,org,'FAKE-COUNTS-1',court,member,tstzrange('2030-01-07T10:00:00+08:00','2030-01-07T12:00:00+08:00','[)'),0,0,'Fake Public Counts Court',repeat('a',64) from fx;
select is((select occupied from pg_temp.counts('2030-01-07T09:30:00+08:00')),2,'one two-hour reservation occupies two slots');
select is((select vacant from pg_temp.counts('2030-01-07T09:30:00+08:00')),12,'reserved slots are not vacant');
update public.bookings set status='cancelled',cancelled_at=now(),status_reason='fake cancellation' where id=(select booking from fx);
select is((select occupied from pg_temp.counts('2030-01-07T09:30:00+08:00')),0,'cancelled reservations do not occupy slots');
insert into public.court_blackouts(org_id,court_id,during,reason)
select org,court,tstzrange('2030-01-07T13:00:00+08:00','2030-01-07T14:00:00+08:00','[)'),'Fake private maintenance reason' from fx;
select is((select vacant from pg_temp.counts('2030-01-07T09:30:00+08:00')),13,'blackouts are excluded from vacant slots');
select is((select occupied from pg_temp.counts('2030-01-07T09:30:00+08:00')),0,'blackouts do not count as occupied bookings');
update public.settings set value='30' where org_id=(select org from fx) and key='booking.slot_minutes' and unit_id is null and deleted_at is null;
select is((select vacant from pg_temp.counts('2030-01-07T00:00:00+08:00')),30,'counts respect configured 30-minute slots');
update public.court_hours set valid_to='2028-12-31' where court_id=(select court from fx) and weekday=1;
insert into public.court_hours(org_id,court_id,weekday,opens_at,closes_at,valid_from)
select org,court,1,'09:00','12:00','2029-01-01' from fx;
select is((select vacant from pg_temp.counts('2030-01-07T00:00:00+08:00')),6,'latest court-specific hours take precedence');
set local role anon;
create temp table response as select public.public_courts() as data;
select is((select c->>'notes' from response,jsonb_array_elements(data->'courts') c where c->>'name'='Fake Public Counts Court'),E'Bring non-marking shoes.\nKeep the gate closed.','public cards receive multiline court notes');
select is((select count(*)::integer from response,jsonb_array_elements(data->'courts') c where c->>'name' in('Fake Closed Counts Court','Fake Deleted Counts Court')),0,'closed and deleted courts stay private');
select is((select array_agg(k order by k) from response,jsonb_array_elements(data->'courts') c,jsonb_object_keys(c) k where c->>'name'='Fake Public Counts Court'),array['availability','hours','indoor','name','notes','surface'],'only approved public court fields are returned');
select is((select array_agg(k order by k) from response,jsonb_array_elements(data->'courts') c,jsonb_object_keys(c->'availability') k where c->>'name'='Fake Public Counts Court'),array['day','occupied','vacant'],'availability exposes only the day and counts');
select ok(not exists(select 1 from response,jsonb_array_elements(data->'courts') c where c->'availability'->>'day' is distinct from ((now() at time zone 'Asia/Manila')::date)::text),'counts use today in Manila');
select is(position('Fake Private Booker' in (select data::text from response)),0,'no booker names are published');
select is(position('Fake private maintenance reason' in (select data::text from response)),0,'no blackout reasons are published');
reset role;
select is(has_function_privilege('anon','core.public_court_slot_counts(text,text,date,timestamptz)','execute'),false,'parameterized counting helper stays private');
select * from finish();
rollback;
