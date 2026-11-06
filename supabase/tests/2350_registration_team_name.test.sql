begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as ev, core.ulid() as dv, core.ulid() as sv, core.ulid() as reg1, core.ulid() as reg2, core.ulid() as reg3,
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
insert into us select r, pg_temp.mk(case when r = 'admin' then 'admin' else 'member' end, 'CPC-2350-9900' || n), null
from (values ('admin', 1), ('a', 2), ('b', 3), ('c', 4), ('d', 5), ('e', 6)) v(r, n);
update us set mid = (select m.id from public.members m join public.profiles p on p.id = m.profile_id where p.auth_user_id = us.u);

select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.create_event((select ev from fx), 'Team Name Test', (select day1 from fx), (select day1 from fx), 'Hall', 0, null, null);
select public.create_division((select dv from fx), (select ev from fx), 'Novice Doubles', (select cat_novice from fx), 'doubles', null, null, null, null, null, (select tpl from fx), null);
select public.create_division((select sv from fx), (select ev from fx), 'Novice Singles', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.set_event_status((select ev from fx), 'registration_open', null);
reset role;
update public.settings set value = 'false'::jsonb where key = 'events.registration_approval_required' and unit_id is null and deleted_at is null;

select pg_temp.as_user((select u from us where role = 'a')); set local role authenticated;
select throws_ok(format('select public.register_for_event_team(%L, %L, %L, %L)', (select reg1 from fx), (select dv from fx), '   ', (select mid from us where role = 'b')),
  '22023', 'enter a team name', 'a doubles registration needs a team name');
select throws_ok(format('select public.register_for_event_team(%L, %L, %L, %L)', (select reg1 from fx), (select dv from fx), 'X', (select mid from us where role = 'b')),
  '22023', 'the team name must be 2 to 40 characters', 'a team name is at least 2 characters');
select is((select count(*)::int from public.registrations where id = (select reg1 from fx)), 0, 'a refused name leaves no registration behind');
select lives_ok(format('select public.register_for_event_team(%L, %L, %L, %L)', (select reg1 from fx), (select dv from fx), '  The   Smashers ', (select mid from us where role = 'b')),
  'a member registers with a team name');
select is((select meta ->> 'team_name' from public.registrations where id = (select reg1 from fx)), 'THE SMASHERS', 'the name is trimmed, capitalised and stored on the registration');
select lives_ok(format('select public.register_for_event_team(%L, %L, %L, %L)', (select reg1 from fx), (select dv from fx), 'The Smashers', (select mid from us where role = 'b')),
  'a retry with the same ID replays without an error');
reset role;

select pg_temp.as_user((select u from us where role = 'c')); set local role authenticated;
select throws_ok(format('select public.register_for_event_team(%L, %L, %L, %L)', (select reg2 from fx), (select dv from fx), 'the smashers', (select mid from us where role = 'd')),
  '23505', 'that team name is already used in this event', 'a team name is unique in the event, ignoring case');
select lives_ok(format('select public.register_for_event_team(%L, %L, %L)', (select reg3 from fx), (select sv from fx), 'Ignored'),
  'singles take no team name and register normally');
select is((select meta ->> 'team_name' from public.registrations where id = (select reg3 from fx)), null, 'a singles registration stores no team name');
reset role;

select is(core.team_name_clean('  a   b  '), 'A B', 'spaces are trimmed and collapsed, letters capitalised');
select is(has_function_privilege('anon', 'public.register_for_event_team(text,text,text,text,text,text)', 'execute'), false, 'the public cannot register');
select is(has_function_privilege('authenticated', 'core.apply_team_name(text,text,text)', 'execute'), false, 'the helper is not callable directly');

select * from finish();
rollback;
