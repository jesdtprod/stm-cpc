begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as ev, core.ulid() as dv, core.ulid() as r1, core.ulid() as r2, core.ulid() as k1, core.ulid() as k2, core.ulid() as k3,
  (select id from public.format_templates where stages -> 0 ->> 'stage_type' = 'round_robin' and jsonb_array_length(stages) = 1 and deleted_at is null order by id limit 1) as tpl,
  (select id from public.categories where code = 'novice' and deleted_at is null) as cat_novice,
  current_date + 30 as day1;
grant select on fx to public;
create function pg_temp.mk(p_role text, p_no text) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); mid text := core.ulid(); org text := (select org from fx);
begin
  insert into auth.users (id, email) values (u, lower(p_no) || '@members.example.test');
  insert into public.persons (id, org_id, display_name, gender, date_of_birth) values (per, org, 'Fake ' || p_no, 'male', '1990-01-01');
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (org, pid, (select id from public.roles where org_id = org and code = p_role));
  insert into public.members (id, org_id, person_id, profile_id, member_no) values (mid, org, per, pid, p_no);
  update public.members set status = 'invited' where id = mid;
  update public.members set status = 'pending_approval' where id = mid;
  update public.members set status = 'active' where id = mid;
  insert into public.member_ranks (org_id, member_id, rank_id)
    select org, mid, r.id from public.ranks r join public.rank_ladders l on l.id = r.ladder_id join public.categories c on c.id = l.category_id
    where c.code = 'novice' and r.deleted_at is null order by r.sort_order limit 1;
  return u;
end $$;
create temp table us(role text primary key, u uuid);
grant select on us to public;
insert into us select r, pg_temp.mk(case when r = 'admin' then 'admin' else 'member' end, 'CPC-2470-9900' || n)
from (values ('admin', 1), ('outsider', 2), ('p1', 3), ('p2', 4)) v(r, n);

select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.create_event((select ev from fx), 'Undraw Test', (select day1 from fx), (select day1 from fx), 'Hall', 0, null, null);
select public.create_division((select dv from fx), (select ev from fx), 'Two Players', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.set_event_status((select ev from fx), 'registration_open', null);
reset role;
update public.settings set value = 'false'::jsonb where key = 'events.registration_approval_required' and unit_id is null and deleted_at is null;
select pg_temp.as_user((select u from us where role = 'p1')); set local role authenticated;
select public.register_for_event((select r1 from fx), (select dv from fx)); reset role;
select pg_temp.as_user((select u from us where role = 'p2')); set local role authenticated;
select public.register_for_event((select r2 from fx), (select dv from fx)); reset role;

select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select throws_ok(format('select public.undraw_division(%L, %L, %L)', (select dv from fx), 'Not drawn yet', (select k1 from fx)), '22023', 'this division is not drawn', 'an undrawn division cannot be undrawn');
select public.set_event_status((select ev from fx), 'registration_closed', null);
select public.run_draw((select id from public.division_stages where division_id = (select dv from fx) and stage_no = 1));
reset role;
select is((select status from public.divisions where id = (select dv from fx)), 'drawn', 'the division is drawn');
select is((select status from public.events where id = (select ev from fx)), 'drawn', 'the event is drawn');

select pg_temp.as_user((select u from us where role = 'outsider')); set local role authenticated;
select throws_ok(format('select public.undraw_division(%L, %L, %L)', (select dv from fx), 'Changed my mind', (select k2 from fx)), '42501', null, 'a member cannot undraw');
reset role;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select throws_ok(format('select public.undraw_division(%L, %L, %L)', (select dv from fx), 'x', (select k2 from fx)), '22023', 'a reason of 3 to 500 characters is required', 'a reason is required');
select lives_ok(format('select public.undraw_division(%L, %L, %L)', (select dv from fx), 'Roster must change', (select k2 from fx)), 'staff undraw the division');
select lives_ok(format('select public.undraw_division(%L, %L, %L)', (select dv from fx), 'Roster must change', (select k2 from fx)), 'a retry with the same key replays');
reset role;
select is((select status from public.divisions where id = (select dv from fx)), 'open', 'the division is open again');
select is((select status from public.division_stages where division_id = (select dv from fx) and stage_no = 1), 'pending', 'the stage is pending again');
select is((select status from public.events where id = (select ev from fx)), 'registration_closed', 'the event goes back to registration closed');
select is((select count(*)::int from public.matches m join public.division_stages s on s.id = m.division_stage_id
  where s.division_id = (select dv from fx) and m.status = 'scheduled'), 0, 'no scheduled matches are left');
select is((select count(*)::int from public.draws d join public.division_stages s on s.id = d.division_stage_id
  where s.division_id = (select dv from fx) and d.status = 'active'), 0, 'the old draw is no longer active');
select is((select count(*)::int from public.draws d join public.division_stages s on s.id = d.division_stage_id
  where s.division_id = (select dv from fx) and d.status = 'superseded'), 1, 'the old draw is kept in the history');
select is((select count(*)::int from public.entries where division_id = (select dv from fx) and seed is not null), 0, 'the seeds are cleared');
select is((select count(*)::int from public.entries where division_id = (select dv from fx)), 2, 'the entries are kept');
select ok(exists (select 1 from core.audit_log where action = 'draw.undraw' and record_id = (select dv from fx)), 'the undraw is audited');

-- the guards are back: a plain status change to a forbidden state is still refused
select throws_ok(format($f$update public.divisions set status = 'completed' where id = %L$f$, (select dv from fx)), null, null, 'the state machine guards are restored');

-- it can be drawn again, and a started match blocks the undraw
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select lives_ok(format('select public.run_draw(%L)', (select id from public.division_stages where division_id = (select dv from fx) and stage_no = 1)), 'the division can be drawn again');
reset role;
update public.matches set status = 'in_progress' where id = (select m.id from public.matches m join public.division_stages s on s.id = m.division_stage_id where s.division_id = (select dv from fx) and m.status = 'scheduled' limit 1);
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select throws_ok(format('select public.undraw_division(%L, %L, %L)', (select dv from fx), 'Too late', (select k3 from fx)), '22023', 'this division is not drawn', 'once a match has started the division is no longer drawn, so the undraw is refused');
reset role;
select is(has_function_privilege('anon', 'public.undraw_division(text,text,text)', 'execute'), false, 'the public cannot undraw');

select * from finish();
rollback;
