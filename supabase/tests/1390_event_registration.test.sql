begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as ev, core.ulid() as dS, core.ulid() as dD, core.ulid() as dA, core.ulid() as dH, core.ulid() as dP, core.ulid() as dOpen,
  core.ulid() as r1, core.ulid() as r1b, core.ulid() as r2, core.ulid() as r3, core.ulid() as r4, core.ulid() as r5, core.ulid() as r6,
  core.ulid() as r7, core.ulid() as r8, core.ulid() as r9, core.ulid() as r10, core.ulid() as r11, core.ulid() as r12, core.ulid() as r13,
  core.ulid() as r14, core.ulid() as r15, core.ulid() as r16, core.ulid() as r17, core.ulid() as r18, core.ulid() as r19,
  core.ulid() as p1, core.ulid() as p2, core.ulid() as p3, core.ulid() as p4,
  (select id from public.format_templates where lower(name) = 'round robin' and deleted_at is null) as tpl,
  (select id from public.categories where code = 'novice' and deleted_at is null) as cat_novice,
  (select id from public.categories where code = 'advanced' and deleted_at is null) as cat_adv,
  (select r.id from public.ranks r join public.rank_ladders l on l.id = r.ladder_id join public.categories c on c.id = l.category_id
   where c.code = 'novice' and r.deleted_at is null order by r.sort_order desc limit 1) as novice_high,
  current_date + 30 as day1;
grant select on fx to public;

create function pg_temp.mk(p_role text, p_no text, p_gender text, p_dob date, p_cat text) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); mid text := core.ulid(); org text := (select id from public.orgs where code = 'cpc');
begin
  insert into auth.users (id, email) values (u, lower(p_no) || '@members.example.test');
  insert into public.persons (id, org_id, display_name, gender, date_of_birth) values (per, org, 'Fake ' || p_no, p_gender, p_dob);
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (org, pid, (select id from public.roles where org_id = org and code = p_role));
  insert into public.members (id, org_id, person_id, profile_id, member_no) values (mid, org, per, pid, p_no);
  update public.members set status = 'invited' where id = mid;
  update public.members set status = 'pending_approval' where id = mid;
  update public.members set status = 'active' where id = mid;
  if p_cat is not null then
    insert into public.member_ranks (org_id, member_id, rank_id)
    select org, mid, r.id from public.ranks r join public.rank_ladders l on l.id = r.ladder_id join public.categories c on c.id = l.category_id
    where c.code = p_cat and r.deleted_at is null order by r.sort_order limit 1;
  end if;
  return u;
end $$;
create temp table us(role text primary key, u uuid, mid text);
grant select on us to public;
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2026-9801', 'male', '1985-01-01', null), null;
insert into us select 'm1', pg_temp.mk('member', 'CPC-2026-9802', 'male', '1990-06-15', 'novice'), null;
insert into us select 'm2', pg_temp.mk('member', 'CPC-2026-9803', 'female', '1992-03-03', 'novice'), null;
insert into us select 'm3', pg_temp.mk('member', 'CPC-2026-9804', 'male', '1960-02-02', 'novice'), null;
insert into us select 'm4', pg_temp.mk('member', 'CPC-2026-9805', 'male', '1991-05-05', 'advanced'), null;
insert into us select 'm5', pg_temp.mk('member', 'CPC-2026-9806', null, '1991-05-05', 'novice'), null;
insert into us select 'm6', pg_temp.mk('member', 'CPC-2026-9807', 'male', '1993-07-07', 'novice'), null;
insert into us select 'm7', pg_temp.mk('member', 'CPC-2026-9808', 'male', '1994-08-08', 'novice'), null;
update us set mid = (select m.id from public.members m join public.profiles p on p.id = m.profile_id join auth.users a on a.id = p.auth_user_id where a.id = us.u);

-- ---- set-up: an event with divisions (as the admin)
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select public.create_event((select ev from fx), 'Reg Test Open', (select day1 from fx), (select day1 + 1 from fx), 'Hall', 300, null, null);
select public.create_division((select dS from fx), (select ev from fx), 'Novice Men Singles', (select cat_novice from fx), 'singles', 'male', null, null, null, 2, (select tpl from fx), null);
select public.create_division((select dD from fx), (select ev from fx), 'Novice Mixed Doubles', (select cat_novice from fx), 'doubles', 'mixed', null, null, null, null, (select tpl from fx), null);
select public.create_division((select dA from fx), (select ev from fx), 'Novice 50 plus', (select cat_novice from fx), 'singles', null, '50+', null, null, null, (select tpl from fx), null);
select public.create_division((select dH from fx), (select ev from fx), 'Novice High Only', (select cat_novice from fx), 'singles', null, null, (select novice_high from fx), null, null, (select tpl from fx), null);
select public.create_division((select dP from fx), (select ev from fx), 'Novice Paid', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.create_division((select dOpen from fx), (select ev from fx), 'Novice Open', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
reset role;

-- ---- before registration opens
select pg_temp.as_user((select u from us where role = 'm1'));
set local role authenticated;
select throws_ok(format($f$select public.register_for_event(%L, %L)$f$, (select r1 from fx), (select dS from fx)), '22023', 'Registration for this event is not open.', 'nobody can register before registration opens');
reset role;
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select public.set_event_status((select ev from fx), 'registration_open', null);
reset role;

-- ---- access
select is(has_function_privilege('anon', 'public.register_for_event(text,text,text,text,text)', 'execute'), false, 'anonymous callers cannot register');
select is(has_function_privilege('authenticated', 'core.registration_problem(text,text,boolean)', 'execute'), false, 'the eligibility helper is private');

-- ---- eligibility is enforced on the server
select pg_temp.as_user((select u from us where role = 'm4'));
set local role authenticated;
select throws_ok(format($f$select public.register_for_event(%L, %L)$f$, (select r1 from fx), (select dS from fx)), '22023', 'This division is for a different category than your current rank.', 'another category is refused');
reset role;
select pg_temp.as_user((select u from us where role = 'm2'));
set local role authenticated;
select throws_ok(format($f$select public.register_for_event(%L, %L)$f$, (select r1 from fx), (select dS from fx)), '22023', 'This division is for men.', 'the wrong gender is refused');
reset role;
select pg_temp.as_user((select u from us where role = 'm5'));
set local role authenticated;
select throws_ok(format($f$select public.register_for_event(%L, %L)$f$, (select r1 from fx), (select dS from fx)), '22023', 'Add your gender to your profile to join this division.', 'no gender on file is refused for a gendered division');
reset role;
select pg_temp.as_user((select u from us where role = 'm1'));
set local role authenticated;
select throws_ok(format($f$select public.register_for_event(%L, %L)$f$, (select r1 from fx), (select dA from fx)), '22023', 'This division is for ages 50 and over.', 'under the age group is refused');
select throws_ok(format($f$select public.register_for_event(%L, %L)$f$, (select r1 from fx), (select dH from fx)), '22023', 'Your rank is below this division''s lowest allowed rank.', 'below the rank band is refused');
select throws_ok(format($f$select public.register_for_event(%L, %L, null, null, 'let me in')$f$, (select r1 from fx), (select dH from fx)), '42501', null, 'a member cannot allow their own exception');
reset role;
select pg_temp.as_user((select u from us where role = 'm3'));
set local role authenticated;
select is((select public.register_for_event((select r2 from fx), (select dA from fx)) ->> 'status'), 'requested', 'someone old enough registers');
reset role;

-- ---- a registration, its replay and a duplicate
select pg_temp.as_user((select u from us where role = 'm1'));
set local role authenticated;
create temp table x1 as select public.register_for_event((select r1 from fx), (select dS from fx)) as r;
reset role;
grant select on x1 to public;
select is((select r ->> 'status' from x1), 'requested', 'with approval on, a registration waits');
select is((select (r ->> 'fee')::numeric from x1), 300::numeric, 'the event fee is copied into it');
select pg_temp.as_user((select u from us where role = 'm1'));
set local role authenticated;
select is((select public.register_for_event((select r1 from fx), (select dS from fx)) ->> 'replayed'), 'true', 'the same request again returns the same registration');
select throws_ok(format($f$select public.register_for_event(%L, %L, %L)$f$, (select r1 from fx), (select dOpen from fx), 'x'), 'CP422', null, 'another request under the same ID is refused');
select throws_ok(format($f$select public.register_for_event(%L, %L)$f$, (select r1b from fx), (select dS from fx)), '23505', null, 'registering twice in a division is refused');
select throws_ok(format($f$insert into public.registrations (org_id, event_id, division_id, member_id, fee_snapshot, payload_hash) values (%L, %L, %L, %L, 0, repeat('a', 64))$f$, (select org from fx), (select ev from fx), (select dOpen from fx), (select mid from us where role = 'm1')), '42501', null, 'the app cannot write registrations directly');
reset role;

-- ---- a full division waitlists, or refuses when the waitlist is off
select pg_temp.as_user((select u from us where role = 'm6'));
set local role authenticated;
select is((select public.register_for_event((select r3 from fx), (select dS from fx)) ->> 'status'), 'requested', 'the second place is taken');
reset role;
select pg_temp.as_user((select u from us where role = 'm7'));
set local role authenticated;
select is((select public.register_for_event((select r4 from fx), (select dS from fx)) ->> 'status'), 'waitlisted', 'a full division waitlists');
reset role;
update public.settings set value = 'false'::jsonb where key = 'events.waitlist_enabled' and unit_id is null and deleted_at is null;
select pg_temp.as_user((select u from us where role = 'm3'));
set local role authenticated;
select throws_ok(format($f$select public.register_for_event(%L, %L)$f$, (select r5 from fx), (select dS from fx)), '22023', 'this division is full', 'with the waitlist off, a full division refuses');
reset role;
update public.settings set value = 'true'::jsonb where key = 'events.waitlist_enabled' and unit_id is null and deleted_at is null;

-- ---- doubles
select pg_temp.as_user((select u from us where role = 'm1'));
set local role authenticated;
select throws_ok(format($f$select public.register_for_event(%L, %L)$f$, (select r6 from fx), (select dD from fx)), '22023', 'choose your doubles partner', 'doubles need a partner');
select throws_ok(format($f$select public.register_for_event(%L, %L, %L)$f$, (select r6 from fx), (select dD from fx), (select mid from us where role = 'm1')), '22023', 'your partner must be another member', 'you cannot be your own partner');
select throws_ok(format($f$select public.register_for_event(%L, %L, %L)$f$, (select r6 from fx), (select dD from fx), (select mid from us where role = 'm4')), '22023', null, 'an ineligible partner is refused');
select throws_ok(format($f$select public.register_for_event(%L, %L, %L)$f$, (select r6 from fx), (select dOpen from fx), (select mid from us where role = 'm2')), '22023', 'singles take no partner', 'singles take no partner');
select is((select public.register_for_event((select r6 from fx), (select dD from fx), (select mid from us where role = 'm2')) ->> 'status'), 'requested', 'a pair registers');
reset role;
select pg_temp.as_user((select u from us where role = 'm6'));
set local role authenticated;
select throws_ok(format($f$select public.register_for_event(%L, %L, %L)$f$, (select r7 from fx), (select dD from fx), (select mid from us where role = 'm2')), '23505', null, 'a partner already in a pair cannot be picked again');
reset role;
select pg_temp.as_user((select u from us where role = 'm2'));
set local role authenticated;
select throws_ok(format($f$select public.register_for_event(%L, %L, %L)$f$, (select r8 from fx), (select dD from fx), (select mid from us where role = 'm6')), '23505', null, 'a partner cannot register again on their own');
reset role;

-- ---- approval
select pg_temp.as_user((select u from us where role = 'm1'));
set local role authenticated;
select throws_ok(format($f$select public.decide_registration(%L, 'approve', null)$f$, (select r1 from fx)), '42501', null, 'a member cannot approve');
reset role;
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select is((select public.decide_registration((select r1 from fx), 'approve', null) ->> 'status'), 'confirmed', 'an admin approves');
select is((select public.decide_registration((select r1 from fx), 'approve', null) ->> 'unchanged'), 'true', 'approving twice is safe');
select throws_ok(format($f$select public.decide_registration(%L, 'reject', 'changed my mind')$f$, (select r1 from fx)), '22023', null, 'a confirmed registration cannot be rejected');
select throws_ok(format($f$select public.decide_registration(%L, 'reject', null)$f$, (select r2 from fx)), '22023', 'a reason is required', 'rejecting needs a reason');
select is((select public.decide_registration((select r2 from fx), 'reject', 'Documents missing') ->> 'status'), 'rejected', 'an admin rejects with a reason');
reset role;
select is((select count(*)::int from public.entries where registration_id = (select r1 from fx)), 1, 'confirming creates the entry');
select is((select count(*)::int from public.entry_members em join public.entries e on e.id = em.entry_id where e.registration_id = (select r1 from fx)), 1, 'with the member in it');
select is((select count(*)::int from public.ledger_entries where source_type = 'event_registration' and source_id = (select r1 from fx)), 1, 'the fee is charged once');
select is((select amount from public.ledger_entries where source_type = 'event_registration' and source_id = (select r1 from fx)), -300::numeric, 'as a charge of 300');
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select public.decide_registration((select r6 from fx), 'approve', null);
reset role;
select is((select count(*)::int from public.entry_members em join public.entries e on e.id = em.entry_id where e.registration_id = (select r6 from fx)), 2, 'a doubles entry holds both partners');

-- ---- payment required: approval waits for the verified fee
update public.settings set value = 'true'::jsonb where key = 'payments.required.event_registration' and unit_id is null and deleted_at is null;
select pg_temp.as_user((select u from us where role = 'm6'));
set local role authenticated;
select is((select public.register_for_event((select r9 from fx), (select dP from fx)) ->> 'status'), 'requested', 'a paid division starts requested');
reset role;
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select throws_ok(format($f$select public.decide_registration(%L, 'approve', null)$f$, (select r9 from fx)), '22023', 'the fee has not been paid and verified yet', 'approval waits for the fee');
reset role;
select pg_temp.as_user((select u from us where role = 'm1'));
set local role authenticated;
select throws_ok(format($f$select public.submit_event_payment(%L, %L, 'cash', null, 300)$f$, (select p1 from fx), (select r9 from fx)), '42501', null, 'only the registrant can pay');
reset role;
select pg_temp.as_user((select u from us where role = 'm6'));
set local role authenticated;
select throws_ok(format($f$select public.submit_event_payment(%L, %L, 'cash', null, 400)$f$, (select p1 from fx), (select r9 from fx)), '22023', null, 'paying more than the fee is refused');
select is((select public.submit_event_payment((select p1 from fx), (select r9 from fx), 'cash', null, 300) ->> 'status'), 'submitted', 'the registrant sends the payment');
select is((select public.submit_event_payment((select p1 from fx), (select r9 from fx), 'cash', null, 300) ->> 'replayed'), 'true', 'sending it again is safe');
reset role;
select is((select status from public.registrations where id = (select r9 from fx)), 'requested', 'an unverified payment confirms nothing');
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select public.decide_payment((select p1 from fx), 'verify', null, core.ulid());
select is((select public.decide_registration((select r9 from fx), 'approve', null) ->> 'status'), 'confirmed', 'once the fee is verified, approval works');
reset role;

-- ---- approval off: a verified payment confirms by itself
update public.settings set value = 'false'::jsonb where key = 'events.registration_approval_required' and unit_id is null and deleted_at is null;
select pg_temp.as_user((select u from us where role = 'm7'));
set local role authenticated;
select is((select public.register_for_event((select r10 from fx), (select dOpen from fx)) ->> 'status'), 'requested', 'with payment required, it waits for the fee even without approval');
select public.submit_event_payment((select p2 from fx), (select r10 from fx), 'cash', null, 300);
reset role;
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select public.decide_payment((select p2 from fx), 'verify', null, core.ulid());
reset role;
select is((select status from public.registrations where id = (select r10 from fx)), 'confirmed', 'verifying the payment confirms it');
select is((select count(*)::int from public.entries where registration_id = (select r10 from fx)), 1, 'and creates the entry');

-- ---- approval off and no payment needed: confirms at once
update public.settings set value = 'false'::jsonb where key = 'payments.required.event_registration' and unit_id is null and deleted_at is null;
select pg_temp.as_user((select u from us where role = 'm3'));
set local role authenticated;
select is((select public.register_for_event((select r11 from fx), (select dOpen from fx)) ->> 'status'), 'confirmed', 'no approval and no payment: confirmed at once');
reset role;
update public.settings set value = 'true'::jsonb where key = 'events.registration_approval_required' and unit_id is null and deleted_at is null;

-- ---- a staff exception
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select throws_ok(format($f$select public.register_for_event(%L, %L, null, %L, null)$f$, (select r12 from fx), (select dOpen from fx), (select mid from us where role = 'm4')), '22023', 'This division is for a different category than your current rank.', 'staff need a reason to allow another category');
select is((select public.register_for_event((select r12 from fx), (select dOpen from fx), null, (select mid from us where role = 'm4'), 'Moved up by the coach') ->> 'status'), 'requested', 'with a reason, staff can register a member from another category');
reset role;
select is((select meta ->> 'override_reason' from public.registrations where id = (select r12 from fx)), 'Moved up by the coach', 'the reason is kept');
select pg_temp.as_user((select u from us where role = 'm1'));
set local role authenticated;
select throws_ok(format($f$select public.register_for_event(%L, %L, null, %L, null)$f$, (select r13 from fx), (select dOpen from fx), (select mid from us where role = 'm4')), '42501', null, 'a member cannot register someone else');

-- ---- what a member is offered
select is((select jsonb_array_length(public.my_event_options())), 1, 'the open event is offered');
select is((select (d ->> 'taken')::int from jsonb_array_elements((public.my_event_options() -> 0 -> 'divisions')) d where d ->> 'name' = 'Novice Men Singles'), 2, 'with the spots taken');
select is((select d -> 'mine' ->> 'status' from jsonb_array_elements((public.my_event_options() -> 0 -> 'divisions')) d where d ->> 'name' = 'Novice Men Singles'), 'confirmed', 'and the member''s own registration');
select ok((select d ->> 'problem' from jsonb_array_elements((public.my_event_options() -> 0 -> 'divisions')) d where d ->> 'name' = 'Novice High Only') is not null, 'and why a division is not open to them');
reset role;

-- ---- registration closed
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select public.set_event_status((select ev from fx), 'registration_closed', null);
reset role;
select pg_temp.as_user((select u from us where role = 'm6'));
set local role authenticated;
select throws_ok(format($f$select public.register_for_event(%L, %L)$f$, (select r14 from fx), (select dOpen from fx)), '22023', 'Registration for this event is not open.', 'a closed event takes no registrations');
reset role;

-- ---- history
select ok((select count(*) from public.entity_events where entity_type = 'registration' and entity_id = (select r1 from fx)) >= 2, 'registration changes are in the history');
select ok(exists (select 1 from core.audit_log where action = 'registration.approve' and record_id = (select r1 from fx)), 'an approval is audited');

select * from finish();
rollback;
