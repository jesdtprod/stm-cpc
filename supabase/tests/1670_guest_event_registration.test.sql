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


-- Guest registration assertions (setup above uses fake data only).
update public.settings set value = 'true'::jsonb where org_id = (select org from fx) and key in ('events.registration_approval_required','events.waitlist_enabled');
update public.settings set value = 'false'::jsonb where org_id = (select org from fx) and key = 'payments.required.event_registration';
create temp table gx as select core.ulid() as person1, core.ulid() as person2, core.ulid() as person3,
  core.ulid() as ep1, core.ulid() as ep2, core.ulid() as ep3, core.ulid() as emp,
  core.ulid() as reg1, core.ulid() as reg2, core.ulid() as reg3, core.ulid() as reg4,
  core.ulid() as pay1, core.ulid() as policy_key,
  (select r.id from public.ranks r join public.rank_ladders l on l.id = r.ladder_id
    where l.category_id = (select cat_novice from fx) and r.deleted_at is null order by r.sort_order limit 1) as rank1,
  (select r.id from public.ranks r join public.rank_ladders l on l.id = r.ladder_id
    where l.category_id = (select cat_adv from fx) and r.deleted_at is null order by r.sort_order limit 1) as wrong_rank;
grant select on gx to public;
select is(has_function_privilege('anon','public.register_guest_for_event(text,text,text,text,text,text)','execute'),false,'anonymous guests cannot self-register');
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select is((select allow_guest_players from public.events where id = (select ev from fx)),false,'events default to members only');
select lives_ok(format($f$select public.set_event_guest_policy(%L,true,%L)$f$,(select ev from fx),(select policy_key from gx)),'admin enables guests in draft');
select lives_ok(format($f$select public.set_event_guest_policy(%L,true,%L)$f$,(select ev from fx),(select policy_key from gx)),'guest policy retry is safe');
select throws_ok(format($f$select public.set_event_guest_policy(%L,false,%L)$f$,(select ev from fx),(select policy_key from gx)),'CP422',null,'policy key cannot be reused with different content');
select public.create_event_participant((select ep1 from gx),(select ev from fx),null,(select person1 from gx),'Fake Guest One','09000000001','male','1990-01-01');
select public.create_event_participant((select ep2 from gx),(select ev from fx),null,(select person2 from gx),'Fake Guest Two','09000000002','female','1992-01-01');
select public.create_event_participant((select ep3 from gx),(select ev from fx),null,(select person3 from gx),'Fake Guest Three',null,'male','1993-01-01');
select public.create_event_participant((select emp from gx),(select ev from fx),(select mid from us where role = 'm1'));
select public.set_event_status((select ev from fx),'registration_open',null);
select lives_ok(format($f$select public.set_event_guest_policy(%L,true,%L)$f$,(select ev from fx),core.ulid()),'admin can keep guests enabled after draft');
select throws_ok(format($f$select public.register_guest_for_event(%L,%L,%L,%L)$f$,core.ulid(),(select dS from fx),(select ep2 from gx),(select rank1 from gx)),'22023',null,'gender eligibility is enforced');
select throws_ok(format($f$select public.register_guest_for_event(%L,%L,%L,%L)$f$,core.ulid(),(select dA from fx),(select ep1 from gx),(select rank1 from gx)),'22023',null,'age eligibility is enforced');
select throws_ok(format($f$select public.register_guest_for_event(%L,%L,%L,%L)$f$,core.ulid(),(select dS from fx),(select ep1 from gx),(select wrong_rank from gx)),'22023',null,'rank category is enforced');
select throws_ok(format($f$select public.register_guest_for_event(%L,%L,%L,null)$f$,core.ulid(),(select dS from fx),(select ep1 from gx)),'22023',null,'guest rank assessment is required');
select lives_ok(format($f$select public.register_guest_for_event(%L,%L,%L,%L)$f$,(select reg1 from gx),(select dS from fx),(select ep1 from gx),(select rank1 from gx)),'eligible guest registers');
select is((select fee_snapshot from public.registrations where id = (select reg1 from gx)),300::numeric,'fee is computed from event settings');
select is((select public.register_guest_for_event((select reg1 from gx),(select dS from fx),(select ep1 from gx),(select rank1 from gx))->>'replayed'),'true','guest registration retry does not duplicate charges or entries');
select throws_ok(format($f$select public.register_guest_for_event(%L,%L,%L,%L)$f$,core.ulid(),(select dS from fx),(select ep1 from gx),(select rank1 from gx)),'22023',null,'duplicate guest registration in a division is refused');
select lives_ok(format($f$select public.register_guest_for_event(%L,%L,%L,%L)$f$,(select reg2 from gx),(select dOpen from fx),(select ep1 from gx),(select rank1 from gx)),'same guest may enter a different division');
select lives_ok(format($f$select public.register_guest_for_event(%L,%L,%L,%L,%L,%L)$f$,(select reg3 from gx),(select dD from fx),(select ep1 from gx),(select rank1 from gx),(select ep2 from gx),(select rank1 from gx)),'two guests may form a doubles team');
select throws_ok(format($f$select public.register_guest_for_event(%L,%L,%L,%L,%L,%L)$f$,core.ulid(),(select dD from fx),(select ep3 from gx),(select rank1 from gx),(select ep2 from gx),(select rank1 from gx)),'22023',null,'guest cannot be reused as a doubles partner in that division');
select lives_ok(format($f$select public.register_guest_for_event(%L,%L,%L,%L)$f$,(select reg4 from gx),(select dS from fx),(select ep3 from gx),(select rank1 from gx)),'second guest takes final singles place');
select throws_ok(format($f$select public.register_guest_for_event(%L,%L,%L,%L)$f$,core.ulid(),(select dS from fx),(select emp from gx),(select rank1 from gx)),'22023',null,'member participant cannot masquerade as a guest');
reset role;
update public.settings set value = 'true'::jsonb where org_id = (select org from fx) and key = 'payments.required.event_registration';
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select throws_ok(format($f$select public.decide_registration(%L,'approve',null)$f$,(select reg1 from gx)),'22023',null,'required payment must be verified before approval');
select throws_ok(format($f$select public.submit_guest_event_payment(%L,%L,'cash',null,301,null)$f$,core.ulid(),(select reg1 from gx)),'22023',null,'guest overpayment is refused');
select throws_ok(format($f$select public.submit_guest_event_payment(%L,%L,'cash',null,-1,null)$f$,core.ulid(),(select reg1 from gx)),'22023',null,'negative guest payments are refused');
select throws_ok(format($f$select public.submit_guest_event_payment(%L,%L,'cash',null,1.001,null)$f$,core.ulid(),(select reg1 from gx)),'22023',null,'guest payments require at most two decimals');
select throws_ok(format($f$select public.submit_guest_event_payment(%L,%L,'gcash',null,300,null)$f$,core.ulid(),(select reg1 from gx)),'22023',null,'noncash guest payment cannot bypass club method and proof rules');
select throws_ok(format($f$select public.submit_guest_event_payment(%L,%L,'cash',null,300,'foreign/folder/fake.png')$f$,core.ulid(),(select reg1 from gx)),'42501',null,'guest proof must be in the submitting staff profile folder');
select lives_ok(format($f$select public.submit_guest_event_payment(%L,%L,'cash',null,300,null)$f$,(select pay1 from gx),(select reg1 from gx)),'staff records guest cash payment');
select is((select public.submit_guest_event_payment((select pay1 from gx),(select reg1 from gx),'cash',null,300,null)->>'replayed'),'true','guest payment retry returns the original receipt');
select throws_ok(format($f$select public.submit_guest_event_payment(%L,%L,'cash',null,299,null)$f$,(select pay1 from gx),(select reg1 from gx)),'CP422',null,'payment ID cannot be reused with another amount');
select throws_ok(format($f$select public.submit_guest_event_payment(%L,%L,'cash',null,1,null)$f$,core.ulid(),(select reg1 from gx)),'22023',null,'pending payments count toward the fee limit');
select is((select payer_name_snapshot from public.payment_submissions where id = (select pay1 from gx)),'Fake Guest One','payment review uses the server guest name snapshot');
select lives_ok(format($f$select public.decide_payment(%L,'verify',null,%L)$f$,(select pay1 from gx),core.ulid()),'guest receipt uses normal payment verification');
select lives_ok(format($f$select public.decide_registration(%L,'approve',null)$f$,(select reg1 from gx)),'paid guest registration confirms');
select is((select count(*)::integer from public.entries where registration_id = (select reg1 from gx)),1,'guest confirmation creates one tournament entry');
select is((select count(*)::integer from public.entry_guests g join public.entries e on e.id = g.entry_id where e.registration_id = (select reg1 from gx)),1,'guest is recorded in the guest roster');
select is((select count(*)::integer from public.entry_members m join public.entries e on e.id = m.entry_id where e.registration_id = (select reg1 from gx)),0,'guest does not create a member rank target');
reset role;
select is((select core.entry_name(id) from public.entries where registration_id = (select reg1 from gx)),'Fake Guest One','brackets show guest names');
select is((select sum(le.amount) from public.ledger_entries le join public.ledger_accounts a on a.id = le.account_id where a.owner_type = 'guest' and a.owner_id = (select person1 from gx)),0::numeric,'guest payment and fee balance on the guest account');
select is((select count(*)::integer from public.members where person_id in ((select person1 from gx),(select person2 from gx))),0,'guest registration creates no fake memberships');
select pg_temp.as_user((select u from us where role = 'm1')); set local role authenticated;
select throws_ok(format($f$select public.withdraw_registration(%L,null)$f$,(select reg1 from gx)),'42501',null,'ordinary member cannot withdraw a guest registration through a null owner');
select throws_ok(format($f$select public.submit_event_payment(%L,%L,'cash',null,1,null)$f$,core.ulid(),(select reg1 from gx)),'42501',null,'member payment API cannot take ownership of guest payments');
select throws_ok(format($f$select public.register_guest_for_event(%L,%L,%L,%L)$f$,core.ulid(),(select dOpen from fx),(select ep2 from gx),(select rank1 from gx)),'42501',null,'members cannot register guests');
select throws_ok(format($f$select public.submit_guest_event_payment(%L,%L,'cash',null,1,null)$f$,core.ulid(),(select reg2 from gx)),'42501',null,'ordinary members cannot submit guest receipts');
reset role;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select lives_ok(format($f$select public.withdraw_registration(%L,'Fake guest withdrew')$f$,(select reg1 from gx)),'staff withdrawal uses normal guest refund flow');
reset role;
select is((select sum(le.amount) from public.ledger_entries le join public.ledger_accounts a on a.id = le.account_id where a.owner_type = 'guest' and a.owner_id = (select person1 from gx)),300::numeric,'withdrawal reverses the charge while preserving the received payment');
-- More lifecycle coverage: capacity, mixed teams, post-close approval and money reversals.
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select lives_ok(format($f$select public.void_payment(%L,'Fake guest payment returned',%L)$f$,(select pay1 from gx),core.ulid()),'verified guest payments can be voided through normal payment controls');
reset role;
select is((select sum(le.amount) from public.ledger_entries le join public.ledger_accounts a on a.id = le.account_id where a.owner_type = 'guest' and a.owner_id = (select person1 from gx)),0::numeric,'voiding the receipt balances the refunded guest account');
update public.settings set value = 'false'::jsonb where org_id = (select org from fx) and key = 'payments.required.event_registration';
create temp table extra as select core.ulid() as ev, core.ulid() as members_only, core.ulid() as members_div,
  core.ulid() as small, core.ulid() as doubles, core.ulid() as ep1, core.ulid() as ep2, core.ulid() as ep3,
  core.ulid() as emp, core.ulid() as excluded, core.ulid() as r1, core.ulid() as r2, core.ulid() as mixed,
  core.ulid() as other_team, core.ulid() as policy_key;
grant select on extra to public;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.create_event((select ev from extra),'Fake Free Guest Event',(select day1 from fx),(select day1 from fx),null,0,null,null);
select public.set_event_guest_policy((select ev from extra),true,(select policy_key from extra));
select public.create_division((select small from extra),(select ev from extra),'Fake Two Spots',(select cat_novice from fx),'singles',null,null,null,null,2,(select tpl from fx),null);
select public.create_division((select doubles from extra),(select ev from extra),'Fake Mixed Teams',(select cat_novice from fx),'doubles','mixed',null,null,null,null,(select tpl from fx),null);
select public.create_event_participant((select ep1 from extra),(select ev from extra),null,(select person1 from gx));
select public.create_event_participant((select ep2 from extra),(select ev from extra),null,(select person2 from gx));
select public.create_event_participant((select ep3 from extra),(select ev from extra),null,(select person3 from gx));
select public.create_event_participant((select emp from extra),(select ev from extra),(select mid from us where role = 'm1'));
select public.set_event_status((select ev from extra),'registration_open',null);
select public.register_for_event(core.ulid(),(select small from extra),null,(select mid from us where role = 'm1'),null);
select public.register_guest_for_event((select r1 from extra),(select small from extra),(select ep1 from extra),(select rank1 from gx));
select public.register_guest_for_event((select r2 from extra),(select small from extra),(select ep2 from extra),(select rank1 from gx));
select is((select status from public.registrations where id = (select r2 from extra)),'waitlisted','guest waits when a division is full');
select throws_ok(format($f$select public.register_guest_for_event(%L,%L,%L,%L)$f$,(select r1 from extra),(select small from extra),(select ep3 from extra),(select rank1 from gx)),'CP422',null,'changed guest payload under a reused registration ID is refused');
reset role;
update public.settings set value = 'false'::jsonb where org_id = (select org from fx) and key = 'events.waitlist_enabled';
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select throws_ok(format($f$select public.register_guest_for_event(%L,%L,%L,%L)$f$,core.ulid(),(select small from extra),(select ep3 from extra),(select rank1 from gx)),'22023',null,'full division refuses guests when waitlists are disabled');
select public.withdraw_registration((select r1 from extra),'Fake guest changed plans');
select is((select status from public.registrations where id = (select r2 from extra)),'requested','guest waitlist promotes after withdrawal');
select public.decide_registration((select r2 from extra),'approve',null);
select is((select status from public.registrations where id = (select r2 from extra)),'confirmed','free guest entry confirms without a payment');
select lives_ok(format($f$select public.register_guest_for_event(%L,%L,%L,%L,%L,null)$f$,(select mixed from extra),(select doubles from extra),(select ep1 from extra),(select rank1 from gx),(select emp from extra)),'a guest and a member can form a doubles team');
reset role;
select pg_temp.as_user((select u from us where role = 'm1')); set local role authenticated;
select throws_ok(format($f$select public.register_for_event(%L,%L,%L)$f$,core.ulid(),(select doubles from extra),(select mid from us where role = 'm2')),'23505',null,'member registration cannot reuse a member already partnering with a guest');
reset role;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.register_guest_for_event((select other_team from extra),(select doubles from extra),(select ep2 from extra),(select rank1 from gx),(select ep3 from extra),(select rank1 from gx));
select public.set_event_status((select ev from extra),'registration_closed',null);
select lives_ok(format($f$select public.decide_registration(%L,'approve',null)$f$,(select mixed from extra)),'mixed team can be approved after registration closes');
select lives_ok(format($f$select public.decide_registration(%L,'approve',null)$f$,(select other_team from extra)),'all-guest team can be approved after registration closes');
reset role;
select is((select count(*)::integer from public.entry_guests g join public.entries e on e.id = g.entry_id where e.registration_id = (select other_team from extra)),2,'all-guest doubles has two guest roster rows');
select is((select count(*)::integer from public.entry_members m join public.entries e on e.id = m.entry_id where e.registration_id = (select mixed from extra)),1,'mixed doubles retains exactly one real member for rank credit');
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select lives_ok(format($f$select public.run_draw(%L)$f$,(select id from public.division_stages where division_id = (select doubles from extra) and stage_no = 1)),'guest and mixed teams enter the normal draw and match engine');
select is((select count(*)::integer from public.event_participant_choices((select ev from extra))),4,'staff can select current event participants');
select is((select count(*)::integer from public.search_event_players((select ev from extra),'Fake Guest')),3,'staff search reuses existing guest identities without contact disclosure');
select lives_ok(format($f$select public.forfeit_match(%L,%L,'Fake match participation test')$f$,
  (select m.id from public.matches m join public.division_stages s on s.id = m.division_stage_id where s.division_id = (select doubles from extra) limit 1),
  (select e.id from public.entries e where e.registration_id = (select other_team from extra))),
  'guest team can finish a match through normal scoring controls');
reset role;
insert into public.rank_rules(org_id,name,conditions,action,levels,priority,exclude_forfeits)
  select org,'Fake Guest Participation Retain','{}'::jsonb,'retain',0,-100000,false from fx;
update public.settings set value = 'true'::jsonb where org_id = (select org from fx) and key = 'ranks.movement_enabled';
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select lives_ok(format($f$select public.finalize_division(%L)$f$,(select doubles from extra)),'guest division finalizes through the normal results engine');
reset role;
select is((select count(*)::integer from public.division_results where division_id = (select doubles from extra)),2,'both teams receive results');
select is((select count(*)::integer from public.rank_history where division_id = (select doubles from extra)),1,'only the actual member receives a rank history row');
select is((select member_id from public.rank_history where division_id = (select doubles from extra)),(select mid from us where role = 'm1'),'rank credit belongs to the member partner, never the guest');
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.create_event((select members_only from extra),'Fake Members Only',(select day1 from fx),(select day1 from fx),null,0,null,null);
select public.create_division((select members_div from extra),(select members_only from extra),'Fake Members Only Singles',(select cat_novice from fx),'singles',null,null,null,null,null,(select tpl from fx),null);
select public.create_event_participant((select excluded from extra),(select members_only from extra),null,(select person1 from gx));
select public.set_event_status((select members_only from extra),'registration_open',null);
select throws_ok(format($f$select public.register_guest_for_event(%L,%L,%L,%L)$f$,core.ulid(),(select members_div from extra),(select excluded from extra),(select rank1 from gx)),'22023',null,'members-only events reject guest registration even with a participant identity');
select throws_ok(format($f$select public.register_guest_for_event(%L,%L,%L,%L)$f$,core.ulid(),(select members_div from extra),(select ep1 from extra),(select rank1 from gx)),'22023',null,'participant from another event cannot be registered');
reset role;
select pg_temp.as_user((select u from us where role = 'm1')); set local role authenticated;
select throws_ok(format($f$select * from public.event_participant_choices(%L)$f$,(select ev from extra)),'42501',null,'participant selector is private to event staff');
select throws_ok(format($f$select * from public.search_event_players(%L,'Fake Guest')$f$,(select ev from extra)),'42501',null,'ordinary members cannot search guest identities');
select is(has_table_privilege('authenticated','public.entry_guests','INSERT'),false,'clients cannot forge guest rosters');
select is(has_table_privilege('authenticated','public.entry_guests','UPDATE'),false,'clients cannot replace guest roster identities');
select is((select count(*)::integer from public.event_participants where event_id = (select ev from extra)),0,'member cannot read guest contact-linked participant identities');
select is((select count(*)::integer from public.entry_guests g join public.entries e on e.id = g.entry_id where e.division_id = (select doubles from extra)),3,'drawn guest roster shares names without contact details');
reset role;
-- Receipt verification can be the last requirement when manual approval is off.
update public.settings set value = 'false'::jsonb where org_id = (select org from fx) and key = 'events.registration_approval_required';
update public.settings set value = 'true'::jsonb where org_id = (select org from fx) and key = 'payments.required.event_registration';
create temp table automatic as select core.ulid() as reg, core.ulid() as pay;
grant select on automatic to public;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.register_guest_for_event((select reg from automatic),(select dP from fx),(select ep3 from gx),(select rank1 from gx));
select is((select status from public.registrations where id = (select reg from automatic)),'requested','automatic guest confirmation still waits for required payment');
select public.submit_guest_event_payment((select pay from automatic),(select reg from automatic),'cash',null,300,null);
select lives_ok(format($f$select public.decide_payment(%L,'verify',null,%L)$f$,(select pay from automatic),core.ulid()),'verifying the guest payment triggers automatic confirmation');
select is((select status from public.registrations where id = (select reg from automatic)),'confirmed','paid guest automatically confirms with manual approval off');
select public.decide_payment((select pay from automatic),'verify',null,core.ulid());
reset role;
select is((select count(*)::integer from public.entries where registration_id = (select reg from automatic)),1,'automatic confirmation and verification retries create one entry');
select is((select count(*)::integer from public.ledger_entries where source_type = 'event_registration' and source_id = (select reg from automatic) and client_ref = 'charge'),1,'automatic confirmation charges the fee exactly once');
select * from finish();
rollback;
