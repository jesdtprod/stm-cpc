begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();
select is(has_function_privilege('anon', 'public.checkin_court_board()', 'execute'), false, 'visitors cannot read court names or bookings');
select is(has_function_privilege('authenticated', 'public.checkin_court_board()', 'execute'), true, 'authenticated callers reach the permission check');
select throws_ok($$select public.checkin_court_board()$$, '42501', 'you do not have permission to view the court board', 'no session is refused');
create temp table fx as select core.ulid() org, core.ulid() other_org, core.ulid() profile,
  core.ulid() person, core.ulid() member, core.ulid() role, gen_random_uuid() auth_user,
  core.ulid() court1, core.ulid() court2, core.ulid() booking1, core.ulid() booking2;
grant select on fx to public;
insert into public.orgs(id, org_id, code, name)
select org, org, 'fake-board-' || lower(right(org, 6)), 'Fake Court Board' from fx
union all select other_org, other_org, 'fake-other-' || lower(right(other_org, 6)), 'Fake Other Club' from fx;
insert into public.roles(id, org_id, code, name) select role, org, 'scanner', 'Fake Scanner' from fx;
insert into public.role_permissions(org_id, role_id, permission_id)
select fx.org, fx.role, pe.id from fx cross join public.permissions pe where pe.code = 'bookings.checkin' and pe.deleted_at is null;
insert into auth.users(id, email) select auth_user, 'fake-board-' || auth_user || '@example.test' from fx;
insert into public.persons(id, org_id, display_name) select person, org, 'Fake Board Player' from fx;
insert into public.profiles(id, org_id, auth_user_id, person_id) select profile, org, auth_user, person from fx;
insert into public.org_members(org_id, profile_id, role_id) select org, profile, role from fx;
insert into public.members(id, org_id, person_id, member_no, status) select member, org, person, 'CPC-2026-99881', 'pending_approval' from fx;
update public.members set status = 'active' where id = (select member from fx);
insert into public.courts(id, org_id, code, name) select court1, org, 'tennis-1', 'Tennis Court 1' from fx
union all select court2, org, 'tennis-2', 'Tennis Court 2' from fx;
insert into public.courts(org_id, code, name) select org, 'other-court', 'Other Court' from fx
union all select other_org, 'tennis-3', 'Tennis Court 3' from fx;
-- One current reservation awaits check-in; court 2 has four future bookings today.
insert into public.bookings(id, org_id, court_id, requested_by_member_id, during, payload_hash, rate_snapshot, price_snapshot, court_name_snapshot)
select booking1, org, court1, member, tstzrange(now() - interval '15 minutes', now() + interval '15 minutes', '[)'), repeat('a',64), 0, 0, 'Tennis Court 1' from fx;
insert into public.bookings(org_id, court_id, requested_by_member_id, during, payload_hash, rate_snapshot, price_snapshot, court_name_snapshot)
select org, court2, member, tstzrange(
  now() + remaining * ((2*n-1)::double precision / 10),
  now() + remaining * ((2*n)::double precision / 10), '[)'), repeat('b',64), 0, 0, 'Tennis Court 2'
from fx cross join generate_series(1,4) n cross join lateral (
  select (((now() at time zone 'Asia/Manila')::date + 1)::timestamp at time zone 'Asia/Manila') - now() as remaining
) bounds;
update public.bookings set status = 'confirmed', approved_at = now() where org_id = (select org from fx);
select set_config('request.jwt.claims', json_build_object('sub', (select auth_user from fx), 'role', 'authenticated')::text, true);
set local role authenticated;
select is(jsonb_array_length(public.checkin_court_board()->'courts'->0->'incoming_bookings'), 1, 'current confirmed booking waits in incoming until scanned');
select is(jsonb_array_length(public.checkin_court_board()->'courts'->1->'incoming_bookings'), 3, 'only three incoming reservations are exposed');
select ok((public.checkin_court_board()->'courts'->1->'incoming_bookings'->0->>'starts_at')::timestamptz <
  (public.checkin_court_board()->'courts'->1->'incoming_bookings'->1->>'starts_at')::timestamptz, 'incoming reservations are ordered by start time');
reset role;
update public.bookings set status = 'checked_in', checked_in_at = now() where id = (select booking1 from fx);
set local role authenticated;
select is(public.checkin_court_board()->'courts'->0->'current_booking'->>'status', 'checked_in', 'scan promotes current reservation to ongoing');
select is(jsonb_array_length(public.checkin_court_board()->'courts'->0->'incoming_bookings'), 0, 'checked-in booking is removed from incoming');
reset role;
-- Cancelling the first future slot automatically advances the next reservation.
update public.bookings set status = 'cancelled', cancelled_at = now(), cancel_reason = 'Fake test cancellation'
where id = (select id from public.bookings where court_id = (select court2 from fx) order by lower(during) limit 1);
set local role authenticated;
select is(jsonb_array_length(public.checkin_court_board()->'courts'->1->'incoming_bookings'), 3, 'queue replenishes after cancellation');
reset role;
select * from finish();
rollback;
