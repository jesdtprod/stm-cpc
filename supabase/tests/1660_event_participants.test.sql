begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();
create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create function pg_temp.mk(p_role text, p_no text) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); mid text := core.ulid(); org text := (select id from public.orgs where code = 'cpc');
begin
  insert into auth.users(id, email) values (u, lower(p_no) || '@members.example.test');
  insert into public.persons(id, org_id, display_name) values (per, org, 'Fake ' || p_no);
  insert into public.profiles(id, org_id, auth_user_id, person_id) values (pid, org, u, per);
  insert into public.org_members(org_id, profile_id, role_id) values (org, pid, (select id from public.roles where org_id = org and code = p_role));
  insert into public.members(id, org_id, person_id, profile_id, member_no) values (mid, org, per, pid, p_no);
  update public.members set status = 'invited' where id = mid;
  update public.members set status = 'pending_approval' where id = mid;
  update public.members set status = 'active' where id = mid;
  return u;
end $$;
create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as e1, core.ulid() as e2, core.ulid() as gp,
  core.ulid() as p1, core.ulid() as p2, core.ulid() as p3,
  core.ulid() as foreign_org, core.ulid() as foreign_person;
create temp table us(role text, u uuid);
insert into us values ('admin', pg_temp.mk('admin', 'CPC-2026-96600'));
insert into us values ('member', pg_temp.mk('member', 'CPC-2026-96601'));
grant select on fx, us to public;
create temp table mids as select m.id, p.person_id from public.members m
  join public.profiles p on p.id = m.profile_id where p.auth_user_id = (select u from us where role = 'member');
grant select on mids to public;
select is(has_function_privilege('anon', 'public.create_event_participant(text,text,text,text,text,text,text,date)', 'execute'), false, 'anonymous callers cannot add participants');
select is(has_table_privilege('authenticated', 'public.event_participants', 'INSERT'), false, 'direct inserts are denied');
select is(has_table_privilege('authenticated', 'public.event_participants', 'UPDATE'), false, 'direct updates are denied');
select is(has_table_privilege('authenticated', 'public.event_participants', 'DELETE'), false, 'direct deletes are denied');
select ok((select relrowsecurity from pg_class where oid = 'public.event_participants'::regclass), 'participant registry has RLS');
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.create_event((select e1 from fx), 'Fake Guest Event', '2030-11-01', '2030-11-02', null, 0, null, null);
select public.create_event((select e2 from fx), 'Fake Second Guest Event', '2030-11-01', '2030-11-02', null, 0, null, null);
select lives_ok(format($f$select public.create_event_participant(%L,%L,null,%L,'Fake Guest','09000000000','female','2000-01-01')$f$, (select p1 from fx), (select e1 from fx), (select gp from fx)), 'admin creates a guest participant without membership');
select is((select public.create_event_participant((select p1 from fx),(select e1 from fx),null,(select gp from fx),'Fake Guest','09000000000','female','2000-01-01')->>'replayed'), 'true', 'same guest creation replays safely');
select is((select count(*)::integer from public.event_participants where event_id = (select e1 from fx)), 1, 'retry does not add another participant');
select throws_ok(format($f$select public.create_event_participant(%L,%L,null,%L,'Changed Guest','09000000000','female','2000-01-01')$f$, (select p1 from fx), (select e1 from fx), (select gp from fx)), 'CP422', null, 'reused participant ID with changed payload is refused');
select throws_ok(format($f$select public.create_event_participant(%L,%L,null,%L)$f$, core.ulid(), (select e1 from fx), (select gp from fx)), '22023', null, 'same person cannot have duplicate participant identities in one event');
select lives_ok(format($f$select public.create_event_participant(%L,%L,null,%L)$f$, (select p2 from fx), (select e2 from fx), (select gp from fx)), 'same guest identity is reusable in another event');
select lives_ok(format($f$select public.create_event_participant(%L,%L,%L)$f$, (select p3 from fx), (select e1 from fx), (select id from mids)), 'active member uses their existing person');
select throws_ok(format($f$select public.create_event_participant(%L,%L,%L,%L)$f$, core.ulid(), (select e1 from fx), (select id from mids), (select gp from fx)), '22023', null, 'member and guest cannot both be supplied');
select throws_ok(format($f$select public.create_event_participant(%L,%L,%L,null,'Forged Name')$f$, core.ulid(), (select e1 from fx), (select id from mids)), '22023', null, 'member names cannot be replaced with client input');
select throws_ok(format($f$select public.create_event_participant(%L,%L,null,%L)$f$, core.ulid(), (select e2 from fx), (select person_id from mids)), '22023', null, 'member cannot masquerade as a guest');
select throws_ok(format($f$select public.create_event_participant(%L,%L,null,%L,'Changed Guest')$f$, core.ulid(), (select e2 from fx), (select gp from fx)), 'CP422', null, 'adding participants cannot silently edit a guest profile');
select throws_ok(format($f$select public.create_event_participant(%L,%L,null,%L,'Fake Future Guest',null,'female','2999-01-01')$f$, core.ulid(), (select e1 from fx), core.ulid()), '22023', null, 'future birth dates are refused');
select throws_ok(format($f$select public.create_event_participant(%L,%L,null,%L,'Fake Guest',null,'invalid')$f$, core.ulid(), (select e1 from fx), core.ulid()), '22023', null, 'invalid guest gender is refused');
select throws_ok(format($f$select public.create_event_participant('bad',%L,null,%L,'Fake Guest')$f$, (select e1 from fx), core.ulid()), '22023', null, 'invalid participant IDs are refused');
select throws_ok(format($f$select public.create_event_participant(%L,%L,null,'bad','Fake Guest')$f$, core.ulid(), (select e1 from fx)), '22023', null, 'invalid guest IDs are refused');
select throws_ok(format($f$select public.create_event_participant(%L,%L)$f$, core.ulid(), (select e1 from fx)), '22023', null, 'a participant must identify a member or guest');
select throws_ok(format($f$select public.create_event_participant(%L,%L,null,%L)$f$, core.ulid(), (select e1 from fx), core.ulid()), '22023', null, 'new guests need a name');
reset role;
select is((select kind from public.persons where id = (select gp from fx)), 'guest', 'guest has the existing guest person classification');
select is((select count(*)::integer from public.members where person_id = (select gp from fx)), 0, 'no membership is created for the guest');
select is((select count(*)::integer from public.profiles where person_id = (select gp from fx)), 0, 'no login profile is created for the guest');
select is((select person_id from public.event_participants where id = (select p3 from fx)), (select person_id from mids), 'member identity is taken from the server');
select ok(exists(select 1 from core.audit_log where table_name = 'public.event_participants' and record_id = (select p1 from fx)), 'participant creation is audited');
select throws_ok(format($f$update public.event_participants set event_id = %L where id = %L$f$, (select e2 from fx), (select p1 from fx)), '22023', null, 'participant identity cannot be reassigned');
update public.members set status = 'suspended', status_reason = 'Fake participant test' where id = (select id from mids);
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select throws_ok(format($f$select public.create_event_participant(%L,%L,%L)$f$, core.ulid(), (select e2 from fx), (select id from mids)), '22023', null, 'suspended members cannot be added as participants');
select public.set_event_status((select e2 from fx), 'cancelled', 'Fake registry cancellation test');
select throws_ok(format($f$select public.create_event_participant(%L,%L,null,%L,'Fake Late Guest')$f$, core.ulid(), (select e2 from fx), core.ulid()), '22023', null, 'cancelled event refuses new participants');
select is((select public.create_event_participant((select p2 from fx),(select e2 from fx),null,(select gp from fx))->>'replayed'), 'true', 'an existing operation can replay after event cancellation');
reset role;
update public.members set status = 'active', status_reason = 'Fake participant test reset' where id = (select id from mids);
insert into public.orgs(id, org_id, code, name) select foreign_org, foreign_org, 'fake_guest_org', 'Fake Guest Organization' from fx;
insert into public.persons(id, org_id, kind, display_name) select foreign_person, foreign_org, 'guest', 'Fake Foreign Guest' from fx;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select throws_ok(format($f$select public.create_event_participant(%L,%L,null,%L)$f$, core.ulid(), (select e1 from fx), (select foreign_person from fx)), '22023', null, 'foreign guest identities are refused');
reset role;
select pg_temp.as_user((select u from us where role = 'member')); set local role authenticated;
select is((select count(*)::integer from public.event_participants where event_id = (select e1 from fx)), 0, 'members cannot read the staff participant registry');
select throws_ok(format($f$select public.create_event_participant(%L,%L,null,%L,'Fake Unauthorized Guest')$f$, core.ulid(), (select e1 from fx), core.ulid()), '42501', null, 'ordinary members cannot create guest participants');
reset role;
-- No guest path into entries was opened by this foundation migration.
select is((select count(*)::integer from public.registrations where event_id = (select e1 from fx)), 0, 'participant setup does not create registrations or fees');
select * from finish();
rollback;
