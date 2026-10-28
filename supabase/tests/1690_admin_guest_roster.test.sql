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
  (select id from public.format_templates where stages -> 0 ->> 'stage_type' = 'round_robin' and jsonb_array_length(stages) = 1 and deleted_at is null order by id limit 1) as tpl,
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



-- Setup above creates only fake accounts, event and divisions.
update public.settings set value='true'::jsonb where org_id=(select org from fx)
  and key in ('events.registration_approval_required','events.waitlist_enabled','payments.required.event_registration');
insert into us select 'manager',pg_temp.mk('manager','CPC-2030-96900','male','1985-01-01',null),null;
update us set mid=(select m.id from public.members m join public.profiles p on p.id=m.profile_id where p.auth_user_id=us.u) where role='manager';
create temp table dx as select core.ulid() as g1,core.ulid() as g2,core.ulid() as g3,core.ulid() as g4,core.ulid() as mp,
  core.ulid() as r1,core.ulid() as r2,core.ulid() as fill,core.ulid() as moved,core.ulid() as replaced,
  core.ulid() as pay1,core.ulid() as double_reg,core.ulid() as double_pay,core.ulid() as double_replace,
  core.ulid() as double_dest,core.ulid() as double_move,core.ulid() as topup,
  core.ulid() as lower_fee,core.ulid() as wait_guest,core.ulid() as wait_reg,core.ulid() as slot_replacement,
  (select r.id from public.ranks r join public.rank_ladders l on l.id=r.ladder_id
    where l.category_id=(select cat_novice from fx) and r.deleted_at is null order by r.sort_order limit 1) as rank1;
grant select on dx to public;
select pg_temp.as_user((select u from us where role='manager')); set local role authenticated;
select is(core.has_permission((select org from fx),null,'events.admin_roster'),false,'manager does not receive admin roster permission');
select throws_ok(format($f$select public.create_event_participant(%L,%L,null,%L,'Fake Unauthorized Guest')$f$,core.ulid(),(select ev from fx),core.ulid()),'42501',null,'manager cannot add guests through the original participant API');
select throws_ok(format($f$select public.create_guest_event_participant(%L,%L,%L,'Fake Unauthorized Guest',null,null,null,'FAKEADMINONLY')$f$,core.ulid(),(select ev from fx),core.ulid()),'42501',null,'manager cannot add guests through the DUPR participant API');
select throws_ok(format($f$select public.set_event_guest_policy(%L,true,%L)$f$,(select ev from fx),core.ulid()),'42501',null,'manager cannot enable guest registration');
reset role;
select pg_temp.as_user((select u from us where role='admin')); set local role authenticated;
select is(core.has_permission((select org from fx),null,'events.admin_roster'),true,'admin receives roster permission');
select public.create_event_participant((select g1 from dx),(select ev from fx),null,core.ulid(),'Fake Late Guest One',null,'male','1990-01-01');
select public.create_event_participant((select g2 from dx),(select ev from fx),null,core.ulid(),'Fake Late Guest Two',null,'male','1990-01-01');
select public.create_event_participant((select g3 from dx),(select ev from fx),null,core.ulid(),'Fake Late Guest Three',null,'female','1990-01-01');
select public.create_event_participant((select mp from dx),(select ev from fx),(select mid from us where role='m1'));
select public.set_event_status((select ev from fx),'registration_open',null);
select lives_ok(format($f$select public.set_event_guest_policy(%L,true,%L)$f$,(select ev from fx),core.ulid()),'admin enables guests in an open event');
select public.register_guest_for_event((select r1 from dx),(select dS from fx),(select g1 from dx),(select rank1 from dx));
select public.submit_guest_event_payment((select pay1 from dx),(select r1 from dx),'cash',null,300,null);
select throws_ok(format($f$select public.change_guest_registration(%L,%L,%L,'move',%L,null,null,null,'Fake pending receipt transfer')$f$,core.ulid(),(select r1 from dx),(select dP from fx),(select rank1 from dx)),'22023',null,'pending receipts must be resolved before moving a registration');
select is((select status from public.registrations where id=(select r1 from dx)),'requested','blocked pending-receipt change preserves the original registration');
select public.decide_payment((select pay1 from dx),'verify',null,core.ulid());
select public.decide_registration((select r1 from dx),'approve',null);
select public.set_event_status((select ev from fx),'registration_closed',null);
create temp table occupied_id as select core.ulid() as id;
grant select on occupied_id to public;
select public.register_guest_for_event((select id from occupied_id),(select dOpen from fx),(select g1 from dx),(select rank1 from dx));
select throws_ok(format($f$select public.change_guest_registration(%L,%L,%L,'move',%L,null,null,null,'Fake reused destination ID')$f$,(select id from occupied_id),(select r1 from dx),(select dOpen from fx),(select rank1 from dx)),'CP422',null,'roster changes cannot reuse an existing registration as their destination');
select lives_ok(format($f$select public.create_guest_event_participant(%L,%L,%L,'Fake Closed Event Guest',null,'male','1990-01-01',null)$f$,(select g4 from dx),(select ev from fx),core.ulid()),'admin adds a guest with registration closed');
select lives_ok(format($f$select public.register_guest_for_event(%L,%L,%L,%L)$f$,(select r2 from dx),(select dS from fx),(select g2 from dx),(select rank1 from dx)),'admin registers a guest while event remains closed');
select is((select status from public.events where id=(select ev from fx)),'registration_closed','late registration does not reopen the event');
select throws_ok(format($f$select public.set_event_guest_policy(%L,false,%L)$f$,(select ev from fx),core.ulid()),'22023',null,'guest policy cannot strand existing guest registrations');
select lives_ok(format($f$select public.change_guest_registration(%L,%L,%L,'move',%L,null,null,null,'Fake division transfer')$f$,(select moved from dx),(select r1 from dx),(select dP from fx),(select rank1 from dx)),'admin moves a paid guest while registration is closed');
select is((select status from public.registrations where id=(select r1 from dx)),'withdrawn','move preserves the withdrawn original registration');
select is((select status from public.registrations where id=(select moved from dx)),'confirmed','same-payer verified payment follows the moved registration');
select is((select count(*)::integer from public.entries where registration_id=(select r1 from dx) and status='withdrawn'),1,'old entry remains in history');
select lives_ok(format($f$select public.change_guest_registration(%L,%L,%L,'move',%L,null,null,null,'Fake division transfer')$f$,(select moved from dx),(select r1 from dx),(select dP from fx),(select rank1 from dx)),'move retry is idempotent after original registration is withdrawn');
select throws_ok(format($f$select public.change_guest_registration(%L,%L,%L,'move',%L,null,null,null,'Changed reason')$f$,(select moved from dx),(select r1 from dx),(select dP from fx),(select rank1 from dx)),'CP422',null,'changed request under the same roster ID is refused');
select public.register_guest_for_event((select fill from dx),(select dS from fx),(select g4 from dx),(select rank1 from dx));
select throws_ok(format($f$select public.change_guest_registration(%L,%L,%L,'move',%L,null,null,null,'Fake full destination')$f$,core.ulid(),(select moved from dx),(select dS from fx),(select rank1 from dx)),'22023',null,'moving to a full division is refused');
select is((select status from public.registrations where id=(select moved from dx)),'confirmed','failed transfer leaves the current entry confirmed');
select throws_ok(format($f$select public.change_guest_registration(%L,%L,%L,'replace',%L,null,null,null,'Fake unchanged roster')$f$,core.ulid(),(select moved from dx),(select dP from fx),(select rank1 from dx)),'22023',null,'replacement requires a different player');
select lives_ok(format($f$select public.change_guest_registration(%L,%L,%L,'replace',%L,null,null,%L,'Fake emergency before draw')$f$,(select replaced from dx),(select moved from dx),(select dP from fx),(select rank1 from dx),(select g2 from dx)),'admin replaces a guest before the draw');
select is((select status from public.registrations where id=(select replaced from dx)),'requested','a replacement payer must meet their own required payment');
select is((select verified_total from public.guest_registration_payment_summary(array[(select replaced from dx)])),0::numeric,'another payer never inherits the outgoing guest receipt');
select is((select verified_total from public.guest_registration_payment_summary(array[(select moved from dx)])),300::numeric,'same-payer history still records the original verified payment');
select public.void_payment((select pay1 from dx),'Fake outgoing guest received a refund',core.ulid());
select is((select verified_total from public.guest_registration_payment_summary(array[(select moved from dx)])),0::numeric,'voided original receipts no longer count as carried credit');
select public.register_guest_for_event((select double_reg from dx),(select dD from fx),(select g1 from dx),(select rank1 from dx),(select mp from dx),null);
select public.submit_guest_event_payment((select double_pay from dx),(select double_reg from dx),'cash',null,300,null);
select public.decide_payment((select double_pay from dx),'verify',null,core.ulid());
select public.decide_registration((select double_reg from dx),'approve',null);
select lives_ok(format($f$select public.change_guest_registration(%L,%L,%L,'replace',%L,%L,%L,null,'Fake partner replacement')$f$,(select double_replace from dx),(select double_reg from dx),(select dD from fx),(select rank1 from dx),(select g3 from dx),(select rank1 from dx)),'admin replaces a member partner with a guest partner');
select is((select status from public.registrations where id=(select double_replace from dx)),'confirmed','same guest payer keeps verified payment when their partner changes');
reset role;
select is((select count(*)::integer from public.entry_guests g join public.entries e on e.id=g.entry_id where e.registration_id=(select double_replace from dx)),2,'replacement team has the new two-guest roster');
select is((select count(*)::integer from public.entry_members m join public.entries e on e.id=m.entry_id where e.registration_id=(select double_reg from dx) and e.status='withdrawn'),1,'outgoing member roster remains attached to the withdrawn entry');
update public.events set fee=450 where id=(select ev from fx);
select pg_temp.as_user((select u from us where role='admin')); set local role authenticated;
select public.create_division((select double_dest from dx),(select ev from fx),'Fake Doubles Destination',(select cat_novice from fx),'doubles','mixed',null,null,null,null,(select tpl from fx),null);
select lives_ok(format($f$select public.change_guest_registration(%L,%L,%L,'move',%L,%L,%L,null,'Fake move with fee difference')$f$,(select double_move from dx),(select double_replace from dx),(select double_dest from dx),(select rank1 from dx),(select g3 from dx),(select rank1 from dx)),'admin move recalculates the current server fee');
select is((select new_fee-previous_fee from public.event_roster_changes where id=(select double_move from dx)),150::numeric,'fee difference is recorded on the server');
select is((select verified_total from public.guest_registration_payment_summary(array[(select double_move from dx)])),300::numeric,'verified credit follows a chain of changes without double counting');
select is((select status from public.registrations where id=(select double_move from dx)),'requested','higher fee waits for the additional payment');
select throws_ok(format($f$select public.submit_guest_event_payment(%L,%L,'cash',null,151,null)$f$,core.ulid(),(select double_move from dx)),'22023',null,'overpayment check includes carried verified credit');
select public.submit_guest_event_payment((select topup from dx),(select double_move from dx),'cash',null,150,null);
select public.decide_payment((select topup from dx),'verify',null,core.ulid());
select public.decide_registration((select double_move from dx),'approve',null);
select is((select verified_total from public.guest_registration_payment_summary(array[(select double_move from dx)])),450::numeric,'carried credit plus top-up covers exactly the new fee');
select is((select status from public.registrations where id=(select double_move from dx)),'confirmed','admin can approve once the fee difference is verified');
reset role;
update public.events set fee=200 where id=(select ev from fx);
select pg_temp.as_user((select u from us where role='admin')); set local role authenticated;
select public.change_guest_registration((select lower_fee from dx),(select double_move from dx),(select dD from fx),'move',(select rank1 from dx),(select g3 from dx),(select rank1 from dx),null,'Fake move to lower current fee');
select is((select status from public.registrations where id=(select lower_fee from dx)),'confirmed','lower-fee transfer keeps a paid entry confirmed');
select is((select verified_total from public.guest_registration_payment_summary(array[(select lower_fee from dx)])),450::numeric,'multiple transfers count each real receipt only once');
reset role;
select is((select sum(le.amount) from public.ledger_entries le join public.ledger_accounts a on a.id=le.account_id
  where a.owner_type='guest' and a.owner_id=(select person_id from public.event_participants where id=(select g1 from dx))),250::numeric,'lower fee leaves the excess on the same guest account');
select pg_temp.as_user((select u from us where role='admin')); set local role authenticated;
select public.create_event_participant((select wait_guest from dx),(select ev from fx),null,core.ulid(),'Fake Waitlisted Guest',null,'male','1990-01-01');
select public.register_guest_for_event((select wait_reg from dx),(select dS from fx),(select wait_guest from dx),(select rank1 from dx));
select is((select status from public.registrations where id=(select wait_reg from dx)),'waitlisted','full source division has an existing waitlist');
select public.change_guest_registration((select slot_replacement from dx),(select r2 from dx),(select dS from fx),'replace',(select rank1 from dx),null,null,(select g1 from dx),'Fake reserved place replacement');
select is((select status from public.registrations where id=(select wait_reg from dx)),'waitlisted','replacing a player retains the original place without promoting the waitlist');
select is((select status from public.registrations where id=(select slot_replacement from dx)),'requested','replacement takes the original place in a full division');
reset role;
select is((select count(*)::integer from public.event_roster_changes where source_registration_id=(select r1 from dx)),1,'retry never duplicates roster history');
select throws_ok(format($f$update public.event_roster_changes set reason='Rewrite history' where id=%L$f$,(select moved from dx)),'42501',null,'roster history is append-only');
select pg_temp.as_user((select u from us where role='manager')); set local role authenticated;
select throws_ok(format($f$select public.register_guest_for_event(%L,%L,%L,%L)$f$,core.ulid(),(select dOpen from fx),(select g1 from dx),(select rank1 from dx)),'42501',null,'manager cannot register a guest even with normal event management permissions');
select throws_ok(format($f$select public.change_guest_registration(%L,%L,%L,'move',%L,null,null,null,'Fake unauthorized move')$f$,core.ulid(),(select double_move from dx),(select dD from fx),(select rank1 from dx)),'42501',null,'manager cannot move or replace players');
select is((select count(*)::integer from public.event_roster_changes),0,'admin roster history is not readable by managers');
select is(has_table_privilege('authenticated','public.event_roster_changes','INSERT'),false,'clients cannot forge roster changes or carried payment credit');
reset role;
-- Drawn records stay immutable; changes during play are the emergency substitution step.
update public.settings set value='false'::jsonb where org_id=(select org from fx) and key='payments.required.event_registration';
select pg_temp.as_user((select u from us where role='admin')); set local role authenticated;
select public.decide_registration((select slot_replacement from dx),'approve',null);
select public.decide_registration((select fill from dx),'approve',null);
select public.run_draw((select id from public.division_stages where division_id=(select dS from fx) and stage_no=1));
select throws_ok(format($f$select public.change_guest_registration(%L,%L,%L,'move',%L,null,null,null,'Fake drawn transfer')$f$,core.ulid(),(select slot_replacement from dx),(select dOpen from fx),(select rank1 from dx)),'22023',null,'admin transfer cannot rewrite a drawn entry');
select is((select status from public.registrations where id=(select slot_replacement from dx)),'confirmed','blocked drawn transfer preserves the entry');
reset role;
select ok(exists(select 1 from core.audit_log where table_name='public.event_roster_changes'
  and record_id=(select moved from dx) and new_values->>'reason'='Fake division transfer'),'admin reason and roster change are audited');
select lives_ok('set constraints all immediate','all deferred destination registration references exist before commit');
select * from finish();
rollback;
