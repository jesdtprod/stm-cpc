begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create temp table fx as select
  (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as court, core.ulid() as court2, core.ulid() as b1, core.ulid() as b2,
  (date_trunc('day', now() at time zone 'Asia/Manila') + interval '3 days') at time zone 'Asia/Manila' as day;
grant select on fx to public;
create function pg_temp.mk(p_no text) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); mid text := core.ulid(); org text := (select org from fx);
begin
  insert into auth.users (id, email) values (u, lower(p_no) || '@members.example.test');
  insert into public.persons (id, org_id, display_name) values (per, org, 'Fake Daily Limit Member');
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (org, pid, (select id from public.roles where org_id = org and code = 'member'));
  insert into public.members (id, org_id, person_id, profile_id, member_no) values (mid, org, per, pid, p_no);
  update public.members set status = 'invited' where id = mid;
  update public.members set status = 'pending_approval' where id = mid;
  update public.members set status = 'active' where id = mid;
  return u;
end $$;
create temp table us as select pg_temp.mk('CPC-2026-99871') as u;
alter table us add column mid text;
update us set mid = (select id from public.members where member_no = 'CPC-2026-99871');
grant select on us to public;
insert into public.courts (id, org_id, code, name) values
  ((select court from fx), (select org from fx), 'daily-limit-a', 'Fake Daily Court A'),
  ((select court2 from fx), (select org from fx), 'daily-limit-b', 'Fake Daily Court B');
insert into public.court_hours (org_id, court_id, weekday, opens_at, closes_at, valid_from)
select org, c, d, '00:00', '23:59', '2000-01-01' from fx, unnest(array[court, court2]) c, generate_series(0, 6) d;
insert into public.court_rates (org_id, court_id, rate_per_hour, valid_from)
select org, c, 0, '2000-01-01' from fx, unnest(array[court, court2]) c;
update public.settings set value = '60' where key = 'booking.slot_minutes' and unit_id is null and deleted_at is null;
update public.settings set value = '14' where key = 'booking.advance_days' and unit_id is null and deleted_at is null;
update public.settings set value = 'true' where key = 'booking.approval_required' and unit_id is null and deleted_at is null;
update public.settings set value = 'false' where key = 'payments.required.court_booking' and unit_id is null and deleted_at is null;

select is(has_function_privilege('authenticated', 'core.booking_daily_limit_problem(text,timestamptz,integer)', 'execute'), false,
  'the helper cannot expose another member booking allowance');
select pg_temp.as_user((select u from us));
set local role authenticated;
select is((public.quote_booking((select court from fx), (select day from fx) + interval '10 hours', 120)->>'ok'), 'false', 'quote refuses two hours');
select throws_ok(format($f$select public.request_booking(%L,%L,%L,120,'{}')$f$, (select b1 from fx), (select court from fx), (select day from fx) + interval '10 hours'),
  '22023', 'A booking can be at most 1 hour. Only 1 booking is allowed per day.', 'RPC refuses a tampered two-hour request');
select lives_ok(format($f$select public.request_booking(%L,%L,%L,60,'{}')$f$, (select b1 from fx), (select court from fx), (select day from fx) + interval '10 hours'), 'first one-hour booking succeeds');
select is((public.request_booking((select b1 from fx), (select court from fx), (select day from fx) + interval '10 hours', 60, '{}')->>'replayed'), 'true', 'retry replays despite the daily limit');
select throws_ok(format($f$select public.request_booking(%L,%L,%L,60,'{}')$f$, (select b1 from fx), (select court from fx), (select day from fx) + interval '11 hours'), 'CP422', null, 'changed payload under one ID is still refused');
select is((public.quote_booking((select court2 from fx), (select day from fx) + interval '20 hours', 60)->>'ok'), 'false', 'quote checks the allowance across courts');
select throws_ok(format($f$select public.request_booking(%L,%L,%L,60,'{}')$f$, (select b2 from fx), (select court2 from fx), (select day from fx) + interval '20 hours'),
  '22023', 'You already have a booking for this day. Only 1 booking of up to 1 hour is allowed per day.', 'another court cannot bypass the daily limit');
select lives_ok(format($f$select public.request_booking(%L,%L,%L,60,'{}')$f$, (select b2 from fx), (select court2 from fx), (select day from fx) + interval '1 day'), 'the next Manila day has its own allowance');
select lives_ok(format($f$select public.cancel_booking(%L,'changed plans',%L)$f$, (select b1 from fx), core.ulid()), 'member cancels the first request');
select is((public.quote_booking((select court from fx), (select day from fx) + interval '10 hours', 60)->>'ok'), 'true', 'cancellation releases the daily allowance');
reset role;

-- Midnight belongs to the next Manila business day even though both instants share a UTC date.
select is(core.booking_daily_limit_problem((select mid from us), (select day from fx) + interval '23 hours', 60), null::text, '11 PM belongs to the original Manila day');
select isnt(core.booking_daily_limit_problem((select mid from us), (select day from fx) + interval '24 hours', 60), null::text, 'midnight uses the next day allowance');
update public.bookings set expires_at = now() - interval '1 minute' where id = (select b2 from fx);
select is(core.booking_daily_limit_problem((select mid from us), (select day from fx) + interval '1 day', 60), null::text, 'stale pending requests do not consume the allowance');
update public.bookings set expires_at = now() + interval '1 day', status = 'confirmed', approved_at = now(), approved_by = 'test' where id = (select b2 from fx);
select isnt(core.booking_daily_limit_problem((select mid from us), (select day from fx) + interval '1 day', 60), null::text, 'confirmed booking consumes the allowance');
update public.bookings set status = 'checked_in', checked_in_at = now(), checked_in_by = 'test' where id = (select b2 from fx);
select isnt(core.booking_daily_limit_problem((select mid from us), (select day from fx) + interval '1 day', 60), null::text, 'checked-in booking consumes the allowance');
update public.bookings set status = 'completed' where id = (select b2 from fx);
select isnt(core.booking_daily_limit_problem((select mid from us), (select day from fx) + interval '1 day', 60), null::text, 'completed booking still consumes the allowance');

select * from finish();
rollback;
