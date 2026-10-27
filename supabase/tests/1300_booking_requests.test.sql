begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as court, core.ulid() as court2,
  core.ulid() as b1, core.ulid() as b2, core.ulid() as b3, core.ulid() as b4, core.ulid() as b5, core.ulid() as b6,
  core.ulid() as b7, core.ulid() as b8, core.ulid() as b9, core.ulid() as b10, core.ulid() as b11, core.ulid() as b12,
  core.ulid() as bx1, core.ulid() as bx2, core.ulid() as bx3,
  core.ulid() as k1, core.ulid() as k2, core.ulid() as k3, core.ulid() as k4, core.ulid() as k5, core.ulid() as k6,
  core.ulid() as k7, core.ulid() as k8, core.ulid() as k9, core.ulid() as k10, core.ulid() as k11, core.ulid() as k12,
  core.ulid() as k13, core.ulid() as k14, core.ulid() as k15, core.ulid() as k16,
  -- tomorrow 10:00 Manila, and the next full hour
  (date_trunc('day', now() at time zone 'Asia/Manila') + interval '1 day 10 hours') at time zone 'Asia/Manila' as tomorrow10,
  (date_trunc('hour', now() at time zone 'Asia/Manila') + interval '1 hour') at time zone 'Asia/Manila' as next_hour;
grant select on fx to public;

create function pg_temp.mk(p_role text, p_no text, p_status text) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); mid text := core.ulid(); org text := (select id from public.orgs where code = 'cpc');
begin
  insert into auth.users (id, email) values (u, lower(p_no) || '@members.example.test');
  insert into public.persons (id, org_id, display_name) values (per, org, 'Fake ' || p_no);
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (org, pid, (select id from public.roles where org_id = org and code = p_role));
  insert into public.members (id, org_id, person_id, profile_id, member_no) values (mid, org, per, pid, p_no);
  update public.members set status = 'invited' where id = mid;
  update public.members set status = 'pending_approval' where id = mid;
  if p_status = 'active' then update public.members set status = 'active' where id = mid; end if;
  return u;
end $$;
create temp table us(role text primary key, u uuid, mid text);
grant select on us to public;
insert into us select 'member', pg_temp.mk('member', 'CPC-2026-9301', 'active'), null;
insert into us select 'friend', pg_temp.mk('member', 'CPC-2026-9302', 'active'), null;
insert into us select 'other', pg_temp.mk('member', 'CPC-2026-9303', 'active'), null;
insert into us select 'waiting', pg_temp.mk('member', 'CPC-2026-9304', 'pending'), null;
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2026-9305', 'active'), null;
insert into us select 'desk', pg_temp.mk('front_desk', 'CPC-2026-9306', 'active'), null;
update us set mid = (select id from public.members where member_no = case us.role when 'member' then 'CPC-2026-9301' when 'friend' then 'CPC-2026-9302'
  when 'other' then 'CPC-2026-9303' when 'waiting' then 'CPC-2026-9304' when 'admin' then 'CPC-2026-9305' else 'CPC-2026-9306' end);

-- a court open every day, 200 an hour, with the settings the tests rely on
insert into public.courts (id, org_id, code, name) values ((select court from fx), (select org from fx), 't11-court', 'T11 Court');
insert into public.court_hours (org_id, court_id, weekday, opens_at, closes_at, valid_from)
select (select org from fx), (select court from fx), d, '00:00', '23:59:59', '2000-01-01' from generate_series(0, 6) d;
insert into public.court_rates (org_id, court_id, rate_per_hour, valid_from) values ((select org from fx), (select court from fx), 200, '2000-01-01');
update public.settings set value = '60'::jsonb where key = 'booking.slot_minutes' and unit_id is null and deleted_at is null;
update public.settings set value = '14'::jsonb where key = 'booking.advance_days' and unit_id is null and deleted_at is null;
update public.settings set value = '4'::jsonb where key = 'booking.max_participants' and unit_id is null and deleted_at is null;
update public.settings set value = '24'::jsonb where key = 'booking.request_expiry_hours' and unit_id is null and deleted_at is null;
update public.settings set value = '24'::jsonb where key = 'booking.cancel_cutoff_hours' and unit_id is null and deleted_at is null;
update public.settings set value = '0'::jsonb where key in ('booking.cancel_fee', 'booking.no_show_fee') and unit_id is null and deleted_at is null;
update public.settings set value = 'true'::jsonb where key = 'booking.approval_required' and unit_id is null and deleted_at is null;
update public.settings set value = 'false'::jsonb where key = 'payments.required.court_booking' and unit_id is null and deleted_at is null;

-- ---- access
select is(has_function_privilege('anon', 'public.request_booking(text,text,timestamptz,integer,text[])', 'execute'), false, 'anonymous callers cannot book');
select is(has_function_privilege('authenticated', 'public.expire_bookings()', 'execute'), false, 'members cannot run the expiry themselves');

-- ---- a request
select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
create temp table r1 as select public.request_booking((select b1 from fx), (select court from fx), (select tomorrow10 from fx), 60, array[(select mid from us where role = 'friend')]) as r;
reset role;
grant select on r1 to public;
select is((select r ->> 'status' from r1), 'pending_approval', 'a request waits for approval');
select is((select (r ->> 'price')::numeric from r1), 200::numeric, 'one hour at 200 costs 200');
select ok((select r ->> 'doc_no' from r1) ~ '^BK-\d{4}-\d{5}$', 'it gets a booking number');
select is((select count(*)::int from public.booking_participants where booking_id = (select b1 from fx)), 2, 'the requester and the friend are the players');
select is((select price_snapshot from public.bookings where id = (select b1 from fx)), 200::numeric, 'the price is copied into the booking');
select ok((select expires_at from public.bookings where id = (select b1 from fx)) > now() + interval '23 hours', 'it expires after the set time');

-- ---- the same request again, and a different one under the same ID
select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
select is((select public.request_booking((select b1 from fx), (select court from fx), (select tomorrow10 from fx), 60, array[(select mid from us where role = 'friend')]) ->> 'id'), (select b1 from fx), 'sending the same request again returns the same booking');
select throws_ok(format($f$select public.request_booking(%L, %L, %L, 60, '{}')$f$, (select b1 from fx), (select court from fx), (select tomorrow10 from fx)), 'CP422', null, 'another request under the same ID is refused');
select is((select count(*)::int from public.bookings where court_id = (select court from fx)), 1, 'still one booking');
reset role;

-- ---- the slot is taken
select pg_temp.as_user((select u from us where role = 'other'));
set local role authenticated;
select throws_ok(format($f$select public.request_booking(%L, %L, %L, 60, '{}')$f$, (select b2 from fx), (select court from fx), (select tomorrow10 from fx)), '23P01', 'that time was just taken; choose another slot', 'an overlapping request loses');
-- ---- the other rules
select throws_ok(format($f$select public.request_booking(%L, %L, %L, 60, '{}')$f$, (select b3 from fx), (select court from fx), (select tomorrow10 from fx) + interval '5 hours 30 minutes'), '22023', null, 'a start off the slot grid is refused');
select throws_ok(format($f$select public.request_booking(%L, %L, %L, 90, '{}')$f$, (select b3 from fx), (select court from fx), (select tomorrow10 from fx) + interval '5 hours'), '22023', null, 'a length that is not whole slots is refused');
select throws_ok(format($f$select public.request_booking(%L, %L, now() - interval '2 hours', 60, '{}')$f$, (select b3 from fx), (select court from fx)), '22023', 'choose a time in the future', 'a time in the past is refused');
select throws_ok(format($f$select public.request_booking(%L, %L, %L, 60, '{}')$f$, (select b3 from fx), (select court from fx), (select tomorrow10 from fx) + interval '20 days'), '22023', null, 'beyond the booking window is refused');
select throws_ok(format($f$select public.request_booking(%L, %L, %L, 60, array[%L, %L, %L, %L])$f$, (select b3 from fx), (select court from fx), (select tomorrow10 from fx) + interval '5 hours',
  (select mid from us where role = 'friend'), (select mid from us where role = 'admin'), (select mid from us where role = 'desk'), (select mid from us where role = 'member')), '22023', 'a booking can have at most 4 players', 'too many players are refused');
select throws_ok(format($f$select public.request_booking(%L, %L, %L, 60, array[%L])$f$, (select b3 from fx), (select court from fx), (select tomorrow10 from fx) + interval '5 hours', (select mid from us where role = 'waiting')), '22023', 'every player must be an active member', 'a player who is not an active member is refused');
select throws_ok(format($f$select public.request_booking(%L, %L, %L, 60, '{}')$f$, (select b3 from fx), core.ulid(), (select tomorrow10 from fx) + interval '5 hours'), '22023', 'the court is not available for booking', 'an unknown court is refused');
reset role;
select pg_temp.as_user((select u from us where role = 'waiting'));
set local role authenticated;
select throws_ok(format($f$select public.request_booking(%L, %L, %L, 60, '{}')$f$, (select b3 from fx), (select court from fx), (select tomorrow10 from fx) + interval '6 hours'), '42501', null, 'a member who is not active cannot book');
reset role;
-- a blackout
insert into public.court_blackouts (org_id, court_id, during, reason)
values ((select org from fx), (select court from fx), tstzrange((select tomorrow10 from fx) + interval '8 hours', (select tomorrow10 from fx) + interval '10 hours', '[)'), 'resurfacing');
select pg_temp.as_user((select u from us where role = 'other'));
set local role authenticated;
select throws_ok(format($f$select public.request_booking(%L, %L, %L, 60, '{}')$f$, (select b3 from fx), (select court from fx), (select tomorrow10 from fx) + interval '8 hours'), '22023', 'the court is closed during that time', 'a blackout blocks the slot');
reset role;
-- hours: close the court at 21:00 for the day after tomorrow
update public.court_hours set closes_at = '21:00' where court_id = (select court from fx) and weekday = extract(dow from (select tomorrow10 from fx) + interval '1 day')::int;
select pg_temp.as_user((select u from us where role = 'other'));
set local role authenticated;
select throws_ok(format($f$select public.request_booking(%L, %L, %L, 60, '{}')$f$, (select b3 from fx), (select court from fx), (select tomorrow10 from fx) + interval '1 day 11 hours'), '22023', null, 'a time after closing is refused');
reset role;

-- ---- approval
select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
select throws_ok(format($f$select public.decide_booking(%L, 'approve', null, %L)$f$, (select b1 from fx), (select k1 from fx)), '42501', null, 'a member cannot approve');
reset role;
select pg_temp.as_user((select u from us where role = 'desk'));
set local role authenticated;
select throws_ok(format($f$select public.decide_booking(%L, 'approve', null, %L)$f$, (select b1 from fx), (select k1 from fx)), '42501', null, 'front desk cannot approve either');
reset role;

-- payment required: no verified payment, no approval
update public.settings set value = 'true'::jsonb where key = 'payments.required.court_booking' and unit_id is null and deleted_at is null;
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select throws_ok(format($f$select public.decide_booking(%L, 'approve', null, %L)$f$, (select b1 from fx), (select k2 from fx)), '22023', 'the payment has not been verified yet', 'an unpaid booking cannot be approved when payment is required');
reset role;
update public.settings set value = 'false'::jsonb where key = 'payments.required.court_booking' and unit_id is null and deleted_at is null;

select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
create temp table d1 as select public.decide_booking((select b1 from fx), 'approve', null, (select k3 from fx)) as r;
reset role;
grant select on d1 to public;
select is((select status from public.bookings where id = (select b1 from fx)), 'confirmed', 'the admin confirms it');
select is((select amount from public.ledger_entries where source_type = 'booking' and source_id = (select b1 from fx) and client_ref = 'charge'), -200.0000::numeric, 'the price is charged to the member');
set local role authenticated;
select is((select public.decide_booking((select b1 from fx), 'approve', null, (select k3 from fx))), (select r from d1), 'the same key replays');
select is((select (public.decide_booking((select b1 from fx), 'approve', null, (select k4 from fx))) ->> 'unchanged'), 'true', 'approving twice changes nothing');
reset role;
select is((select count(*)::int from public.ledger_entries where source_type = 'booking' and source_id = (select b1 from fx) and client_ref = 'charge'), 1, 'and the charge is posted once');

-- ---- reject frees the slot
select pg_temp.as_user((select u from us where role = 'other'));
set local role authenticated;
select public.request_booking((select b4 from fx), (select court from fx), (select tomorrow10 from fx) + interval '4 hours', 60, '{}');
reset role;
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select throws_ok(format($f$select public.decide_booking(%L, 'reject', '', %L)$f$, (select b4 from fx), (select k5 from fx)), '22023', 'a reason is required', 'a rejection needs a reason');
select is((select public.decide_booking((select b4 from fx), 'reject', 'court needed for a clinic', (select k6 from fx)) ->> 'status'), 'rejected', 'the admin rejects');
reset role;
select pg_temp.as_user((select u from us where role = 'friend'));
set local role authenticated;
select is((select public.request_booking((select b5 from fx), (select court from fx), (select tomorrow10 from fx) + interval '4 hours', 60, '{}') ->> 'status'), 'pending_approval', 'the freed slot can be booked again');
reset role;

-- ---- expiry frees the slot
update public.bookings set expires_at = now() - interval '1 minute' where id = (select b5 from fx);
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select throws_ok(format($f$select public.decide_booking(%L, 'approve', null, %L)$f$, (select b5 from fx), (select k7 from fx)), '22023', 'this request has expired and its time was released', 'an expired request cannot be approved');
reset role;
select cmp_ok((select public.expire_bookings()), '>=', 1, 'the scheduler expires it');
select is((select status from public.bookings where id = (select b5 from fx)), 'expired', 'it is marked expired');
select pg_temp.as_user((select u from us where role = 'other'));
set local role authenticated;
select is((select public.request_booking((select b6 from fx), (select court from fx), (select tomorrow10 from fx) + interval '4 hours', 60, '{}') ->> 'status'), 'pending_approval', 'and the slot is free again');
reset role;
select is((select public.expire_bookings()), 0, 'the scheduler finds nothing more to expire');

-- ---- cancel
select pg_temp.as_user((select u from us where role = 'friend'));
set local role authenticated;
select throws_ok(format($f$select public.cancel_booking(%L, 'changed my mind', %L)$f$, (select b1 from fx), (select k8 from fx)), '42501', null, 'a player who is not the requester cannot cancel');
reset role;
update public.settings set value = '50'::jsonb where key = 'booking.cancel_fee' and unit_id is null and deleted_at is null;
select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
create temp table c1 as select public.cancel_booking((select b1 from fx), 'changed my mind', (select k9 from fx)) as r;
reset role;
grant select on c1 to public;
select is((select status from public.bookings where id = (select b1 from fx)), 'cancelled', 'the requester cancels a confirmed booking');
select is((select amount from public.ledger_entries where source_type = 'booking' and source_id = (select b1 from fx) and client_ref = 'charge-reversal'), 200.0000::numeric, 'the charge is reversed');
select is((select count(*)::int from public.ledger_entries where source_type = 'booking' and source_id = (select b1 from fx) and client_ref = 'cancel-fee'), 0, 'no fee more than 24 hours ahead');
select is((select sum(amount) from public.ledger_entries where source_type = 'booking' and source_id = (select b1 from fx)), 0.0000::numeric, 'the member owes nothing for it');
set local role authenticated;
select is((select public.cancel_booking((select b1 from fx), 'changed my mind', (select k9 from fx))), (select r from c1), 'the same key replays');
select is((select (public.cancel_booking((select b1 from fx), 'changed my mind', (select k10 from fx))) ->> 'unchanged'), 'true', 'cancelling twice changes nothing');
reset role;
select is((select count(*)::int from public.ledger_entries where source_type = 'booking' and source_id = (select b1 from fx) and client_ref = 'charge-reversal'), 1, 'and the refund appears once');

-- inside the cut-off the member pays the late fee
select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
select public.request_booking((select b7 from fx), (select court from fx), (select tomorrow10 from fx) + interval '3 hours', 60, '{}');
reset role;
update public.settings set value = '72'::jsonb where key = 'booking.cancel_cutoff_hours' and unit_id is null and deleted_at is null;
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select public.decide_booking((select b7 from fx), 'approve', null, (select k11 from fx));
reset role;
select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
select is((select (public.cancel_booking((select b7 from fx), null, (select k12 from fx)) ->> 'fee')::numeric), 50::numeric, 'cancelling inside the cut-off charges the late fee');
reset role;
select is((select amount from public.ledger_entries where source_type = 'booking' and source_id = (select b7 from fx) and client_ref = 'cancel-fee'), -50.0000::numeric, 'as a charge in the ledger');

-- staff cancel without a fee, with a reason
select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
select public.request_booking((select b8 from fx), (select court from fx), (select tomorrow10 from fx) + interval '2 hours', 60, '{}');
reset role;
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select public.decide_booking((select b8 from fx), 'approve', null, (select k13 from fx));
select throws_ok(format($f$select public.cancel_booking(%L, '', %L)$f$, (select b8 from fx), core.ulid()), '22023', 'a reason is required', 'staff must give a reason');
select is((select (public.cancel_booking((select b8 from fx), 'court flooded', core.ulid()) ->> 'fee')::numeric), 0::numeric, 'staff cancelling never charges the fee');
reset role;

-- ---- check-in, no-show, complete (rows inserted directly so that the times can be near or past)
insert into public.courts (id, org_id, code, name) values ((select court2 from fx), (select org from fx), 't11-court2', 'T11 Court Two');
insert into public.bookings (id, org_id, doc_no, court_id, requested_by_member_id, during, rate_snapshot, price_snapshot, court_name_snapshot, payload_hash)
values ((select b9 from fx), (select org from fx), 'T11-BK-9', (select court2 from fx), (select mid from us where role = 'member'),
  tstzrange(now() - interval '3 hours', now() - interval '2 hours', '[)'), 0, 0, 'T11 Court Two', repeat('1', 64)),
 ((select b10 from fx), (select org from fx), 'T11-BK-10', (select court2 from fx), (select mid from us where role = 'member'),
  tstzrange(now() + interval '20 minutes', now() + interval '80 minutes', '[)'), 0, 0, 'T11 Court Two', repeat('2', 64)),
 ((select b11 from fx), (select org from fx), 'T11-BK-11', (select court2 from fx), (select mid from us where role = 'member'),
  tstzrange(now() + interval '6 hours', now() + interval '7 hours', '[)'), 0, 0, 'T11 Court Two', repeat('3', 64));
update public.bookings set status = 'confirmed', approved_at = now(), approved_by = 'test' where id in ((select b9 from fx), (select b10 from fx), (select b11 from fx));
update public.settings set value = '75'::jsonb where key = 'booking.no_show_fee' and unit_id is null and deleted_at is null;
select pg_temp.as_user((select u from us where role = 'desk'));
set local role authenticated;
select throws_ok(format($f$select public.decide_booking(%L, 'check_in', null, %L)$f$, (select b11 from fx), core.ulid()), '22023', null, 'check-in is refused when it is hours too early');
select is((select public.decide_booking((select b10 from fx), 'check_in', null, core.ulid()) ->> 'status'), 'checked_in', 'front desk checks a member in within the hour before');
select is((select public.decide_booking((select b10 from fx), 'complete', null, core.ulid()) ->> 'status'), 'completed', 'and completes the booking');
select throws_ok(format($f$select public.decide_booking(%L, 'no_show', null, %L)$f$, (select b11 from fx), core.ulid()), '22023', null, 'a no-show cannot be marked before the start');
select is((select public.decide_booking((select b9 from fx), 'no_show', 'did not arrive', (select k14 from fx)) ->> 'status'), 'no_show', 'a booking that has passed can be a no-show');
reset role;
select is((select amount from public.ledger_entries where source_type = 'booking' and source_id = (select b9 from fx) and client_ref = 'no-show-fee'), -75.0000::numeric, 'with the no-show fee charged');

-- ---- instant confirmation when the club does not approve by hand
update public.settings set value = 'false'::jsonb where key = 'booking.approval_required' and unit_id is null and deleted_at is null;
select pg_temp.as_user((select u from us where role = 'other'));
set local role authenticated;
select is((select public.request_booking((select b12 from fx), (select court from fx), (select tomorrow10 from fx) + interval '1 day 6 hours', 60, '{}') ->> 'status'), 'confirmed', 'with approval switched off a paid-or-free request is confirmed at once');
reset role;
select is((select amount from public.ledger_entries where source_type = 'booking' and source_id = (select b12 from fx) and client_ref = 'charge'), -200.0000::numeric, 'and charged');
update public.settings set value = 'true'::jsonb where key = 'payments.required.court_booking' and unit_id is null and deleted_at is null;
select pg_temp.as_user((select u from us where role = 'other'));
set local role authenticated;
select is((select public.request_booking((select bx1 from fx), (select court from fx), (select tomorrow10 from fx) + interval '2 days 7 hours', 60, '{}') ->> 'status'), 'pending_approval', 'but it waits when payment is required and not yet verified');
reset role;

select * from finish();
rollback;
