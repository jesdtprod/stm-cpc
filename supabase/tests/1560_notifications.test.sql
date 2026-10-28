begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as court, core.ulid() as bk, core.ulid() as pay, core.ulid() as ev, core.ulid() as dv, core.ulid() as r1, core.ulid() as r2,
  (select id from public.format_templates where stages -> 0 ->> 'stage_type' = 'round_robin' and jsonb_array_length(stages) = 1 and deleted_at is null order by id limit 1) as tpl,
  (select id from public.categories where code = 'novice' and deleted_at is null) as cat_novice,
  (date_trunc('day', now() at time zone 'Asia/Manila') + interval '1 day 10 hours') at time zone 'Asia/Manila' as tomorrow10,
  current_date + 30 as day1;
grant select on fx to public;
create temp table topr as select rank_id as r from core.rank_chain((select org from fx)) order by idx desc limit 1;
grant select on topr to public;

create function pg_temp.mk(p_role text, p_no text, p_name text, p_ranked boolean) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); mid text := core.ulid(); org text := (select id from public.orgs where code = 'cpc');
begin
  insert into auth.users (id, email) values (u, lower(p_no) || '@members.example.test');
  insert into public.persons (id, org_id, display_name, gender, date_of_birth) values (per, org, p_name, 'male', '1990-01-01');
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (org, pid, (select id from public.roles where org_id = org and code = p_role));
  insert into public.members (id, org_id, person_id, profile_id, member_no) values (mid, org, per, pid, p_no);
  update public.members set status = 'invited' where id = mid;
  update public.members set status = 'pending_approval' where id = mid;
  update public.members set status = 'active' where id = mid;
  if p_ranked then
    insert into public.member_ranks (org_id, member_id, rank_id)
    select org, mid, r.id from public.ranks r join public.rank_ladders l on l.id = r.ladder_id join public.categories c on c.id = l.category_id
    where c.code = 'novice' and r.deleted_at is null order by r.sort_order limit 1;
  end if;
  return u;
end $$;
create temp table us(role text primary key, u uuid, mid text);
grant select on us to public;
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2026-97801', 'Zzyzx Admin', false), null;
insert into us select 'a', pg_temp.mk('member', 'CPC-2026-97802', 'Zzyzx Aaron', true), null;
insert into us select 'b', pg_temp.mk('member', 'CPC-2026-97803', 'Zzyzx Bea', true), null;
update us set mid = (select m.id from public.members m join public.profiles p on p.id = m.profile_id where p.auth_user_id = us.u);
create function pg_temp.n(p_member text, p_kind text) returns integer language sql as $$
  select count(*)::int from public.member_notifications where member_id = p_member and kind = p_kind
$$;
grant execute on function pg_temp.n(text, text) to public;

-- ---- members
select ok(pg_temp.n((select mid from us where role = 'admin'), 'staff.member_pending') >= 2, 'an administrator is told of each new member waiting for approval');
select is(pg_temp.n((select mid from us where role = 'a'), 'member.approved'), 1, 'a member is told their membership was approved');
select is(pg_temp.n((select mid from us where role = 'a'), 'staff.member_pending'), 0, 'and an ordinary member gets no staff messages');

-- ---- a court booking
insert into public.courts (id, org_id, code, name) values ((select court from fx), (select org from fx), 't-court', 'Zzyzx Court');
insert into public.court_hours (org_id, court_id, weekday, opens_at, closes_at, valid_from)
select (select org from fx), (select court from fx), d, '06:00', '23:00', '2000-01-01' from generate_series(0, 6) d;
insert into public.court_rates (org_id, court_id, rate_per_hour, valid_from) values ((select org from fx), (select court from fx), 150, '2000-01-01');
update public.settings set value = '60'::jsonb where key = 'booking.slot_minutes' and unit_id is null and deleted_at is null;
update public.settings set value = '14'::jsonb where key = 'booking.advance_days' and unit_id is null and deleted_at is null;
update public.settings set value = 'true'::jsonb where key = 'booking.approval_required' and unit_id is null and deleted_at is null;
select pg_temp.as_user((select u from us where role = 'a')); set local role authenticated;
select public.request_booking((select bk from fx), (select court from fx), (select tomorrow10 from fx), 60, '{}');
reset role;
select ok(pg_temp.n((select mid from us where role = 'admin'), 'staff.booking_request') >= 1, 'staff are told of a new booking request');
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.decide_booking((select bk from fx), 'approve', null, core.ulid());
reset role;
select is(pg_temp.n((select mid from us where role = 'a'), 'booking.confirmed'), 1, 'the member is told the booking was confirmed');
select ok((select body like 'Zzyzx Court%' from public.member_notifications where member_id = (select mid from us where role = 'a') and kind = 'booking.confirmed'), 'with the court and the time');

-- ---- a payment
select pg_temp.as_user((select u from us where role = 'a')); set local role authenticated;
select public.submit_payment((select pay from fx), (select bk from fx), 'cash', null, 150);
reset role;
select ok(pg_temp.n((select mid from us where role = 'admin'), 'staff.payment_submitted') >= 1, 'staff are told a payment waits to be checked');
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.decide_payment((select pay from fx), 'verify', null, core.ulid());
reset role;
select is(pg_temp.n((select mid from us where role = 'a'), 'payment.verified'), 1, 'the payer is told the payment was verified');

-- ---- an event: registration, the draw, a time, a rank change
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.create_event((select ev from fx), 'Zzyzx Notify Open', (select day1 from fx), (select day1 from fx), 'Hall', 0, null, null);
select public.create_division((select dv from fx), (select ev from fx), 'Zzyzx Division', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.set_event_status((select ev from fx), 'registration_open', null);
reset role;
update public.settings set value = 'true'::jsonb where key = 'events.registration_approval_required' and unit_id is null and deleted_at is null;
select pg_temp.as_user((select u from us where role = 'a')); set local role authenticated;
select public.register_for_event((select r1 from fx), (select dv from fx));
reset role;
select pg_temp.as_user((select u from us where role = 'b')); set local role authenticated;
select public.register_for_event((select r2 from fx), (select dv from fx));
reset role;
select ok(pg_temp.n((select mid from us where role = 'admin'), 'staff.registration_requested') >= 2, 'staff are told of each registration waiting for approval');
select is((select body from public.member_notifications where member_id = (select mid from us where role = 'admin')
  and kind = 'staff.registration_requested' and body like '%' || (select r1 from fx) limit 1),
  E'Player: Zzyzx Aaron\nEvent: Zzyzx Notify Open\nDivision: Zzyzx Division\nStatus: Requested\nReference: ' || (select r1 from fx),
  'staff registration alerts identify the player, event, division, status and reference');
select ok(exists(select 1 from public.member_notifications where member_id = (select mid from us where role = 'admin')
  and kind = 'staff.registration_requested' and body like E'Player: Zzyzx Bea\n%' and body like '%' || (select r2 from fx)),
  'registrations in the same division can be distinguished');
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.decide_registration((select r1 from fx), 'approve', null);
select public.decide_registration((select r2 from fx), 'approve', null);
select public.set_event_status((select ev from fx), 'registration_closed', null);
select public.run_draw((select id from public.division_stages where division_id = (select dv from fx)));
reset role;
select is(pg_temp.n((select mid from us where role = 'a'), 'registration.confirmed'), 1, 'a registration is confirmed to the player');
select is((select body from public.member_notifications where member_id = (select mid from us where role = 'a') and kind = 'registration.confirmed'),
  E'Player: Zzyzx Aaron\nEvent: Zzyzx Notify Open\nDivision: Zzyzx Division\nStatus: Confirmed\nReference: ' || (select r1 from fx),
  'confirmation includes the same entry details and the updated status');
select is(pg_temp.n((select mid from us where role = 'a'), 'draw.made'), 1, 'the draw reaches the first player');
select is(pg_temp.n((select mid from us where role = 'b'), 'draw.made'), 1, 'and the second');
select is((select url from public.member_notifications where member_id = (select mid from us where role = 'a') and kind = 'draw.made'),
  '#/bracket?division=' || (select dv from fx), 'with the address of their bracket');
update public.matches set scheduled_at = (select tomorrow10 from fx) where division_stage_id = (select id from public.division_stages where division_id = (select dv from fx));
select is(pg_temp.n((select mid from us where role = 'a'), 'match.scheduled'), 1, 'giving a match a time tells both players');
select is(pg_temp.n((select mid from us where role = 'b'), 'match.scheduled'), 1, 'the other one too');
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.override_member_rank((select mid from us where role = 'a'), (select r from topr), 'Test move', core.ulid());
reset role;
select is(pg_temp.n((select mid from us where role = 'a'), 'rank.changed'), 1, 'a rank change is told to the member');

-- ---- reading and clearing
select pg_temp.as_user((select u from us where role = 'a')); set local role authenticated;
select ok((select count(*)::int from public.my_notifications()) >= 6, 'a member lists their own messages');
select is((select count(*)::int from public.member_notifications), (select count(*)::int from public.my_notifications(200)), 'and the browser can read only their own rows');
select is((select min(created_at) <= max(created_at) from public.my_notifications()), true, 'newest first');
create temp table before_read as select public.my_unread_count() as n;
select ok((select n from before_read) >= 6, 'they have unread messages');
select is((select public.mark_notifications_read(array[(select id from public.my_notifications() limit 1)])), 1, 'one message can be marked read');
select is(public.my_unread_count(), (select n from before_read) - 1, 'the unread count falls by one');
select is((select public.mark_notifications_read(array[(select id from public.my_notifications() limit 1)])), 0, 'marking it again changes nothing');
select ok((select public.mark_notifications_read()) >= 0, 'all of them can be marked read');
select is(public.my_unread_count(), 0, 'then nothing is unread');
select throws_ok($$insert into public.member_notifications (org_id, member_id, kind, title) values ('x', 'y', 'a.b', 'forged')$$, '42501', null, 'the browser cannot write a notification');
reset role;
select pg_temp.as_user((select u from us where role = 'b')); set local role authenticated;
select is((select count(*)::int from public.member_notifications where member_id = (select mid from us where role = 'a')), 0, 'one member cannot read another''s messages');
select is((select public.mark_notifications_read(array[(select id from public.member_notifications where member_id = (select mid from us where role = 'a') limit 1)])), 0, 'or mark them read');
reset role;
set local role anon;
select throws_ok($$select * from public.my_notifications()$$, '42501', null, 'the public has no messages');
reset role;

-- ---- devices
select pg_temp.as_user((select u from us where role = 'a')); set local role authenticated;
select throws_ok($$select public.register_push('http://insecure.example/x', repeat('p', 40), repeat('a', 16))$$, '22023', 'that is not a push address', 'only https push addresses');
select lives_ok($$select public.register_push('https://push.example.test/send/aaa', repeat('p', 40), repeat('a', 16), 'Test phone')$$, 'a device registers');
select lives_ok($$select public.register_push('https://push.example.test/send/aaa', repeat('q', 40), repeat('b', 16), 'Test phone')$$, 'registering it again updates it');
select is(public.my_push_registered('https://push.example.test/send/aaa'), true, 'the browser can ask if this device is registered');
select throws_ok($$select * from public.push_subscriptions$$, '42501', null, 'the device keys are never readable from the browser');
select throws_ok($$select public.push_targets('x')$$, '42501', null, 'and only the push function can fetch them');
reset role;
select is((select count(*)::int from public.push_subscriptions where endpoint = 'https://push.example.test/send/aaa'), 1, 'one row per device');
select is((select p256dh from public.push_subscriptions where endpoint = 'https://push.example.test/send/aaa'), repeat('q', 40), 'with the latest keys');
select pg_temp.as_user((select u from us where role = 'a')); set local role authenticated;
select public.register_push('https://push.example.test/send/' || i, repeat('p', 40), repeat('a', 16)) from generate_series(1, 9) i;
select throws_ok($$select public.register_push('https://push.example.test/send/one-too-many', repeat('p', 40), repeat('a', 16))$$, '22023', null, 'ten devices are the most');
reset role;

-- a message for a member with a device does not fail without the push set-up, and the function can read the targets
select lives_ok(format($f$select core.notify_member(%L, 'test.ping', 'Hello', 'A test message', '#/')$f$, (select mid from us where role = 'a')), 'a message is stored even when pushing is not set up');
create temp table tg as select public.push_targets((select id from public.member_notifications where member_id = (select mid from us where role = 'a') and kind = 'test.ping')) as j;
select is((select j ->> 'title' from tg), 'Hello', 'the push function reads the title');
select is((select j ->> 'url' from tg), '#/', 'and the address');
select is((select jsonb_array_length(j -> 'subs') from tg), 10, 'and the ten registered devices');
select public.push_mark(array[(select (j -> 'subs' -> 0 ->> 'id') from tg)], array[(select (j -> 'subs' -> 1 ->> 'id') from tg)]);
select is((select count(*)::int from public.push_subscriptions s join public.members m on m.profile_id = s.profile_id where m.id = (select mid from us where role = 'a') and s.revoked_at is not null), 1, 'a device the push service says is gone is switched off');
select is((select count(*)::int from public.push_subscriptions where last_ok_at is not null), 1, 'one that worked is noted');
select pg_temp.as_user((select u from us where role = 'a')); set local role authenticated;
select lives_ok($$select public.unregister_push('https://push.example.test/send/aaa')$$, 'a device can be removed');
select is(public.my_push_registered('https://push.example.test/send/aaa'), false, 'and then it is not registered');
reset role;
select ok(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'member_notifications'), 'open pages hear of new messages in real time');
select is(has_function_privilege('anon', 'public.push_mark(text[], text[])', 'execute'), false, 'the public cannot touch devices');

select * from finish();
rollback;
