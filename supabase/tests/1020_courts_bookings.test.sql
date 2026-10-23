begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create function pg_temp.mk(p_org text, p_role text, p_person text default null) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := coalesce(p_person, core.ulid()); rid text;
begin
  select id into rid from public.roles where org_id = p_org and code = p_role;
  insert into auth.users (id, email) values (u, p_role || '-' || u || '@example.test');
  if p_person is null then
    insert into public.persons (id, org_id, display_name) values (per, p_org, 'Fake ' || p_role);
  end if;
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, p_org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (p_org, pid, rid);
  return u;
end $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as court1, core.ulid() as court2, core.ulid() as court_mx,
  core.ulid() as per1, core.ulid() as per2, core.ulid() as per3, core.ulid() as per4,
  core.ulid() as mem1, core.ulid() as mem2, core.ulid() as mem3, core.ulid() as mem_pending,
  core.ulid() as bk1, core.ulid() as bk2, core.ulid() as bk3;
grant select on fx to public;

insert into public.persons (id, org_id, display_name) values
  ((select per1 from fx), (select org from fx), 'Fake Player One'), ((select per2 from fx), (select org from fx), 'Fake Player Two'),
  ((select per3 from fx), (select org from fx), 'Fake Player Three'), ((select per4 from fx), (select org from fx), 'Fake Pending');
insert into public.members (id, org_id, person_id, member_no, status) values
  ((select mem1 from fx), (select org from fx), (select per1 from fx), 'CPC-2026-91001', 'pending_approval'),
  ((select mem2 from fx), (select org from fx), (select per2 from fx), 'CPC-2026-91002', 'pending_approval'),
  ((select mem3 from fx), (select org from fx), (select per3 from fx), 'CPC-2026-91003', 'pending_approval'),
  ((select mem_pending from fx), (select org from fx), (select per4 from fx), 'CPC-2026-91004', 'pending_approval');
update public.members set status = 'active' where id in ((select mem1 from fx), (select mem2 from fx), (select mem3 from fx));

-- ---- structure
select is((select count(*)::int from pg_class where relnamespace = 'public'::regnamespace and relrowsecurity
  and relname in ('courts', 'court_hours', 'court_rates', 'court_blackouts', 'bookings', 'booking_events', 'booking_participants')), 7, 'RLS is on for all seven tables');
select is((select count(*)::int from pg_class c where c.relnamespace = 'public'::regnamespace
  and c.relname in ('courts', 'court_hours', 'court_rates', 'court_blackouts', 'bookings', 'booking_events', 'booking_participants')
  and obj_description(c.oid, 'pg_class') like 'class: %'), 7, 'every table has a class comment');

-- ---- courts, hours, rates, blackouts
insert into public.courts (id, org_id, code, name, surface, indoor) values
  ((select court1 from fx), (select org from fx), 'court-1', 'Court 1', 'acrylic', false),
  ((select court2 from fx), (select org from fx), 'court-2', 'Court 2', 'acrylic', true);
insert into public.courts (id, org_id, code, name, status) values ((select court_mx from fx), (select org from fx), 'court-3', 'Court 3', 'maintenance');
select throws_ok(format($f$insert into public.courts (org_id, code, name) values (%L, 'court-1', 'Duplicate')$f$, (select org from fx)),
  '23505', null, 'a court code is unique among active courts');
select throws_ok(format($f$insert into public.courts (org_id, code, name, status) values (%L, 'court-9', 'Nine', 'broken')$f$, (select org from fx)),
  '23514', null, 'court status is checked');

insert into public.court_hours (org_id, court_id, weekday, opens_at, closes_at, valid_from) values ((select org from fx), null, 1, '06:00', '22:00', '2026-01-01');
select throws_ok(format($f$insert into public.court_hours (org_id, court_id, weekday, opens_at, closes_at, valid_from) values (%L, null, 1, '07:00', '21:00', '2026-06-01')$f$, (select org from fx)),
  '23P01', null, 'two hour windows for the same weekday cannot overlap in time of validity');
select lives_ok(format($f$insert into public.court_hours (org_id, court_id, weekday, opens_at, closes_at, valid_from) values (%L, %L, 1, '07:00', '21:00', '2026-06-01')$f$, (select org from fx), (select court1 from fx)),
  'a court-specific window is separate from the all-courts window');
select lives_ok(format($f$insert into public.court_hours (org_id, court_id, weekday, opens_at, closes_at, valid_from, valid_to) values (%L, null, 2, '06:00', '12:00', '2026-01-01', '2026-03-31')$f$, (select org from fx)),
  'an effective-dated window is accepted');
select lives_ok(format($f$insert into public.court_hours (org_id, court_id, weekday, opens_at, closes_at, valid_from) values (%L, null, 2, '08:00', '20:00', '2026-04-01')$f$, (select org from fx)),
  'the next window starts the day after the previous ends');
select throws_ok(format($f$insert into public.court_hours (org_id, weekday, opens_at, closes_at, valid_from) values (%L, 3, '22:00', '06:00', '2026-01-01')$f$, (select org from fx)),
  '23514', null, 'closing time must be after opening time');
select throws_ok(format($f$insert into public.court_hours (org_id, weekday, opens_at, closes_at, valid_from) values (%L, 7, '06:00', '22:00', '2026-01-01')$f$, (select org from fx)),
  '23514', null, 'weekday is 0 to 6');

select lives_ok(format($f$insert into public.court_rates (org_id, court_id, rate_per_hour, valid_from) values (%L, null, 150.00, '2026-01-01')$f$, (select org from fx)), 'a rate is accepted');
select throws_ok(format($f$insert into public.court_rates (org_id, rate_per_hour, valid_from) values (%L, -1, '2026-01-01')$f$, (select org from fx)), '23514', null, 'a rate cannot be negative');
select throws_ok(format($f$insert into public.court_rates (org_id, rate_per_hour, valid_from, from_time, to_time) values (%L, 100, '2026-01-01', '18:00', '17:00')$f$, (select org from fx)),
  '23514', null, 'a rate window must run forward');

insert into public.court_blackouts (org_id, court_id, during, reason)
  values ((select org from fx), (select court2 from fx), tstzrange('2026-12-24 08:00+08', '2026-12-24 12:00+08'), 'Maintenance');
select throws_ok(format($f$insert into public.court_blackouts (org_id, during, reason) values (%L, tstzrange('2026-12-25 12:00+08', '2026-12-25 08:00+08'), 'x')$f$, (select org from fx)),
  '22000', null, 'a blackout range must run forward');
select throws_ok(format($f$insert into public.court_blackouts (org_id, during, reason) values (%L, tstzrange('2026-12-25 08:00+08', '2026-12-25 12:00+08'), '  ')$f$, (select org from fx)),
  '23514', null, 'a blackout needs a reason');

-- ---- bookings: insert rules
insert into public.bookings (id, org_id, court_id, requested_by_member_id, during, payload_hash, rate_snapshot, price_snapshot, court_name_snapshot)
  values ((select bk1 from fx), (select org from fx), (select court1 from fx), (select mem1 from fx),
    tstzrange('2026-11-02 09:00+08', '2026-11-02 10:00+08'), repeat('a', 64), 150, 150, 'Court 1');
select matches((select doc_no from public.bookings where id = (select bk1 from fx)), '^BK-20[0-9]{2}-[0-9]{5}$', 'the booking number is assigned by the database');
select is((select status from public.bookings where id = (select bk1 from fx)), 'pending_approval', 'a booking starts pending approval');

insert into public.bookings (id, org_id, court_id, requested_by_member_id, during, payload_hash, rate_snapshot, price_snapshot, court_name_snapshot)
  values ((select bk2 from fx), (select org from fx), (select court1 from fx), (select mem2 from fx),
    tstzrange('2026-11-02 10:00+08', '2026-11-02 11:00+08'), repeat('b', 64), 150, 150, 'Court 1');
select pass('a booking that starts exactly when another ends is allowed (half-open ranges)');
select is((select count(distinct doc_no)::int from public.bookings where org_id = (select org from fx) and id in ((select bk1 from fx), (select bk2 from fx))), 2, 'booking numbers are distinct');

select throws_ok(format($f$insert into public.bookings (org_id, court_id, requested_by_member_id, during, payload_hash, rate_snapshot, price_snapshot, court_name_snapshot)
  values (%L, %L, %L, tstzrange('2026-11-02 09:30+08', '2026-11-02 10:30+08'), repeat('c', 64), 150, 150, 'Court 1')$f$,
  (select org from fx), (select court1 from fx), (select mem3 from fx)), '23P01', null, 'an overlapping booking of the same court is refused');
select throws_ok(format($f$insert into public.bookings (org_id, court_id, requested_by_member_id, during, payload_hash, rate_snapshot, price_snapshot, court_name_snapshot)
  values (%L, %L, %L, tstzrange('2026-11-02 08:00+08', '2026-11-02 12:00+08'), repeat('c', 64), 150, 150, 'Court 1')$f$,
  (select org from fx), (select court1 from fx), (select mem3 from fx)), '23P01', null, 'a booking that contains existing ones is refused');
select lives_ok(format($f$insert into public.bookings (org_id, court_id, requested_by_member_id, during, payload_hash, rate_snapshot, price_snapshot, court_name_snapshot)
  values (%L, %L, %L, tstzrange('2026-11-02 09:00+08', '2026-11-02 10:00+08'), repeat('c', 64), 150, 150, 'Court 2')$f$,
  (select org from fx), (select court2 from fx), (select mem3 from fx)), 'the same time on another court is fine');

select throws_ok(format($f$insert into public.bookings (org_id, court_id, requested_by_member_id, during, payload_hash, rate_snapshot, price_snapshot, court_name_snapshot)
  values (%L, %L, %L, tstzrange('2026-11-03 09:00+08', '2026-11-03 10:00+08'), repeat('c', 64), 150, 150, 'Court 1')$f$,
  (select org from fx), (select court1 from fx), (select mem_pending from fx)), '22023', null, 'a member who is not active cannot book');
select throws_ok(format($f$insert into public.bookings (org_id, court_id, requested_by_member_id, during, payload_hash, rate_snapshot, price_snapshot, court_name_snapshot)
  values (%L, %L, %L, tstzrange('2026-11-03 09:00+08', '2026-11-03 10:00+08'), repeat('c', 64), 150, 150, 'Court 3')$f$,
  (select org from fx), (select court_mx from fx), (select mem3 from fx)), '22023', null, 'a court under maintenance cannot be booked');
select throws_ok(format($f$insert into public.bookings (org_id, court_id, requested_by_member_id, during, payload_hash, rate_snapshot, price_snapshot, court_name_snapshot)
  values (%L, %L, %L, tstzrange('2026-12-24 10:00+08', '2026-12-24 11:00+08'), repeat('c', 64), 150, 150, 'Court 2')$f$,
  (select org from fx), (select court2 from fx), (select mem3 from fx)), '22023', null, 'a booking inside a blackout is refused');
select throws_ok(format($f$insert into public.bookings (org_id, court_id, requested_by_member_id, during, payload_hash, rate_snapshot, price_snapshot, court_name_snapshot, status)
  values (%L, %L, %L, tstzrange('2026-11-04 09:00+08', '2026-11-04 10:00+08'), repeat('c', 64), 150, 150, 'Court 1', 'confirmed')$f$,
  (select org from fx), (select court1 from fx), (select mem3 from fx)), '22023', null, 'a new booking cannot start confirmed');
select throws_ok(format($f$insert into public.bookings (org_id, court_id, requested_by_member_id, during, payload_hash, rate_snapshot, price_snapshot, court_name_snapshot)
  values (%L, %L, %L, tstzrange('2026-11-05 09:00+08', '2026-11-05 10:00+08'), 'short', 150, 150, 'Court 1')$f$,
  (select org from fx), (select court1 from fx), (select mem3 from fx)), '23514', null, 'the payload hash must be a sha-256 hex string');
select throws_ok(format($f$insert into public.bookings (org_id, court_id, requested_by_member_id, during, payload_hash, rate_snapshot, price_snapshot, court_name_snapshot)
  values (%L, %L, %L, tstzrange('2026-11-05 10:00+08', '2026-11-05 09:00+08'), repeat('c', 64), 150, 150, 'Court 1')$f$,
  (select org from fx), (select court1 from fx), (select mem3 from fx)), '22000', null, 'a booking range must run forward');
select throws_ok(format($f$insert into public.bookings (org_id, court_id, requested_by_member_id, during, payload_hash, rate_snapshot, price_snapshot, court_name_snapshot)
  values (%L, %L, %L, tstzrange('2026-11-05 09:00+08', '2026-11-05 10:00+08'), repeat('c', 64), -5, 150, 'Court 1')$f$,
  (select org from fx), (select court1 from fx), (select mem3 from fx)), '23514', null, 'a rate snapshot cannot be negative');

-- ---- state machine, frozen fields, history
select throws_ok(format($f$update public.bookings set status = 'checked_in', checked_in_at = now() where id = %L$f$, (select bk1 from fx)),
  '22023', null, 'pending cannot jump to checked_in');
select throws_ok(format($f$update public.bookings set status = 'confirmed' where id = %L$f$, (select bk1 from fx)),
  '23514', null, 'confirmed needs approved_at');
select lives_ok(format($f$update public.bookings set status = 'confirmed', approved_at = now(), approved_by = 'system' where id = %L$f$, (select bk1 from fx)), 'pending -> confirmed');
select throws_ok(format($f$update public.bookings set during = tstzrange('2026-11-02 13:00+08', '2026-11-02 14:00+08') where id = %L$f$, (select bk1 from fx)),
  '42501', null, 'the time of a booking cannot be changed');
select throws_ok(format($f$update public.bookings set price_snapshot = 0 where id = %L$f$, (select bk1 from fx)), '42501', null, 'the price snapshot cannot be changed');
select throws_ok(format($f$update public.bookings set court_id = %L where id = %L$f$, (select court2 from fx), (select bk1 from fx)), '42501', null, 'the court cannot be changed');
select lives_ok(format($f$update public.bookings set status = 'checked_in', checked_in_at = now(), checked_in_by = 'system' where id = %L$f$, (select bk1 from fx)), 'confirmed -> checked_in');
select lives_ok(format($f$update public.bookings set status = 'completed' where id = %L$f$, (select bk1 from fx)), 'checked_in -> completed');
select throws_ok(format($f$update public.bookings set status = 'cancelled', cancelled_at = now() where id = %L$f$, (select bk1 from fx)), '22023', null, 'completed is final');
select is((select count(*)::int from public.booking_events where booking_id = (select bk1 from fx)), 4, 'every status change is written to booking_events');
select throws_ok(format($f$delete from public.bookings where id = %L$f$, (select bk1 from fx)), '42501', null, 'a booking cannot be hard-deleted');
select throws_ok(format($f$update public.booking_events set reason = 'x' where booking_id = %L$f$, (select bk1 from fx)), '42501', null, 'booking events cannot be edited');

-- cancelling frees the slot
select lives_ok(format($f$update public.bookings set status = 'cancelled', cancelled_at = now(), cancelled_by = 'system', cancel_reason = 'changed plans' where id = %L$f$, (select bk2 from fx)), 'pending -> cancelled');
select lives_ok(format($f$insert into public.bookings (id, org_id, court_id, requested_by_member_id, during, payload_hash, rate_snapshot, price_snapshot, court_name_snapshot)
  values (%L, %L, %L, %L, tstzrange('2026-11-02 10:00+08', '2026-11-02 11:00+08'), repeat('d', 64), 150, 150, 'Court 1')$f$,
  (select bk3 from fx), (select org from fx), (select court1 from fx), (select mem3 from fx)), 'a cancelled booking frees its time for someone else');
select is((select reason from public.booking_events where booking_id = (select bk2 from fx) and to_status = 'cancelled'), 'changed plans', 'the cancel reason is in the history');
select lives_ok(format($f$update public.bookings set status = 'rejected', status_reason = 'court needed' where id = %L$f$, (select bk3 from fx)), 'pending -> rejected');
select throws_ok(format($f$update public.bookings set status = 'pending_approval' where id = %L$f$, (select bk3 from fx)), '22023', null, 'rejected is final');

-- ---- participants
select lives_ok(format($f$insert into public.booking_participants (org_id, booking_id, member_id) values (%L, %L, %L)$f$, (select org from fx), (select bk1 from fx), (select mem2 from fx)), 'an active member can be added');
select throws_ok(format($f$insert into public.booking_participants (org_id, booking_id, member_id) values (%L, %L, %L)$f$, (select org from fx), (select bk1 from fx), (select mem2 from fx)), '23505', null, 'a member joins a booking once');
select throws_ok(format($f$insert into public.booking_participants (org_id, booking_id, member_id) values (%L, %L, %L)$f$, (select org from fx), (select bk1 from fx), (select mem_pending from fx)), '22023', null, 'a participant must be an active member');
select throws_ok(format($f$update public.booking_participants set member_id = %L where booking_id = %L$f$, (select mem3 from fx), (select bk1 from fx)), '42501', null, 'a participant row cannot be changed');

-- ---- row-level security with real users
create temp table us(role text primary key, u uuid);
grant select on us to public;
insert into us values ('admin', pg_temp.mk((select org from fx), 'admin'));
insert into us values ('manager', pg_temp.mk((select org from fx), 'manager'));
insert into us values ('front_desk', pg_temp.mk((select org from fx), 'front_desk'));
insert into us values ('m1', pg_temp.mk((select org from fx), 'member', (select per1 from fx)));
insert into us values ('m2', pg_temp.mk((select org from fx), 'member', (select per2 from fx)));
insert into us values ('m3', pg_temp.mk((select org from fx), 'member', (select per3 from fx)));
update public.members set profile_id = (select p.id from public.profiles p where p.auth_user_id = (select u from us where role = 'm1')) where id = (select mem1 from fx);
update public.members set profile_id = (select p.id from public.profiles p where p.auth_user_id = (select u from us where role = 'm2')) where id = (select mem2 from fx);
update public.members set profile_id = (select p.id from public.profiles p where p.auth_user_id = (select u from us where role = 'm3')) where id = (select mem3 from fx);

select pg_temp.as_user((select u from us where role = 'm1'));
set local role authenticated;
select cmp_ok((select count(*)::int from public.courts), '>=', 3, 'a member reads the courts');
select cmp_ok((select count(*)::int from public.court_hours), '>=', 1, 'a member reads the operating hours');
select cmp_ok((select count(*)::int from public.court_rates), '>=', 1, 'a member reads the rates');
select is((select count(distinct id)::int from public.bookings), 1, 'the requester sees only their own booking');
select is((select count(*)::int from public.booking_participants), 1, 'and its participants');
select cmp_ok((select count(*)::int from public.booking_events), '>=', 4, 'and its history');
select throws_ok(format($f$insert into public.bookings (org_id, court_id, requested_by_member_id, during, payload_hash, rate_snapshot, price_snapshot, court_name_snapshot)
  values (%L, %L, %L, tstzrange('2026-11-09 09:00+08', '2026-11-09 10:00+08'), repeat('e', 64), 150, 150, 'Court 1')$f$, (select org from fx), (select court1 from fx), (select mem1 from fx)),
  '42501', null, 'a member cannot insert a booking directly');
select throws_ok($$update public.bookings set status = 'confirmed'$$, '42501', null, 'a member cannot approve a booking');
select throws_ok(format($f$insert into public.courts (org_id, code, name) values (%L, 'court-x', 'X')$f$, (select org from fx)), '42501', null, 'a member cannot create a court');
select is((select count(*)::int from public.court_availability('2026-11-02 00:00+08', '2026-11-03 00:00+08') where kind = 'booked' and court_id = (select court2 from fx)), 1,
  'availability shows another member''s live booking as an occupied time');
select is((select count(*)::int from public.court_availability('2026-11-02 00:00+08', '2026-11-03 00:00+08') where kind = 'booked' and court_id = (select court1 from fx)), 0,
  'and leaves out completed, cancelled and rejected bookings');
select is((select count(*)::int from public.court_availability('2026-12-24 00:00+08', '2026-12-25 00:00+08') where kind = 'closed'), 1, 'and blackouts as closed');
select throws_ok($$select * from public.court_availability('2026-01-01', '2027-06-01')$$, '22023', null, 'availability is limited to 62 days');
reset role;

select pg_temp.as_user((select u from us where role = 'm2'));
set local role authenticated;
select is((select count(distinct id)::int from public.bookings), 2, 'a participant sees the booking they play in plus their own');
select ok(exists(select 1 from public.bookings where id = (select bk1 from fx)), 'including the one they were added to');
reset role;

select pg_temp.as_user((select u from us where role = 'm3'));
set local role authenticated;
select is((select count(distinct id)::int from public.bookings), 2, 'another member sees only their own bookings');
select ok(not exists(select 1 from public.bookings where id = (select bk1 from fx)), 'and not someone else''s');
reset role;

select pg_temp.as_user((select u from us where role = 'front_desk'));
set local role authenticated;
select cmp_ok((select count(*)::int from public.bookings), '>=', 4, 'front desk (bookings.read_all) sees all bookings');
select throws_ok(format($f$insert into public.court_blackouts (org_id, during, reason) values (%L, tstzrange('2027-01-01 08:00+08', '2027-01-01 09:00+08'), 'x')$f$, (select org from fx)),
  '42501', null, 'front desk cannot add blackouts');
reset role;

select pg_temp.as_user((select u from us where role = 'manager'));
set local role authenticated;
select lives_ok(format($f$insert into public.courts (org_id, code, name) values (%L, 'court-4', 'Court 4')$f$, (select org from fx)), 'a manager adds a court');
select lives_ok(format($f$update public.courts set status = 'closed' where id = %L$f$, (select court2 from fx)), 'a manager closes a court');
select lives_ok(format($f$insert into public.court_blackouts (org_id, during, reason) values (%L, tstzrange('2027-01-01 08:00+08', '2027-01-01 09:00+08'), 'Tournament setup')$f$, (select org from fx)), 'a manager adds a blackout');
select lives_ok(format($f$insert into public.court_rates (org_id, rate_per_hour, valid_from) values (%L, 200, '2027-01-01')$f$, (select org from fx)), 'a manager adds a rate');
select throws_ok($$update public.bookings set status = 'confirmed'$$, '42501', null, 'even a manager cannot write bookings directly');
reset role;

select is((select has_any_column_privilege('authenticated', 'public.bookings', 'insert') or has_any_column_privilege('authenticated', 'public.bookings', 'update')),
  false, 'clients have no write privilege on bookings');
select is(has_function_privilege('anon', 'public.court_availability(timestamptz,timestamptz)', 'execute'), false, 'anon cannot call court_availability');

select * from finish();
rollback;
