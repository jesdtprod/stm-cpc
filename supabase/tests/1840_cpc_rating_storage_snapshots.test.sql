begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create function pg_temp.mk(p_role text, p_no text) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); person text := core.ulid(); mid text := core.ulid(); org text := (select id from public.orgs where code = 'cpc');
begin
  insert into auth.users(id,email) values(u,lower(p_no)||'@members.example.test');
  insert into public.persons(id,org_id,display_name) values(person,org,'Fake '||p_no);
  insert into public.profiles(id,org_id,auth_user_id,person_id) values(pid,org,u,person);
  insert into public.org_members(org_id,profile_id,role_id) values(org,pid,(select id from public.roles where org_id=org and code=p_role));
  insert into public.members(id,org_id,person_id,profile_id,member_no) values(mid,org,person,pid,p_no);
  update public.members set status='invited' where id=mid;
  update public.members set status='pending_approval' where id=mid;
  update public.members set status='active' where id=mid;
  return u;
end $$;

create temp table us(role text primary key, u uuid, member_id text);
insert into us(role,u) values ('admin',pg_temp.mk('admin','CPC-2031-98401')), ('member',pg_temp.mk('member','CPC-2031-98402'));
update us set member_id=(select m.id from public.members m join public.profiles p on p.id=m.profile_id where p.auth_user_id=us.u);
create temp table fx as select
  (select id from public.orgs where code='cpc') as org, core.ulid() as event_id, core.ulid() as division_id,
  core.ulid() as guest_participant_id, core.ulid() as guest_person_id, core.ulid() as guest_registration_id,
  core.ulid() as key1, core.ulid() as key2, core.ulid() as key3, core.ulid() as key4, core.ulid() as member_registration_id,
  (select id from public.categories where code='novice' and deleted_at is null) as category_id,
  (select r.id from public.ranks r join public.rank_ladders l on l.id=r.ladder_id join public.categories c on c.id=l.category_id
    where c.code='novice' and r.deleted_at is null order by r.sort_order limit 1) as rank_id,
  (select id from public.format_templates where lower(name) like 'split single elimination%' and deleted_at is null) as template_id;
grant select on us,fx to public;
insert into public.member_ranks(org_id,member_id,rank_id) values((select org from fx),(select member_id from us where role='member'),(select rank_id from fx));

select is(has_table_privilege('anon','public.member_cpc_ratings','select'),false,'anonymous cannot read member CPC ratings');
select is(has_column_privilege('authenticated','public.member_cpc_ratings','points','UPDATE'),false,'browser cannot directly set member CPC points');
select is(has_column_privilege('authenticated','public.division_cpc_rating_snapshots','starting_points','INSERT'),false,'browser cannot write rating snapshots');
update public.settings set value='false'::jsonb
  where key='events.registration_approval_required' and unit_id is null and deleted_at is null;

select pg_temp.as_user((select u from us where role='member')); set local role authenticated;
select throws_ok(format('select public.set_member_cpc_rating(%L,''singles'',2.500,0,%L,%L)',(select member_id from us where role='member'),(select key1 from fx),'Fake assessment'),'42501',null,'member cannot assess their own official CPC points');
select is((select count(*)::integer from public.member_cpc_ratings where discipline='singles' and member_id=(select member_id from us where role='member')),0,'unrated member has no implicit points row');
reset role;

select pg_temp.as_user((select u from us where role='admin')); set local role authenticated;
select lives_ok(format('select public.set_member_cpc_rating(%L,''singles'',2.500,0,%L,%L)',(select member_id from us where role='member'),(select key1 from fx),'Fake assessed starting point'),'rank override admin initializes member points');
select is((select points from public.member_cpc_ratings where discipline='singles' and member_id=(select member_id from us where role='member') and deleted_at is null),2.500,'assessment stores three-decimal member points');
select is((select eligible_match_count from public.member_cpc_ratings where discipline='singles' and member_id=(select member_id from us where role='member')),0,'assessment starts at zero eligible matches');
select lives_ok(format('select public.set_member_cpc_rating(%L,''singles'',2.500,0,%L,%L)',(select member_id from us where role='member'),(select key1 from fx),'Fake assessed starting point'),'lost-response member assessment replays');
select is((select count(*)::integer from public.member_cpc_ratings where discipline='singles' and member_id=(select member_id from us where role='member')),1,'assessment retry has one current row');
select throws_ok(format('select public.set_member_cpc_rating(%L,''singles'',2.600,0,%L,%L)',(select member_id from us where role='member'),(select key1 from fx),'Different request'),'CP422',null,'same assessment key cannot change points');
select throws_ok(format('select public.set_member_cpc_rating(%L,''singles'',0,1,%L,%L)',(select member_id from us where role='member'),core.ulid(),'Bad points'),'22023',null,'zero is not a CPC rating');
select throws_ok(format('select public.set_member_cpc_rating(%L,''singles'',2.750,0,%L,%L)',(select member_id from us where role='member'),core.ulid(),'Stale reassessment'),'CP409',null,'stale version cannot overwrite member points');
select lives_ok(format('select public.set_member_cpc_rating(%L,''singles'',2.750,1,%L,%L)',(select member_id from us where role='member'),core.ulid(),'Fake reassessment'),'admin reassesses member points');
select is((select points from public.member_cpc_ratings where discipline='singles' and member_id=(select member_id from us where role='member') and deleted_at is null),2.750,'reassessment updates current points');
select is((select count(*)::integer from public.member_cpc_rating_history where member_id=(select member_id from us where role='member')),2,'each assessment appends one history row');
select is((select points_before from public.member_cpc_rating_history where member_id=(select member_id from us where role='member') and points_after=2.750),2.500::numeric(4,3),'history keeps the value before the reassessment');
select is((select points_before from public.member_cpc_rating_history where member_id=(select member_id from us where role='member') and points_after=2.500),null::numeric(4,3),'first assessment history starts from unrated');
select lives_ok(format('select public.initialize_member_cpc_ratings(%L)',(select key4 from fx)),'admin initializes existing members');
select is((select count(*)::integer from public.member_cpc_ratings where member_id=(select member_id from us where role='admin') and points is null),2,'initialization leaves an existing member unrated (NULL) for singles and doubles');
select is((select points from public.member_cpc_ratings where discipline='singles' and member_id=(select member_id from us where role='member') and deleted_at is null),2.750,'initialization preserves assessed points');
select is((select count(*)::integer from public.member_cpc_ratings r join public.members m on m.id=r.member_id where m.status='active' and m.deleted_at is null and r.deleted_at is null),
  (select 2*count(*)::integer from public.members where status='active' and deleted_at is null and org_id=(select org from fx)),'every active member has one rating row');
select is(public.initialize_member_cpc_ratings((select key4 from fx))->>'ok','true','initialization retry replays');
select is((select count(*)::integer from public.member_cpc_rating_history where member_id=(select member_id from us where role='admin')),0,'initialization writes no points history');
select is((select count(*)::integer from public.member_cpc_ratings r join public.members m on m.id=r.member_id where m.status='active' and r.deleted_at is null),
  (select 2*count(*)::integer from public.members where status='active' and deleted_at is null and org_id=(select org from fx)),'initialization retry creates no duplicates');

select public.create_event((select event_id from fx),'Rating Snapshot Test',current_date+30,current_date+30,'Test Court',0,null,null);
select public.set_event_guest_policy((select event_id from fx),true,core.ulid());
select public.create_division((select division_id from fx),(select event_id from fx),'Guest Snapshot',(select category_id from fx),'singles',null,null,null,null,null,(select template_id from fx),null);
select public.set_event_status((select event_id from fx),'registration_open',null);
select public.create_guest_event_participant((select guest_participant_id from fx),(select event_id from fx),(select guest_person_id from fx),'Fake Guest',null,null,null,null);
select lives_ok(format('select public.set_event_participant_cpc_rating(%L,''singles'',3.250,0,%L,%L)',(select guest_participant_id from fx),(select key2 from fx),'Fake guest starting point'),'admin assesses guest points');
select is((select points from public.event_participant_cpc_ratings where discipline='singles' and participant_id=(select guest_participant_id from fx)),3.250,'guest points are stored separately from members');
select public.register_guest_for_event((select guest_registration_id from fx),(select division_id from fx),(select guest_participant_id from fx),(select rank_id from fx));
reset role;
select pg_temp.as_user((select u from us where role='member')); set local role authenticated;
select public.register_for_event((select member_registration_id from fx),(select division_id from fx));
reset role;
select pg_temp.as_user((select u from us where role='admin')); set local role authenticated;
select public.set_event_status((select event_id from fx),'registration_closed',null);
select public.run_draw((select id from public.division_stages where division_id=(select division_id from fx) and stage_no=1));
select lives_ok(format('select public.snapshot_division_cpc_ratings(%L)',(select division_id from fx)),'drawn division gets frozen CPC inputs');
select is((select count(*)::integer from public.division_cpc_rating_snapshots where division_id=(select division_id from fx)),2,'member and guest division has two frozen player inputs');
select is((select starting_points from public.division_cpc_rating_snapshots where division_id=(select division_id from fx) and participant_id=(select guest_participant_id from fx)),3.250,'guest snapshot freezes assessed points');
select is((select team_strength from public.division_cpc_rating_snapshots where division_id=(select division_id from fx) and participant_id=(select guest_participant_id from fx)),3.250,'guest snapshot freezes team strength');
select is((select prior_eligible_match_count from public.division_cpc_rating_snapshots where division_id=(select division_id from fx) and participant_id=(select guest_participant_id from fx)),0,'guest snapshot has no member match count');
select is(public.snapshot_division_cpc_ratings((select division_id from fx))->>'replayed','true','rating snapshot retry replays safely');
select throws_ok(format('select public.set_event_participant_cpc_rating(%L,''singles'',3.500,1,%L,%L)',(select guest_participant_id from fx),(select key3 from fx),'Late change'),'22023',null,'guest assessment cannot change after a snapshot');
reset role;

select pg_temp.as_user((select u from us where role='member')); set local role authenticated;
select is((select points from public.member_cpc_ratings where discipline='singles' and member_id=(select member_id from us where role='member')),2.750,'member may read their own points');
select is((select count(*)::integer from public.member_cpc_rating_history where member_id=(select member_id from us where role='member')),2,'member may read their own points history');
select is((select count(*)::integer from public.member_cpc_ratings where member_id=(select member_id from us where role='admin')),0,'member cannot read another member''s points');
select throws_ok(format('select public.initialize_member_cpc_ratings(%L)',core.ulid()),'42501',null,'member cannot initialize CPC points');
select throws_ok(format('select public.snapshot_division_cpc_ratings(%L)',(select division_id from fx)),'42501',null,'member cannot read or create division snapshots');
reset role;
select is(has_column_privilege('authenticated','public.member_cpc_rating_history','points_after','INSERT'),false,'browser cannot write points history');
select throws_ok('update public.member_cpc_rating_history set reason = ''Edited''','42501',null,'points history is append-only');
select is((select count(*)::integer from core.audit_log where occurred_at >= now() and action in ('cpc_rating.member_assessment','cpc_rating.guest_assessment','cpc_rating.snapshot','cpc_rating.initialize')),5,'assessments, initialization and snapshot are audited');
select * from finish();
rollback;
