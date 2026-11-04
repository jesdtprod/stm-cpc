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

-- Standalone fake roster fixture; all data and assertions roll back.
grant execute on function core.registration_paid(text) to authenticated;
grant execute on function pg_temp.as_user(uuid) to public;
update public.settings set value='false'::jsonb where org_id=(select org from fx)
  and key in ('ranks.cpc_points_enabled','payments.required.event_registration');
create temp table rr as select core.ulid() as dv,core.ulid() as r1,core.ulid() as r2,core.ulid() as r3,
  core.ulid() as g1,core.ulid() as g2,core.ulid() as g3,core.ulid() as g4,core.ulid() as g5,core.ulid() as g6,
  core.ulid() as pay,core.ulid() as intent,
  (select r.id from public.ranks r join public.rank_ladders l on l.id=r.ladder_id
    where l.category_id=(select cat_novice from fx) and r.deleted_at is null order by r.sort_order limit 1) as rank;
grant select on rr to public;
create temp table answers(name text primary key,value jsonb);
grant all on answers to public;
create function pg_temp.edit(action text,source text,target text default null,sp integer default null,tp integer default null,replacement text default null,reason text default 'Fake roster correction')
returns jsonb language sql as $$
  select public.edit_division_roster(core.ulid(),(select dv from rr),action,source,target,sp,tp,replacement,reason,
    (select jsonb_object_agg(id,version) from public.registrations where id in(source,target)))
$$;
grant execute on function pg_temp.edit(text,text,text,integer,integer,text,text) to public;
select pg_temp.as_user((select u from us where role='admin'));
set local role authenticated;
select public.create_division((select dv from rr),(select ev from fx),'Fake Roster Doubles',(select cat_novice from fx),'doubles','male',null,null,null,2,(select tpl from fx),null);
select public.set_event_status((select ev from fx),'registration_open',null);
select public.set_event_guest_policy((select ev from fx),true,core.ulid());
select public.create_event_participant((select g1 from rr),(select ev from fx),null,core.ulid(),'Fake Roster One',null,'male','1990-01-01');
select public.create_event_participant((select g2 from rr),(select ev from fx),null,core.ulid(),'Fake Roster Two',null,'male','1990-01-01');
select public.create_event_participant((select g3 from rr),(select ev from fx),null,core.ulid(),'Fake Roster Three',null,'male','1990-01-01');
select public.create_event_participant((select g4 from rr),(select ev from fx),null,core.ulid(),'Fake Roster Four',null,'male','1990-01-01');
select public.create_event_participant((select g5 from rr),(select ev from fx),null,core.ulid(),'Fake Roster Five',null,'male','1990-01-01');
select public.create_event_participant((select g6 from rr),(select ev from fx),null,core.ulid(),'Fake Roster Six',null,'male','1990-01-01');
select public.register_guest_for_event((select r1 from rr),(select dv from rr),(select g1 from rr),(select rank from rr),(select g2 from rr),(select rank from rr));
select public.register_guest_for_event((select r2 from rr),(select dv from rr),(select g3 from rr),(select rank from rr),(select g4 from rr),(select rank from rr));
select public.decide_registration((select r1 from rr),'approve',null);
select public.decide_registration((select r2 from rr),'approve',null);
select public.register_guest_for_event((select r3 from rr),(select dv from rr),(select g5 from rr),(select rank from rr),(select g6 from rr),(select rank from rr));
select public.submit_guest_event_payment((select pay from rr),(select r1 from rr),'cash',null,300,null);
select public.decide_payment((select pay from rr),'verify',null,core.ulid());

select public.create_event_participant(core.ulid(),(select ev from fx),(select mid from us where role='m1'));
select public.create_event_participant(core.ulid(),(select ev from fx),(select mid from us where role='m4'));
select public.create_event_participant(core.ulid(),(select ev from fx),(select mid from us where role='m2'));
select is((select count(*)::integer from public.roster_replacement_choices((select r1 from rr),1) where member_id=(select mid from us where role='m1')),1,'replacement list includes an eligible member in the division rank range');
select is((select count(*)::integer from public.roster_replacement_choices((select r1 from rr),1) where member_id=(select mid from us where role='m4')),0,'replacement list hides a member in another rank category');
select is((select count(*)::integer from public.roster_replacement_choices((select r1 from rr),1) where member_id=(select mid from us where role='m2')),0,'replacement list also enforces gender eligibility');
select is((select count(*)::integer from public.roster_replacement_choices((select r1 from rr),1) where id in((select g1 from rr),(select g5 from rr))),0,'registered and waitlisted guests are excluded');
reset role;
-- Activation requires a rating row per active member; these NR rows roll back.
insert into public.member_cpc_ratings(org_id,member_id,discipline)
  select m.org_id,m.id,d.discipline from public.members m cross join (values('singles'),('doubles')) d(discipline)
  where m.deleted_at is null and m.status='active' and not exists(select 1 from public.member_cpc_ratings cr
    where cr.member_id=m.id and cr.discipline=d.discipline and cr.deleted_at is null);
update public.settings set value='true'::jsonb where key='ranks.cpc_points_enabled' and org_id=(select org from fx) and unit_id is null and deleted_at is null;
set local role authenticated;
insert into answers values('rated_guest',public.create_guest_event_participant(core.ulid(),(select ev from fx),core.ulid(),'Fake Eligible Novice Guest',null,'male','1990-01-01',null,null,2.500));
insert into answers values('wrong_rank_guest',public.create_guest_event_participant(core.ulid(),(select ev from fx),core.ulid(),'Fake Ineligible Beginner Guest',null,'male','1990-01-01',null,null,2.000));
select is((select count(*)::integer from public.roster_replacement_choices((select r1 from rr),2) where id=(select value->>'id' from answers where name='rated_guest')),1,'assessed guest within division rating range appears');
select is((select count(*)::integer from public.roster_replacement_choices((select r1 from rr),2) where id=(select value->>'id' from answers where name='wrong_rank_guest')),0,'guest outside division rating range never appears');
select throws_ok($$select public.roster_replacement_choices((select r1 from rr),3)$$,'22023',null,'replacement choices reject an invalid source player slot');
reset role;
update public.settings set value='false'::jsonb where key='ranks.cpc_points_enabled' and org_id=(select org from fx) and unit_id is null and deleted_at is null;
set local role authenticated;

insert into answers values('original_request',(select jsonb_object_agg(id,version) from public.registrations where id in((select r1 from rr),(select r2 from rr))));
insert into answers values('positions',(select jsonb_object_agg(id,n) from (
  select id,row_number() over(order by created_at,id) as n from public.registrations
    where division_id=(select dv from rr) and status in ('requested','confirmed')) ordered));
insert into answers values('order',public.edit_division_roster((select intent from rr),(select dv from rr),'team_swap',(select r1 from rr),(select r2 from rr),null,null,null,null,(select value from answers where name='original_request')));
select is((select meta->>'roster_position' from public.registrations where id=(select r1 from rr)),(select value->>(select r2 from rr) from answers where name='positions'),'whole team changes entry position');
select is((select count(*)::integer from public.registrations where division_id=(select dv from rr) and status='confirmed'),2,'team movement preserves confirmations');
select lives_ok($$select public.edit_division_roster((select intent from rr),(select dv from rr),'team_swap',(select r1 from rr),(select r2 from rr),null,null,null,null,(select value from answers where name='original_request'))$$,'identical retry is idempotent');
select throws_ok($$select public.edit_division_roster((select intent from rr),(select dv from rr),'team_swap',(select r2 from rr),(select r1 from rr),null,null,null,null,(select value from answers where name='original_request'))$$,'CP422',null,'idempotency key cannot be reused for a different swap');
select throws_ok($$select public.edit_division_roster(core.ulid(),(select dv from rr),'team_swap',(select r1 from rr),(select r2 from rr),null,null,null,null,(select value from answers where name='original_request'))$$,'CP409',null,'stale versions cannot overwrite newer roster');
select throws_ok($$select pg_temp.edit('player_swap',(select r1 from rr),(select r2 from rr),2,2,null,'x')$$,'22023',null,'player changes require a reason');
select throws_ok($$select pg_temp.edit('player_swap',(select r1 from rr),(select r2 from rr),3,2)$$,'22023',null,'invalid player slot rejected');
select throws_ok($$select pg_temp.edit('team_swap',(select r1 from rr),(select r3 from rr))$$,'CP409',null,'waitlisted entry cannot occupy an active slot');
insert into answers values('pending',public.submit_guest_event_payment(core.ulid(),(select r2 from rr),'cash',null,1,null));
select throws_ok($$select pg_temp.edit('player_swap',(select r1 from rr),(select r2 from rr),2,2)$$,'22023',null,'pending receipts block player changes');
select is((select count(*)::integer from public.registrations where id in((select r1 from rr),(select r2 from rr)) and status='confirmed'),2,'blocked receipt change preserves both original entries');
select public.decide_payment((select value->>'id' from answers where name='pending'),'reject','Fake receipt rejected for test',core.ulid());

insert into answers values('partners',pg_temp.edit('player_swap',(select r1 from rr),(select r2 from rr),2,2));
select is((select guest_partner_participant_id from public.registrations where id=(select value->>'source_id' from answers where name='partners')),(select g4 from rr),'partner moved into source team');
select is((select guest_partner_participant_id from public.registrations where id=(select value->>'target_id' from answers where name='partners')),(select g2 from rr),'reciprocal partner moved atomically');
select is((select count(*)::integer from public.registrations where id in((select r1 from rr),(select r2 from rr)) and status='withdrawn'),2,'original registrations retained as withdrawn history');
select is((select status from public.registrations where id=(select r3 from rr)),'waitlisted','full-capacity swap never promotes waitlist');
select is(core.registration_paid((select value->>'source_id' from answers where name='partners')),300::numeric,'same payer keeps verified payment credit');
select is((select meta->>'roster_position' from public.registrations where id=(select value->>'source_id' from answers where name='partners')),(select value->>(select r2 from rr) from answers where name='positions'),'replacement registration retains entry slot');
select is((select count(*)::integer from public.entries where division_id=(select dv from rr) and status='active'),2,'exactly two active entries remain after swapping');

select throws_ok($$select pg_temp.edit('replace',(select value->>'source_id' from answers where name='partners'),null,2,null,'g:'||(select g2 from rr))$$,'22023',null,'replacement cannot duplicate another registered player');
select is((select count(*)::integer from public.entries where division_id=(select dv from rr) and status='active'),2,'failed replacement rolls back all withdrawals');
select throws_ok($$select pg_temp.edit('replace',(select value->>'source_id' from answers where name='partners'),null,1,null,'m:'||(select mid from us where role='m2'))$$,'22023',null,'gender-ineligible replacement rejected');
insert into answers values('member',pg_temp.edit('replace',(select value->>'source_id' from answers where name='partners'),null,1,null,'m:'||(select mid from us where role='m1')));
select is((select member_id from public.registrations where id=(select value->>'source_id' from answers where name='member')),(select mid from us where role='m1'),'a member can replace the lead guest');
select is(core.registration_paid((select value->>'source_id' from answers where name='member')),0::numeric,'a new payer never inherits another guest payment');
select is((select status from public.payment_submissions where id=(select pay from rr)),'verified','original payment receipt is preserved');
select is((select count(*)::integer from public.event_roster_changes where event_id=(select ev from fx)),3,'append-only roster history captures both swaps and replacement');

select pg_temp.as_user((select u from us where role='m1'));
select throws_ok($$select public.roster_replacement_choices((select value->>'source_id' from answers where name='member'),1)$$,'42501',null,'members cannot list administrator replacement choices');
select throws_ok($$select pg_temp.edit('team_swap',(select value->>'source_id' from answers where name='member'),(select value->>'target_id' from answers where name='partners'))$$,'42501',null,'members cannot edit rosters');
reset role;
select pg_temp.as_user((select u from us where role='admin'));
set local role authenticated;
select public.set_event_status((select ev from fx),'registration_closed',null);
select lives_ok($$select pg_temp.edit('team_swap',(select value->>'source_id' from answers where name='member'),(select value->>'target_id' from answers where name='partners'))$$,'administrator can arrange a closed undrawn roster');
select public.run_draw((select id from public.division_stages where division_id=(select dv from rr) and stage_no=1));
select throws_ok($$select pg_temp.edit('team_swap',(select value->>'source_id' from answers where name='member'),(select value->>'target_id' from answers where name='partners'))$$,'22023',null,'official draw locks roster editing');
reset role;
select * from finish();
rollback;



