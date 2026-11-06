begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as ev, core.ulid() as d1, core.ulid() as d2,
  core.ulid() as ra1, core.ulid() as ra2, core.ulid() as rb1, core.ulid() as rb2, core.ulid() as rb3,
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
create temp table us(role text primary key, u uuid);
grant select on us to public;
insert into us select r, pg_temp.mk(case when r = 'admin' then 'admin' else 'member' end, 'CPC-2520-9900' || n)
from (values ('admin', 1), ('a', 2), ('b', 3)) v(r, n);

select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.create_event((select ev from fx), 'Multi Test', (select day1 from fx), (select day1 from fx), 'Hall', 0, null, null);
select public.create_division((select d1 from fx), (select ev from fx), 'One', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.create_division((select d2 from fx), (select ev from fx), 'Two', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.set_event_status((select ev from fx), 'registration_open', null);
reset role;
update public.settings set value = 'false'::jsonb where key = 'events.registration_approval_required' and unit_id is null and deleted_at is null;

select is((select value from public.settings where key = 'events.allow_multiple_divisions' and unit_id is null and deleted_at is null and org_id = (select org from fx)), 'true'::jsonb, 'joining several divisions is allowed by default');
select is(core.setting_valid('events.allow_multiple_divisions', 'true'::jsonb), true, 'the setting takes true or false');
select is(core.setting_valid('events.allow_multiple_divisions', '"yes"'::jsonb), false, 'the setting does not take text');

-- ON: member a joins both divisions, but not the same one twice
select pg_temp.as_user((select u from us where role = 'a')); set local role authenticated;
select lives_ok(format('select public.register_for_event(%L, %L)', (select ra1 from fx), (select d1 from fx)), 'with the setting on, a member joins a first division');
select lives_ok(format('select public.register_for_event(%L, %L)', (select ra2 from fx), (select d2 from fx)), 'and a second division of the same event');
reset role;

-- OFF: member b may join one division only
update public.settings set value = 'false'::jsonb where key = 'events.allow_multiple_divisions' and unit_id is null and deleted_at is null and org_id = (select org from fx);
select pg_temp.as_user((select u from us where role = 'b')); set local role authenticated;
select lives_ok(format('select public.register_for_event(%L, %L)', (select rb1 from fx), (select d1 from fx)), 'with the setting off, a member joins one division');
select throws_ok(format('select public.register_for_event(%L, %L)', (select rb2 from fx), (select d2 from fx)), '22023', null, 'but not a second division of the same event');
reset role;
select is(core.registration_problem((select m.id from public.members m join public.profiles p on p.id = m.profile_id where p.auth_user_id = (select u from us where role = 'b')), (select d2 from fx), true) like '%turned off in Settings%', true,
  'the reason names the setting');

-- turning it back on lets the same member join
update public.settings set value = 'true'::jsonb where key = 'events.allow_multiple_divisions' and unit_id is null and deleted_at is null and org_id = (select org from fx);
select pg_temp.as_user((select u from us where role = 'b')); set local role authenticated;
select lives_ok(format('select public.register_for_event(%L, %L)', (select rb3 from fx), (select d2 from fx)), 'switching it back on allows the second division');
reset role;

select * from finish();
rollback;
