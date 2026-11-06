begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as ev, core.ulid() as dv, core.ulid() as reg1, core.ulid() as reg2,
  (select id from public.categories where code = 'novice' and deleted_at is null) as cat_novice,
  (select r.id from public.ranks r join public.rank_ladders l on l.id = r.ladder_id join public.categories c on c.id = l.category_id
    where c.code = 'novice' and r.deleted_at is null order by r.sort_order desc limit 1) as novice_top,
  (select id from public.format_templates where stages -> 0 ->> 'stage_type' = 'round_robin' and jsonb_array_length(stages) = 1 and deleted_at is null order by id limit 1) as tpl,
  current_date + 120 as day1;
grant select on fx to public;
create function pg_temp.mk(p_role text, p_no text) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); mid text := core.ulid(); org text := (select org from fx);
begin
  insert into auth.users (id, email) values (u, lower(p_no) || '@members.example.test');
  insert into public.persons (id, org_id, display_name) values (per, org, 'Fake ' || p_no);
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (org, pid, (select id from public.roles where org_id = org and code = p_role));
  insert into public.members (id, org_id, person_id, profile_id, member_no) values (mid, org, per, pid, p_no);
  update public.members set status = 'invited' where id = mid;
  update public.members set status = 'pending_approval' where id = mid;
  update public.members set status = 'active' where id = mid;
  insert into public.member_ranks (org_id, member_id, rank_id) values (org, mid, (select novice_top from fx));
  return u;
end $$;
create temp table us(role text primary key, u uuid, mid text);
grant select on us to public;
insert into us select r, pg_temp.mk(case when r = 'admin' then 'admin' else 'member' end, 'CPC-2440-9900' || n), null
from (values ('admin', 1), ('a', 2), ('b', 3), ('c', 4), ('d', 5)) v(r, n);
update us set mid = (select m.id from public.members m join public.profiles p on p.id = m.profile_id where p.auth_user_id = us.u);

select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.create_event((select ev from fx), 'Roster Test', (select day1 from fx), (select day1 from fx), 'Hall', 0, null, null);
select public.create_division((select dv from fx), (select ev from fx), 'Novice Doubles', (select cat_novice from fx), 'doubles', null, null, null, null, null, (select tpl from fx), null);
reset role;
set local role anon;
select is((select count(*)::int from public.public_event_rosters() where event_name = 'Roster Test'), 0, 'a draft event has no public roster');
reset role;

select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.set_event_status((select ev from fx), 'registration_open', null);
reset role;
update public.settings set value = 'false'::jsonb where key = 'events.registration_approval_required' and unit_id is null and deleted_at is null;
select pg_temp.as_user((select u from us where role = 'a')); set local role authenticated;
select public.register_for_event_team((select reg1 from fx), (select dv from fx), 'The Smashers', (select mid from us where role = 'b'));
reset role;
update public.settings set value = 'true'::jsonb where key = 'events.registration_approval_required' and unit_id is null and deleted_at is null;
select pg_temp.as_user((select u from us where role = 'c')); set local role authenticated;
select public.register_for_event_team((select reg2 from fx), (select dv from fx), 'Waiting Team', (select mid from us where role = 'd'));
reset role;

set local role anon;
select is((select count(*)::int from public.public_event_rosters() where event_name = 'Roster Test'), 1, 'visitors see only the approved team');
select is((select team_name from public.public_event_rosters() where event_name = 'Roster Test'), 'THE SMASHERS', 'the team name is shown');
select is((select p1_name from public.public_event_rosters() where event_name = 'Roster Test'), 'Fake CPC-2440-99002', 'player 1 is the registrant');
select is((select p2_name from public.public_event_rosters() where event_name = 'Roster Test'), 'Fake CPC-2440-99003', 'player 2 is the partner');
select is((select count(*)::int from public.public_event_rosters() where event_name = 'Roster Test' and team_name = 'WAITING TEAM'), 0, 'a pending team is not listed');
reset role;

select is((select status from public.registrations where id = (select reg2 from fx)), 'requested', 'the second registration is waiting for approval');
select is(has_function_privilege('anon', 'public.public_event_rosters()', 'execute'), true, 'visitors may call the roster');
select ok(not exists (select 1 from jsonb_array_elements(public.public_landing_info() -> 'events') e where e ? 'id'), 'the public events list still carries no ids');

-- photos: a rostered player's photo is readable by visitors
update public.persons set avatar_path = (select org from fx) || '/fakeroster/a.jpg' where id = (select person_id from public.members where id = (select mid from us where role = 'a'));
update public.persons set avatar_path = (select org from fx) || '/fakeroster/c.jpg' where id = (select person_id from public.members where id = (select mid from us where role = 'c'));
insert into storage.objects (bucket_id, name) values ('avatars', (select org from fx) || '/fakeroster/a.jpg'), ('avatars', (select org from fx) || '/fakeroster/c.jpg');
set local role anon;
select is((select count(*)::int from storage.objects where bucket_id = 'avatars' and name = (select org from fx) || '/fakeroster/a.jpg'), 1, 'a visitor can read the photo of a player on an official roster');
reset role;

select is((select drawn from public.public_event_rosters() where event_name = 'Roster Test' limit 1), false, 'a division that is not drawn is not offered as a bracket');
select is((select finished from public.public_event_rosters() where event_name = 'Roster Test' limit 1), false, 'a division that has not been played is not finished');
select * from finish();
rollback;
