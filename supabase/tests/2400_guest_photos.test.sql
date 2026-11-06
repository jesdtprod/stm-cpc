begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();
create temp table fx as select (select id from public.orgs where code='cpc') as org,
  core.ulid() as ev, core.ulid() as guest, core.ulid() as gp, core.ulid() as obj;
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
create temp table us(role text,u uuid);
grant select on us to public;
insert into us values('admin',pg_temp.mk('admin','CPC-2400-99101')),('member',pg_temp.mk('member','CPC-2400-99102'));
create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims',json_build_object('sub',u,'role','authenticated')::text,true) $$;

select pg_temp.as_user((select u from us where role='admin')); set local role authenticated;
select public.create_event((select ev from fx),'Fake Guest Photos',current_date+70,current_date+70,'Fake Hall',0,null,null);
select public.set_event_guest_policy((select ev from fx),true,core.ulid());
select public.create_guest_event_participant((select guest from fx),(select ev from fx),(select gp from fx),'Fake Photo Guest',null,null,null,null,2.800,2.800);
create temp table path as select public.guest_photo_path((select guest from fx)) as p;
grant select on path to public;
select matches((select p from path), '^[A-Za-z0-9]+/g[A-Za-z0-9]+/[A-Za-z0-9]+\.jpg$', 'the upload path is <org>/g<guest person>/<file>.jpg');
select is(split_part((select p from path), '/', 2), 'g' || (select gp from fx), 'the folder belongs to the guest person');
reset role;

select pg_temp.as_user((select u from us where role='member')); set local role authenticated;
select throws_ok(format('select public.guest_photo_path(%L)', (select guest from fx)), '42501', null, 'a member cannot ask for a guest upload path');
select throws_ok(format('select public.set_event_guest_avatar(%L, null)', (select guest from fx)), '42501', null, 'a member cannot change a guest photo');
select throws_ok(format('select * from public.guest_photos(%L)', (select ev from fx)), '42501', null, 'a member cannot list guest photos');
reset role;

select pg_temp.as_user((select u from us where role='admin')); set local role authenticated;
select throws_ok(format('select public.set_event_guest_avatar(%L, %L)', (select guest from fx), (select p from path)),
  '22023', 'the photo was not found; upload it again', 'a path with no uploaded file is refused');
select throws_ok(format('select public.set_event_guest_avatar(%L, %L)', (select guest from fx), (select org from fx) || '/gOTHER/x.jpg'),
  '42501', null, 'a path in another folder is refused');
reset role;
insert into storage.objects (bucket_id, name, owner) values ('avatars', (select p from path), null);
select pg_temp.as_user((select u from us where role='admin')); set local role authenticated;
select lives_ok(format('select public.set_event_guest_avatar(%L, %L)', (select guest from fx), (select p from path)), 'staff saves the guest photo');
select is((select count(*)::int from public.guest_photos((select ev from fx)) where participant_id = (select guest from fx) and avatar_path = (select p from path)), 1,
  'the photo is listed for the event');
select lives_ok(format('select public.set_event_guest_avatar(%L, null)', (select guest from fx)), 'the photo can be removed');
select is((select count(*)::int from public.guest_photos((select ev from fx))), 0, 'a removed photo is no longer listed');
reset role;
select is(has_function_privilege('anon', 'public.guest_photos(text)', 'execute'), false, 'the public cannot list guest photos');

select * from finish();
rollback;
