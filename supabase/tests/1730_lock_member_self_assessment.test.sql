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

insert into public.member_ranks(org_id,member_id,rank_id) select org,(select mid from us where role='member'),low from fx;
select pg_temp.as_user((select u from us where role='member')); set local role authenticated;
select is(public.get_member_self_assessment()->>'rank_id',(select low from fx),'existing club rank loads automatically');
select is(public.get_member_self_assessment()->>'origin','club_rank','club fallback is identified separately');
select is(public.get_member_self_assessment()->>'source','club','existing official rank is shown as club assigned');
select is(public.get_member_self_assessment()->>'can_edit','false','club-assigned member is read-only');
select is(public.get_member_self_assessment()->>'locked','true','club-assigned assessment is locked');
select is(public.get_member_self_assessment()->>'version','0','loading the club rank does not write an assessment');
select throws_ok(format('select public.set_member_self_assessment(%L,%L,0,%L,null)',(select mid from us where role='member'),(select high from fx),core.ulid()),'42501',null,'member cannot replace an existing club rank assessment');
reset role;
select is((select self_assessed_rank_id from public.members where id=(select mid from us where role='member')),null,'club fallback does not backfill the stored estimate');
select pg_temp.as_user((select u from us where role='admin')); set local role authenticated;
select lives_ok(format('select public.set_member_self_assessment(%L,%L,0,%L,%L)',(select mid from us where role='member'),(select high from fx),core.ulid(),'Fake admin assessment'),'admin can assess a club-assigned member');
reset role;
select pg_temp.as_user((select u from us where role='member')); set local role authenticated;
select is(public.get_member_self_assessment()->>'rank_id',(select high from fx),'admin assessment loads directly');
select is(public.get_member_self_assessment()->>'source','admin','admin provenance loads directly');
select is(public.get_member_self_assessment()->>'can_edit','false','admin assessment stays read-only for the member');
select throws_ok(format('select public.set_member_self_assessment(%L,%L,1,%L,null)',(select mid from us where role='member'),(select low from fx),core.ulid()),'42501',null,'direct member RPC cannot bypass the lock');
reset role;
select pg_temp.as_user((select u from us where role='front_desk')); set local role authenticated;
select is(public.get_member_self_assessment()->>'can_edit','true','unranked unassessed account can submit once');
select throws_ok(format('select public.set_member_self_assessment(%L,null,0,%L,null)',(select mid from us where role='front_desk'),core.ulid()),'22023',null,'empty member submission is rejected');
select is(public.get_member_self_assessment()->>'version','0','empty submission does not lock the member');
select lives_ok(format('select public.set_member_self_assessment(%L,%L,0,%L,null)',(select mid from us where role='front_desk'),(select low from fx),(select key1 from fx)),'fresh member submits once');
select is(public.get_member_self_assessment()->>'can_edit','false','successful submission becomes read-only');
select lives_ok(format('select public.set_member_self_assessment(%L,%L,0,%L,null)',(select mid from us where role='front_desk'),(select low from fx),(select key1 from fx)),'lost-response retry succeeds after the lock');
select is(public.get_member_self_assessment()->>'version','1','locked retry does not write twice');
select throws_ok(format('select public.set_member_self_assessment(%L,%L,1,%L,null)',(select mid from us where role='front_desk'),(select high from fx),core.ulid()),'42501',null,'second submission is blocked');
select throws_ok(format('select public.set_member_self_assessment(%L,null,1,%L,null)',(select mid from us where role='front_desk'),core.ulid()),'42501',null,'member cannot clear a saved assessment');
reset role;
select pg_temp.as_user((select u from us where role='admin')); set local role authenticated;
select lives_ok(format('select public.set_member_self_assessment(%L,null,1,%L,%L)',(select mid from us where role='front_desk'),core.ulid(),'Fake admin reset'),'admin can clear a locked assessment');
reset role;
select pg_temp.as_user((select u from us where role='front_desk')); set local role authenticated;
select is(public.get_member_self_assessment()->>'rank_id',null,'admin clear stays empty');
select is(public.get_member_self_assessment()->>'can_edit','false','admin clear does not unlock self submission');
select throws_ok(format('select public.set_member_self_assessment(%L,%L,2,%L,null)',(select mid from us where role='front_desk'),(select high from fx),core.ulid()),'42501',null,'cleared assessment still requires an admin update');
reset role;
select is((select rank_id from public.member_ranks where member_id=(select mid from us where role='member') and deleted_at is null),(select low from fx),'assessment corrections do not alter official CPC rank');
select is((select count(*)::integer from public.rank_history),(select history from baseline),'lock and assessment changes do not write official rank history');
select * from finish();
rollback;
