begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();
create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create function pg_temp.mk(p_role text, p_no text) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); mid text := core.ulid();
  org text := (select id from public.orgs where code = 'cpc');
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
insert into us(role,u) values ('admin',pg_temp.mk('admin','CPC-2030-97200')),
  ('member',pg_temp.mk('member','CPC-2030-97201')),('front_desk',pg_temp.mk('front_desk','CPC-2030-97202'));
update us set mid=(select m.id from public.members m join public.profiles p on p.id=m.profile_id where p.auth_user_id=us.u);
create temp table fx as select (select id from public.orgs where code='cpc') as org,
  core.ulid() as cat, core.ulid() as ladder, core.ulid() as low, core.ulid() as high,
  core.ulid() as other_org, core.ulid() as other_person, core.ulid() as other_member,
  core.ulid() as other_cat, core.ulid() as other_ladder, core.ulid() as other_rank,
  core.ulid() as key1, core.ulid() as key2;
grant select on us,fx to public;
insert into public.categories(id,org_id,code,name) select cat,org,'fake_assessment_'||lower(left(cat,8)),'Fake Assessment' from fx;
insert into public.rank_ladders(id,org_id,category_id) select ladder,org,cat from fx;
insert into public.ranks(id,org_id,ladder_id,code,name,sort_order)
  select low,org,ladder,'low','Fake Low',0 from fx union all select high,org,ladder,'high','Fake High',1 from fx;
create temp table baseline as select count(*)::integer as history from public.rank_history;
grant select on baseline to public;
insert into public.orgs(id,code,name) select other_org,'fake-'||lower(left(other_org,12)),'Fake Other Club' from fx;
insert into public.persons(id,org_id,display_name) select other_person,other_org,'Fake Other Member' from fx;
insert into public.members(id,org_id,person_id,member_no) select other_member,other_org,other_person,'FAKE-OTHER' from fx;
insert into public.categories(id,org_id,code,name) select other_cat,other_org,'fake_other_assessment','Fake Other Category' from fx;
insert into public.rank_ladders(id,org_id,category_id) select other_ladder,other_org,other_cat from fx;
insert into public.ranks(id,org_id,ladder_id,code,name,sort_order) select other_rank,other_org,other_ladder,'fake_other','Fake Other Rank',0 from fx;

select is(has_function_privilege('anon','public.get_member_self_assessment(text)','execute'),false,'anonymous users cannot read assessments');
select is(has_function_privilege('anon','public.set_member_self_assessment(text,text,integer,text,text)','execute'),false,'anonymous users cannot set assessments');
select is(has_column_privilege('authenticated','public.members','self_assessed_rank_id','UPDATE'),false,'direct client writes are forbidden');
select ok((select relrowsecurity from pg_class where oid='public.members'::regclass),'existing members RLS remains enabled');

select pg_temp.as_user((select u from us where role='member')); set local role authenticated;
select is(public.get_member_self_assessment()->>'version','0','missing assessment starts at version zero');
select is(public.get_member_self_assessment()->>'rank_id',null,'no assessment is assigned automatically');
select is(public.get_member_self_assessment()->>'official_rank',null,'unranked member can submit an assessment');
select is(public.get_member_self_assessment()->>'can_edit','true','member can edit own estimate');
select ok(exists(select 1 from jsonb_array_elements(public.get_member_self_assessment()->'options') x where x->>'value'=(select high from fx)),'active rank choices are supplied');
select throws_ok(format('select public.get_member_self_assessment(%L)',(select mid from us where role='admin')),'42501',null,'member cannot read another assessment');
select throws_ok(format('select public.set_member_self_assessment(%L,%L,0,%L,null)',(select mid from us where role='admin'),(select high from fx),core.ulid()),'42501',null,'member cannot change another assessment');
select lives_ok(format('select public.set_member_self_assessment(%L,%L,0,%L,null)',(select mid from us where role='member'),(select high from fx),(select key1 from fx)),'member saves an estimate');
select is(public.get_member_self_assessment()->>'rank_id',(select high from fx),'saved estimate reloads');
select is(public.get_member_self_assessment()->>'source','member','member source is recorded');
select lives_ok(format('select public.set_member_self_assessment(%L,%L,0,%L,null)',(select mid from us where role='member'),(select high from fx),(select key1 from fx)),'lost-response retry replays successfully');
select is(public.get_member_self_assessment()->>'version','1','retry does not increment version');
select throws_ok(format('select public.set_member_self_assessment(%L,%L,1,%L,null)',(select mid from us where role='member'),(select low from fx),(select key1 from fx)),'CP422',null,'same key with different values is rejected');
select throws_ok(format('select public.set_member_self_assessment(%L,%L,0,%L,null)',(select mid from us where role='member'),(select low from fx),core.ulid()),'CP409',null,'stale version cannot overwrite a newer estimate');
select throws_ok(format('select public.set_member_self_assessment(%L,%L,1,%L,null)',(select mid from us where role='member'),core.ulid(),core.ulid()),'42501',null,'saved assessment is locked even for an unknown rank');
select throws_ok(format('select public.set_member_self_assessment(%L,%L,1,%L,null)',(select mid from us where role='member'),(select other_rank from fx),core.ulid()),'42501',null,'saved assessment cannot be replaced with another club rank');
reset role;
select is((select count(*)::integer from core.audit_log where action='member.self_assessment' and record_id=(select mid from us where role='member')),1,'one audit entry for the retried member save');
insert into public.member_ranks(org_id,member_id,rank_id) select org,(select mid from us where role='member'),low from fx;

select pg_temp.as_user((select u from us where role='front_desk')); set local role authenticated;
select is(public.get_member_self_assessment((select mid from us where role='member'))->>'can_edit','false','read-only staff can view but not edit');
select throws_ok(format('select public.set_member_self_assessment(%L,%L,1,%L,%L)',(select mid from us where role='member'),(select low from fx),core.ulid(),'Fake reason'),'42501',null,'members.read does not grant correction rights');
reset role;
select pg_temp.as_user((select u from us where role='admin')); set local role authenticated;
select is(public.get_member_self_assessment((select mid from us where role='member'))->>'can_edit','true','rank-override admin can edit the estimate');
select throws_ok(format('select public.set_member_self_assessment(%L,%L,1,%L,%L)',(select mid from us where role='member'),core.ulid(),core.ulid(),'Fake correction'),'22023',null,'admin cannot select an unknown rank');
select throws_ok(format('select public.set_member_self_assessment(%L,%L,1,%L,%L)',(select mid from us where role='member'),(select other_rank from fx),core.ulid(),'Fake correction'),'22023',null,'admin cannot select another club rank');
select throws_ok(format('select public.set_member_self_assessment(%L,%L,1,%L,null)',(select mid from us where role='member'),(select low from fx),core.ulid()),'22023',null,'admin correction needs a reason');
select lives_ok(format('select public.set_member_self_assessment(%L,%L,1,%L,%L)',(select mid from us where role='member'),(select low from fx),(select key2 from fx),'Fake assessment correction'),'admin can alter the self-assessment');
select is(public.get_member_self_assessment((select mid from us where role='member'))->>'source','admin','admin source is recorded');
select is(public.get_member_self_assessment((select mid from us where role='member'))->>'reason','Fake assessment correction','correction reason reloads');
select throws_ok(format('select public.get_member_self_assessment(%L)',(select other_member from fx)),'42501',null,'admin cannot read another club assessment');
select throws_ok(format('select public.set_member_self_assessment(%L,null,0,%L,%L)',(select other_member from fx),core.ulid(),'Fake other club'),'42501',null,'admin cannot write another club assessment');
reset role;
select is((select self_assessed_by from public.members where id=(select mid from us where role='member')),
  (select p.id from public.profiles p join us on us.u=p.auth_user_id where us.role='admin'),'server records the correcting profile');
update public.rank_ladders set is_active=false where id=(select ladder from fx);
select pg_temp.as_user((select u from us where role='admin')); set local role authenticated;
select throws_ok(format('select public.set_member_self_assessment(%L,%L,2,%L,%L)',(select mid from us where role='member'),(select high from fx),core.ulid(),'Fake correction'),'22023',null,'inactive ladder ranks cannot be selected');
reset role;
update public.rank_ladders set is_active=true where id=(select ladder from fx);
select pg_temp.as_user((select u from us where role='member')); set local role authenticated;
select throws_ok(format('select public.set_member_self_assessment(%L,%L,2,%L,null)',(select mid from us where role='member'),(select high from fx),core.ulid()),'42501',null,'member cannot resubmit after an admin correction');
select is(public.get_member_self_assessment()->>'source','admin','admin correction remains authoritative');
reset role;
select pg_temp.as_user((select u from us where role='admin')); set local role authenticated;
select lives_ok(format('select public.set_member_self_assessment(%L,null,2,%L,%L)',(select mid from us where role='member'),core.ulid(),'Fake assessment reset'),'admin may clear the assessment');
reset role;
select pg_temp.as_user((select u from us where role='member')); set local role authenticated;
select is(public.get_member_self_assessment()->>'rank_id',null,'clearing does not assign a rank');
reset role;
insert into public.member_access(org_id,member_id,must_change_password) select org,(select mid from us where role='member'),true from fx;
select pg_temp.as_user((select u from us where role='member')); set local role authenticated;
select throws_ok(format('select public.set_member_self_assessment(%L,%L,3,%L,null)',(select mid from us where role='member'),(select high from fx),core.ulid()),'42501',null,'password-change gate blocks self edits');
reset role;
update public.member_access set must_change_password=false where member_id=(select mid from us where role='member');
update public.members set status='suspended' where id=(select mid from us where role='member');
select pg_temp.as_user((select u from us where role='member')); set local role authenticated;
select throws_ok(format('select public.set_member_self_assessment(%L,%L,3,%L,null)',(select mid from us where role='member'),(select high from fx),core.ulid()),'42501',null,'suspended member cannot edit');
reset role;
select is((select rank_id from public.member_ranks where member_id=(select mid from us where role='member') and deleted_at is null),(select low from fx),'member and admin estimates never modify official rank');
select is((select count(*)::integer from public.rank_history),(select history from baseline),'self-assessment never writes official rank history');
select is((select count(*)::integer from core.audit_log where action='member.self_assessment' and record_id=(select mid from us where role='member')),3,'all three changes are audited once');
select * from finish();
rollback;
