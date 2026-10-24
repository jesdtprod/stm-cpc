begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as ev, core.ulid() as dv1, core.ulid() as dv2, core.ulid() as dv3,
  core.ulid() as g1, core.ulid() as g2, core.ulid() as g3, core.ulid() as g4, core.ulid() as g5, core.ulid() as g6,
  core.ulid() as h1, core.ulid() as h2, core.ulid() as h3, core.ulid() as h4, core.ulid() as h5,
  core.ulid() as k1, core.ulid() as k2, core.ulid() as k3,
  (select id from public.format_templates where lower(name) = 'round robin' and deleted_at is null) as tpl,
  (select id from public.categories where code = 'novice' and deleted_at is null) as cat_novice,
  current_date + 30 as day1;
grant select on fx to public;

create function pg_temp.mk(p_role text, p_no text) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); mid text := core.ulid(); org text := (select id from public.orgs where code = 'cpc');
begin
  insert into auth.users (id, email) values (u, lower(p_no) || '@members.example.test');
  insert into public.persons (id, org_id, display_name, gender, date_of_birth) values (per, org, 'Fake ' || p_no, 'male', '1990-01-01');
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (org, pid, (select id from public.roles where org_id = org and code = p_role));
  insert into public.members (id, org_id, person_id, profile_id, member_no) values (mid, org, per, pid, p_no);
  update public.members set status = 'invited' where id = mid;
  update public.members set status = 'pending_approval' where id = mid;
  update public.members set status = 'active' where id = mid;
  if p_role = 'member' then
    insert into public.member_ranks (org_id, member_id, rank_id)
    select org, mid, r.id from public.ranks r join public.rank_ladders l on l.id = r.ladder_id join public.categories c on c.id = l.category_id
    where c.code = 'novice' and r.deleted_at is null order by r.sort_order limit 1;
  end if;
  return u;
end $$;
create temp table us(role text primary key, u uuid, mid text);
grant select on us to public;
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2026-9901'), null;
insert into us select 'a', pg_temp.mk('member', 'CPC-2026-9902'), null;
insert into us select 'b', pg_temp.mk('member', 'CPC-2026-9903'), null;
insert into us select 'c', pg_temp.mk('member', 'CPC-2026-9904'), null;
insert into us select 'd', pg_temp.mk('member', 'CPC-2026-9905'), null;
insert into us select 'e', pg_temp.mk('member', 'CPC-2026-9906'), null;
update us set mid = (select m.id from public.members m join public.profiles p on p.id = m.profile_id where p.auth_user_id = us.u);

-- ---- set-up: an event of 300 with a division of two places
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select public.create_event((select ev from fx), 'Withdraw Test', (select day1 from fx), (select day1 from fx), 'Hall', 300, null, null);
select public.create_division((select dv1 from fx), (select ev from fx), 'Two Places', (select cat_novice from fx), 'singles', null, null, null, null, 2, (select tpl from fx), null);
select public.create_division((select dv2 from fx), (select ev from fx), 'Second Division', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.create_division((select dv3 from fx), (select ev from fx), 'To Be Cancelled', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.set_event_status((select ev from fx), 'registration_open', null);
reset role;
-- approval off, payment not required: registrations confirm at once
update public.settings set value = 'false'::jsonb where key = 'events.registration_approval_required' and unit_id is null and deleted_at is null;

-- a and b fill the division; c, d and e wait in that order
select pg_temp.as_user((select u from us where role = 'a'));
set local role authenticated;
select is((select public.register_for_event((select g1 from fx), (select dv1 from fx)) ->> 'status'), 'confirmed', 'a takes the first place');
reset role;
select pg_temp.as_user((select u from us where role = 'b'));
set local role authenticated;
select is((select public.register_for_event((select g2 from fx), (select dv1 from fx)) ->> 'status'), 'confirmed', 'b takes the second');
reset role;
select pg_temp.as_user((select u from us where role = 'c'));
set local role authenticated;
select is((select public.register_for_event((select g3 from fx), (select dv1 from fx)) ->> 'status'), 'waitlisted', 'c waits');
reset role;
select pg_temp.as_user((select u from us where role = 'd'));
set local role authenticated;
select is((select public.register_for_event((select g4 from fx), (select dv1 from fx)) ->> 'status'), 'waitlisted', 'd waits behind c');
reset role;
select pg_temp.as_user((select u from us where role = 'e'));
set local role authenticated;
select is((select public.register_for_event((select g5 from fx), (select dv1 from fx)) ->> 'status'), 'waitlisted', 'e waits behind d');
reset role;
-- one test transaction gives every row the same clock time; real registrations are minutes apart
set local session_replication_role = replica;
update public.registrations set created_at = now() - interval '3 minutes' where id = (select g3 from fx);
update public.registrations set created_at = now() - interval '2 minutes' where id = (select g4 from fx);
update public.registrations set created_at = now() - interval '1 minute' where id = (select g5 from fx);
set local session_replication_role = origin;
select is((select count(*)::int from public.ledger_entries where source_type = 'event_registration' and source_id = (select g1 from fx)), 1, 'a was charged the fee');

-- ---- access
select is(has_function_privilege('anon', 'public.withdraw_registration(text,text)', 'execute'), false, 'anonymous callers cannot withdraw');
select pg_temp.as_user((select u from us where role = 'b'));
set local role authenticated;
select throws_ok(format($f$select public.withdraw_registration(%L, 'not mine')$f$, (select g1 from fx)), '42501', null, 'a member cannot withdraw someone else');
reset role;

-- ---- a withdrawal frees the place for the oldest waiting registration, and refunds the fee once
select pg_temp.as_user((select u from us where role = 'a'));
set local role authenticated;
select is((select public.withdraw_registration((select g1 from fx), 'Injured') ->> 'status'), 'withdrawn', 'a withdraws');
select is((select public.withdraw_registration((select g1 from fx), 'Injured') ->> 'unchanged'), 'true', 'withdrawing twice is safe');
reset role;
select is((select status from public.registrations where id = (select g1 from fx)), 'withdrawn', 'the registration is withdrawn');
select is((select status from public.entries where registration_id = (select g1 from fx)), 'withdrawn', 'and so is the entry');
select is((select count(*)::int from public.ledger_entries where source_type = 'event_registration' and source_id = (select g1 from fx)), 2, 'the ledger holds the charge and one refund');
select is((select sum(amount) from public.ledger_entries where source_type = 'event_registration' and source_id = (select g1 from fx)), 0::numeric, 'which net to zero');
select is((select reverses_entry_id from public.ledger_entries where source_type = 'event_registration' and source_id = (select g1 from fx) and client_ref = 'refund'),
  (select id from public.ledger_entries where source_type = 'event_registration' and source_id = (select g1 from fx) and client_ref = 'charge'), 'the refund points at the charge');
select is((select status from public.registrations where id = (select g3 from fx)), 'confirmed', 'c, first in line, is promoted (and confirmed, as approval is off)');
select is((select status from public.registrations where id = (select g4 from fx)), 'waitlisted', 'd still waits');
select is((select status from public.registrations where id = (select g5 from fx)), 'waitlisted', 'e still waits');
select is((select count(*)::int from public.entries where registration_id = (select g3 from fx)), 1, 'the promoted member has an entry');

-- ---- a staff withdrawal needs a reason; a rejection also frees a place
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select throws_ok(format($f$select public.withdraw_registration(%L, null)$f$, (select g2 from fx)), '22023', 'a reason is required', 'staff must give a reason');
select is((select public.withdraw_registration((select g2 from fx), 'Asked by phone') ->> 'status'), 'withdrawn', 'staff withdraw b');
reset role;
select is((select status from public.registrations where id = (select g4 from fx)), 'confirmed', 'd is next to be promoted');
select is((select status from public.registrations where id = (select g5 from fx)), 'waitlisted', 'e still waits, the division is full again');

-- ---- a bigger limit promotes the waiting
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select public.update_division((select dv1 from fx), 'Two Places', null, null, null, null, 3);
reset role;
select is((select status from public.registrations where id = (select g5 from fx)), 'confirmed', 'raising the limit promotes e');

-- ---- with approval on, a promoted registration goes back to requested
update public.settings set value = 'true'::jsonb where key = 'events.registration_approval_required' and unit_id is null and deleted_at is null;
select pg_temp.as_user((select u from us where role = 'a'));
set local role authenticated;
select is((select public.register_for_event((select h1 from fx), (select dv2 from fx)) ->> 'status'), 'requested', 'a registers elsewhere and waits for approval');
reset role;
update public.divisions set max_entries = 2 where id = (select dv2 from fx);
select pg_temp.as_user((select u from us where role = 'b'));
set local role authenticated;
select is((select public.register_for_event((select h2 from fx), (select dv2 from fx)) ->> 'status'), 'requested', 'b takes the second place');
reset role;
select pg_temp.as_user((select u from us where role = 'c'));
set local role authenticated;
select is((select public.register_for_event((select h3 from fx), (select dv2 from fx)) ->> 'status'), 'waitlisted', 'c waits');
reset role;
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select public.decide_registration((select h1 from fx), 'reject', 'No documents');
reset role;
select is((select status from public.registrations where id = (select h3 from fx)), 'requested', 'a rejection frees the place; the promoted registration still needs approval');
select is((select status_reason from public.registrations where id = (select h3 from fx)), 'Promoted from the waitlist', 'and says why');

-- ---- after the draw, a member cannot just withdraw
update public.divisions set status = 'drawn' where id = (select dv2 from fx);
select pg_temp.as_user((select u from us where role = 'b'));
set local role authenticated;
select throws_ok(format($f$select public.withdraw_registration(%L, 'Changed my mind')$f$, (select h2 from fx)), '22023', 'the draw has been made; ask the club to remove you', 'withdrawal stops once the division is drawn');
reset role;

-- ---- cancelling a division withdraws and refunds everyone in it
select pg_temp.as_user((select u from us where role = 'a'));
set local role authenticated;
select public.register_for_event((select k1 from fx), (select dv3 from fx));
reset role;
update public.settings set value = 'false'::jsonb where key = 'events.registration_approval_required' and unit_id is null and deleted_at is null;
select pg_temp.as_user((select u from us where role = 'b'));
set local role authenticated;
select is((select public.register_for_event((select k2 from fx), (select dv3 from fx)) ->> 'status'), 'confirmed', 'b joins the third division and is confirmed');
reset role;
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select public.cancel_division((select dv3 from fx), 'Too few entries');
reset role;
select is((select count(*)::int from public.registrations where division_id = (select dv3 from fx) and status = 'withdrawn'), 2, 'cancelling the division withdraws both registrations');
select is((select sum(amount) from public.ledger_entries where source_type = 'event_registration' and source_id = (select k2 from fx)), 0::numeric, 'and refunds the confirmed one');
select is((select status_reason from public.registrations where id = (select k2 from fx)), 'Division cancelled', 'with the reason');

-- ---- history and audit
select ok((select count(*) from public.entity_events where entity_type = 'registration' and entity_id = (select g1 from fx)) >= 2, 'the withdrawal is in the history');
select ok(exists (select 1 from core.audit_log where action = 'registration.withdraw' and record_id = (select g1 from fx)), 'and audited');

select * from finish();
rollback;
