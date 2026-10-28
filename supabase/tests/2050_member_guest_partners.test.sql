begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();
create temp table fx as select (select id from public.orgs where code='cpc') as org,
  core.ulid() as ev, core.ulid() as dv, core.ulid() as high, core.ulid() as singles,
  core.ulid() as guest, core.ulid() as gp, core.ulid() as wrong, core.ulid() as wp,
  core.ulid() as reg, core.ulid() as reg2, core.ulid() as guest_lead_reg,
  core.ulid() as filler1, core.ulid() as filler2, core.ulid() as filler_person1, core.ulid() as filler_person2,
  (select id from public.format_templates where stages->0->>'stage_type'='round_robin'
    and jsonb_array_length(stages)=1 and deleted_at is null order by id limit 1) as tpl;
grant select on fx to public;
create function pg_temp.mk(p_role text,p_no text) returns uuid language plpgsql as $$
declare u uuid:=gen_random_uuid(); pid text:=core.ulid(); per text:=core.ulid(); mid text:=core.ulid(); org text:=(select org from fx);
begin
  insert into auth.users(id,email) values(u,lower(p_no)||'@members.example.test');
  insert into public.persons(id,org_id,display_name) values(per,org,'Fake '||p_no);
  insert into public.profiles(id,org_id,auth_user_id,person_id) values(pid,org,u,per);
  insert into public.org_members(org_id,profile_id,role_id) values(org,pid,(select id from public.roles where org_id=org and code=p_role));
  insert into public.members(id,org_id,person_id,profile_id,member_no) values(mid,org,per,pid,p_no);
  update public.members set status='invited' where id=mid;
  update public.members set status='pending_approval' where id=mid;
  update public.members set status='active' where id=mid;
  return u;
end $$;
create temp table us(role text,u uuid,mid text);
grant select on us to public;
insert into us values('admin',pg_temp.mk('admin','CPC-2042-99101'),null),('me',pg_temp.mk('member','CPC-2042-99102'),null),
  ('outsider',pg_temp.mk('member','CPC-2042-99103'),null);
update us set mid=(select m.id from public.members m join public.profiles p on p.id=m.profile_id where p.auth_user_id=us.u);
create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims',json_build_object('sub',u,'role','authenticated')::text,true) $$;
create function pg_temp.my_registration(p_div text) returns jsonb language sql as $$
  select d->'mine' from jsonb_array_elements(public.my_event_options()) e
    cross join lateral jsonb_array_elements(e->'divisions') d where d->>'id'=p_div
$$;
grant execute on function pg_temp.my_registration(text) to authenticated;
select pg_temp.as_user((select u from us where role='admin')); set local role authenticated;
select public.create_event((select ev from fx),'Fake Mixed Partners',current_date+70,current_date+70,'Fake Hall',0,null,null);
select public.set_event_guest_policy((select ev from fx),true,core.ulid());
select public.create_division((select dv from fx),(select ev from fx),'Beginner Doubles',
  (select id from public.categories where code='beginner' and deleted_at is null),'doubles',null,null,null,null,null,(select tpl from fx),null);
select public.create_division((select high from fx),(select ev from fx),'Beginner High Doubles',
  (select id from public.categories where code='beginner' and deleted_at is null),'doubles',null,null,
  (select id from public.ranks where code='beginner-high' and deleted_at is null),null,null,(select tpl from fx),null);
select public.create_division((select singles from fx),(select ev from fx),'Beginner Singles',
  (select id from public.categories where code='beginner' and deleted_at is null),'singles',null,null,null,null,null,(select tpl from fx),null);
select public.create_guest_event_participant((select guest from fx),(select ev from fx),(select gp from fx),'Fake Search Guest',null,null,null,null,2.800,null);
select public.create_guest_event_participant((select wrong from fx),(select ev from fx),(select wp from fx),'Fake Search Wrong',null,null,null,null,null,3.800);
select public.set_event_status((select ev from fx),'registration_open',null);
reset role;
insert into public.member_cpc_ratings(org_id,member_id,discipline)
  select m.org_id,m.id,d.discipline from public.members m cross join (values('singles'),('doubles')) d(discipline)
  where m.deleted_at is null and m.status='active' and not exists(select 1 from public.member_cpc_ratings r
    where r.member_id=m.id and r.discipline=d.discipline and r.deleted_at is null);
update public.settings set value='true' where key='ranks.cpc_points_enabled' and unit_id is null and deleted_at is null;
update public.settings set value='false' where key='events.registration_approval_required' and unit_id is null and deleted_at is null;
select pg_temp.as_user((select u from us where role='me')); set local role authenticated;
select is((select count(*)::int from public.eligible_division_partners((select dv from fx),'Search') where guest_participant_id=(select guest from fx)),1,
  'NR guest with a Singles rating can be found for Beginner Low Doubles');
select is((select count(*)::int from public.eligible_division_partners((select dv from fx),'Search') where guest_participant_id=(select wrong from fx)),0,
  'guest outside the Doubles category is hidden');
select is((select count(*)::int from public.eligible_division_partners((select dv from fx),'F')),0,'two-character search minimum');
select throws_ok(format('select public.register_for_event_with_guest(%L,%L,%L)',core.ulid(),(select high from fx),(select guest from fx)),
  '22023',null,'NR cannot save a higher-minimum entry');
select throws_ok(format('select public.register_for_event_with_guest(%L,%L,%L)',core.ulid(),(select singles from fx),(select guest from fx)),
  '22023',null,'singles cannot take a guest partner');
select throws_ok(format('select public.register_for_event_with_guest(%L,%L,%L)',core.ulid(),(select dv from fx),(select wrong from fx)),
  '22023',null,'save rejects a wrong-category guest');
select lives_ok(format('select public.register_for_event_with_guest(%L,%L,%L)',(select reg from fx),(select dv from fx),(select guest from fx)),
  'member can register with an NR guest in Beginner Low');
select is(pg_temp.my_registration((select dv from fx))->>'status','confirmed','division reports an approved owner registration');
select is((pg_temp.my_registration((select dv from fx))->>'is_owner')::boolean,true,'owner can manage the registration');
select is((public.register_for_event_with_guest((select reg from fx),(select dv from fx),(select guest from fx))->>'replayed')::boolean,true,'retry replays');
select throws_ok(format('select public.register_for_event_with_guest(%L,%L,%L)',(select reg from fx),(select dv from fx),(select wrong from fx)),
  'CP422',null,'retry cannot change the partner');
select throws_ok(format('select public.register_for_event_with_guest(%L,%L,%L)',(select reg2 from fx),(select dv from fx),(select guest from fx)),
  '23505',null,'duplicate roster is refused');
reset role;
select is((select member_id from public.registrations where id=(select reg from fx)),(select mid from us where role='me'),'member owns registration');
select is(core.registration_payer((select reg from fx)),(select mid from us where role='me'),'member remains payer');
select is((select count(*)::int from public.entry_members em join public.entries e on e.id=em.entry_id where e.registration_id=(select reg from fx)),1,'confirmed team has one member');
select is((select count(*)::int from public.entry_guests eg join public.entries e on e.id=eg.entry_id where e.registration_id=(select reg from fx)),1,'confirmed team has one guest');
select ok(not exists(select 1 from public.event_participant_cpc_ratings where participant_id=(select guest from fx) and discipline='doubles' and points is not null),'guest stays NR');
update public.event_participant_cpc_ratings set points=2.100 where participant_id=(select wrong from fx) and discipline='doubles';
update public.divisions set max_entries=2 where id=(select dv from fx);
select pg_temp.as_user((select u from us where role='admin')); set local role authenticated;
select public.create_guest_event_participant((select filler1 from fx),(select ev from fx),(select filler_person1 from fx),'Fake Capacity Guest One');
select public.create_guest_event_participant((select filler2 from fx),(select ev from fx),(select filler_person2 from fx),'Fake Capacity Guest Two');
select public.register_guest_for_event(core.ulid(),(select dv from fx),(select filler1 from fx),null,(select filler2 from fx),null);
select is((select count(*)::int from public.eligible_division_partners((select dv from fx),'Search Wrong') where guest_participant_id=(select wrong from fx)),1,
  'rated guest within the band can be found');
select is((public.register_for_event_with_guest((select reg2 from fx),(select dv from fx),(select wrong from fx))->>'status'),'waitlisted',
  'mixed teams follow capacity and waitlist rules');
select is(pg_temp.my_registration((select dv from fx))->>'status','waitlisted','division reports waitlisted registration');
reset role;
select pg_temp.as_user((select u from us where role='me')); set local role authenticated;
select lives_ok(format('select public.withdraw_registration(%L,''Fake withdrawal'')',(select reg from fx)),'member can withdraw their mixed team');
reset role;
select is((select status from public.registrations where id=(select reg2 from fx)),'confirmed','waitlist promotion confirms the next mixed team');
select is((select count(*)::int from public.entry_guests eg join public.entries e on e.id=eg.entry_id where e.registration_id=(select reg2 from fx)),1,
  'waitlist promotion creates the guest roster');
select pg_temp.as_user((select u from us where role='me')); set local role authenticated;
select throws_ok(format('select public.withdraw_registration(%L,''Fake other withdrawal'')',(select reg2 from fx)),
  '42501',null,'non-owner member cannot withdraw another registration');
reset role;
select pg_temp.as_user((select u from us where role='admin')); set local role authenticated;
select is((select count(*)::int from public.eligible_division_partners((select dv from fx),'Search Wrong')),0,'already registered guest is excluded from search');
select public.withdraw_registration((select reg2 from fx),'Fake owner withdrawal');
reset role;
update public.settings set value='true' where key='events.registration_approval_required' and unit_id is null and deleted_at is null;
select pg_temp.as_user((select u from us where role='admin')); set local role authenticated;
select lives_ok(format('select public.register_guest_for_event(%L,%L,%L,null,%L,null)',
  (select guest_lead_reg from fx),(select dv from fx),(select guest from fx),
  public.ensure_event_member_participant(core.ulid(),(select ev from fx),(select mid from us where role='me'))->>'id'),
  'admin registers a guest-led team with the member as partner');
reset role;
select pg_temp.as_user((select u from us where role='me')); set local role authenticated;
select is(pg_temp.my_registration((select dv from fx))->>'status','requested','partner sees waiting-for-approval state');
select is((pg_temp.my_registration((select dv from fx))->>'is_owner')::boolean,false,'guest-led partner is not treated as payer or owner');
reset role;
select pg_temp.as_user((select u from us where role='admin')); set local role authenticated;
select public.decide_registration((select guest_lead_reg from fx),'approve',null);
reset role;
select pg_temp.as_user((select u from us where role='me')); set local role authenticated;
select is(pg_temp.my_registration((select dv from fx))->>'status','confirmed','partner sees approval after admin action');
select is((select status from public.registrations where id=(select guest_lead_reg from fx)),'confirmed',
  'partner RLS permits the approved row and its Realtime update');
select throws_ok(format('update public.registrations set status=''withdrawn'' where id=%L',(select guest_lead_reg from fx)),
  '42501',null,'partner read access does not permit direct writes');
reset role;
select pg_temp.as_user((select u from us where role='admin')); set local role authenticated;
select public.withdraw_registration((select guest_lead_reg from fx),'Fake cancellation');
reset role;
select pg_temp.as_user((select u from us where role='me')); set local role authenticated;
select is((select status from public.registrations where id=(select guest_lead_reg from fx)),'withdrawn',
  'partner keeps cancellation visibility after entry withdrawal');
reset role;
select pg_temp.as_user((select u from us where role='outsider')); set local role authenticated;
select is((select count(*)::int from public.registrations where id=(select guest_lead_reg from fx)),0,
  'unrelated member cannot read another team registration');
reset role;
select set_config('request.jwt.claims','',true);
select throws_ok(format('select * from public.eligible_division_partners(%L,''Search'')',(select dv from fx)),'42501',null,'signed-out search is refused');
select is(has_function_privilege('anon','public.register_for_event_with_guest(text,text,text)','execute'),false,'anonymous registration denied');
select * from finish();
rollback;
