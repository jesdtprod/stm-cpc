begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as ev, core.ulid() as dv1, core.ulid() as dv2, core.ulid() as dv3,
  core.ulid() as g1, core.ulid() as g2, core.ulid() as g3, core.ulid() as g4, core.ulid() as g5, core.ulid() as g6,
  core.ulid() as h1, core.ulid() as h2, core.ulid() as h3,
  core.ulid() as k1, core.ulid() as k2, core.ulid() as k3, core.ulid() as k4,
  core.ulid() as m1, core.ulid() as m2,
  (select id from public.format_templates where stages -> 0 ->> 'stage_type' = 'pool_play' and deleted_at is null order by id limit 1) as tpl_reg,
  (select id from public.format_templates where stages -> 0 ->> 'stage_type' = 'round_robin' and jsonb_array_length(stages) = 1 and deleted_at is null order by id limit 1) as tpl_rr,
  (select id from public.categories where code = 'novice' and deleted_at is null) as cat_novice,
  current_date + 30 as day1;
grant select on fx to public;

create function pg_temp.mk(p_role text, p_no text, p_ranked boolean) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); mid text := core.ulid(); org text := (select id from public.orgs where code = 'cpc');
begin
  insert into auth.users (id, email) values (u, lower(p_no) || '@members.example.test');
  insert into public.persons (id, org_id, display_name, gender, date_of_birth) values (per, org, 'Fake ' || p_no, 'male', '1990-01-01');
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (org, pid, (select id from public.roles where org_id = org and code = p_role));
  insert into public.members (id, org_id, person_id, profile_id, member_no) values (mid, org, per, pid, p_no);
  update public.members set status = 'invited' where id = mid;
  update public.members set status = 'pending_approval' where id = mid;
  update public.members set status = 'active' where id = mid;
  if p_ranked then
    insert into public.member_ranks (org_id, member_id, rank_id)
    select org, mid, r.id from public.ranks r join public.rank_ladders l on l.id = r.ladder_id join public.categories c on c.id = l.category_id
    where c.code = 'novice' and r.deleted_at is null order by r.sort_order limit 1;
  end if;
  return u;
end $$;
create temp table us(role text primary key, u uuid, mid text);
grant select on us to public;
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2026-9601', false), null;
insert into us select 'outsider', pg_temp.mk('member', 'CPC-2026-9602', false), null;
insert into us select 'p1', pg_temp.mk('member', 'CPC-2026-9611', true), null;
insert into us select 'p2', pg_temp.mk('member', 'CPC-2026-9612', true), null;
insert into us select 'p3', pg_temp.mk('member', 'CPC-2026-9613', true), null;
insert into us select 'p4', pg_temp.mk('member', 'CPC-2026-9614', true), null;
insert into us select 'p5', pg_temp.mk('member', 'CPC-2026-9615', true), null;
insert into us select 'p6', pg_temp.mk('member', 'CPC-2026-9616', true), null;
update us set mid = (select m.id from public.members m join public.profiles p on p.id = m.profile_id where p.auth_user_id = us.u);

-- ---- the order is a pure function of the seed and the entrants
select is(core.draw_order(repeat('ab', 32), array['e1', 'e2', 'e3', 'e4', 'e5', 'e6', 'e7', 'e8', 'e9', 'e10', 'e11', 'e12']),
  core.draw_order(repeat('ab', 32), array['e12', 'e11', 'e10', 'e9', 'e8', 'e7', 'e6', 'e5', 'e4', 'e3', 'e2', 'e1']), 'the same seed gives the same order whatever order the entrants are listed in');
select isnt(core.draw_order(repeat('ab', 32), array['e1', 'e2', 'e3', 'e4', 'e5', 'e6', 'e7', 'e8', 'e9', 'e10', 'e11', 'e12']),
  core.draw_order(repeat('cd', 32), array['e1', 'e2', 'e3', 'e4', 'e5', 'e6', 'e7', 'e8', 'e9', 'e10', 'e11', 'e12']), 'another seed gives another order');
select is(cardinality(core.draw_order(repeat('ab', 32), array['e1', 'e2', 'e3'])), 3, 'every entrant is placed exactly once');

-- ---- set-up
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.create_event((select ev from fx), 'Draw Test', (select day1 from fx), (select day1 from fx), 'Hall', 0, null, null);
select public.create_division((select dv1 from fx), (select ev from fx), 'Five Players', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl_reg from fx), null);
select public.create_division((select dv2 from fx), (select ev from fx), 'Two Players', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl_rr from fx), null);
select public.create_division((select dv3 from fx), (select ev from fx), 'One Player', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl_rr from fx), null);
select public.set_event_status((select ev from fx), 'registration_open', null);
reset role;
update public.settings set value = 'false'::jsonb where key = 'events.registration_approval_required' and unit_id is null and deleted_at is null;
select pg_temp.as_user((select u from us where role = 'p1')); set local role authenticated;
select public.register_for_event((select g1 from fx), (select dv1 from fx)); select public.register_for_event((select h1 from fx), (select dv2 from fx)); select public.register_for_event((select k1 from fx), (select dv3 from fx)); reset role;
select pg_temp.as_user((select u from us where role = 'p2')); set local role authenticated;
select public.register_for_event((select g2 from fx), (select dv1 from fx)); select public.register_for_event((select h2 from fx), (select dv2 from fx)); reset role;
select pg_temp.as_user((select u from us where role = 'p3')); set local role authenticated;
select public.register_for_event((select g3 from fx), (select dv1 from fx)); reset role;
select pg_temp.as_user((select u from us where role = 'p4')); set local role authenticated;
select public.register_for_event((select g4 from fx), (select dv1 from fx)); reset role;
select pg_temp.as_user((select u from us where role = 'p5')); set local role authenticated;
select public.register_for_event((select g5 from fx), (select dv1 from fx)); reset role;
create temp table stg as select (select id from public.division_stages where division_id = (select dv1 from fx) and stage_no = 1) as s1,
  (select id from public.division_stages where division_id = (select dv1 from fx) and stage_no = 2) as s1b,
  (select id from public.division_stages where division_id = (select dv2 from fx)) as s2,
  (select id from public.division_stages where division_id = (select dv3 from fx)) as s3;
grant select on stg to public;

-- ---- access and preconditions
select is(has_function_privilege('anon', 'public.run_draw(text)', 'execute'), false, 'anonymous callers cannot run a draw');
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select throws_ok(format($f$select public.run_draw(%L)$f$, (select s1 from stg)), '22023', 'close registration before the draw', 'the draw waits for registration to close');
select public.set_event_status((select ev from fx), 'registration_closed', null);
reset role;
select pg_temp.as_user((select u from us where role = 'outsider')); set local role authenticated;
select throws_ok(format($f$select public.run_draw(%L)$f$, (select s1 from stg)), '42501', null, 'a member cannot run a draw');
reset role;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select throws_ok(format($f$select public.run_draw(%L)$f$, (select s1b from stg)), '22023', 'only the first stage is drawn from the entries; later stages are filled from the results', 'only stage 1 is drawn from the entries');
select throws_ok(format($f$select public.run_draw(%L)$f$, (select s3 from stg)), '22023', 'a draw needs at least 2 entries (this division has 1)', 'one entry cannot be drawn');
reset role;

-- a registration still waiting blocks the draw
update public.settings set value = 'true'::jsonb where key = 'events.registration_approval_required' and unit_id is null and deleted_at is null;
update public.events set status = 'registration_open' where id = (select ev from fx);
select pg_temp.as_user((select u from us where role = 'p6')); set local role authenticated;
select public.register_for_event((select g6 from fx), (select dv1 from fx));
reset role;
update public.events set status = 'registration_closed' where id = (select ev from fx);
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select throws_ok(format($f$select public.run_draw(%L)$f$, (select s1 from stg)), '22023', '1 registration(s) are still waiting for approval; approve or reject them first', 'a registration waiting for approval blocks the draw');
select public.decide_registration((select g6 from fx), 'reject', 'Not eligible');
reset role;

-- ---- running the draw
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
create temp table d1 as select public.run_draw((select s1 from stg)) as r;
reset role;
grant select on d1 to public;
select is(jsonb_array_length((select r -> 'order' from d1)), 5, 'all five entries are drawn');
select is((select count(distinct v)::int from d1, jsonb_array_elements_text(r -> 'order') v), 5, 'each exactly once');
select is((select array_agg(seed order by seed) from public.entries where division_id = (select dv1 from fx) and status = 'active'), array[1, 2, 3, 4, 5], 'entries are numbered 1 to 5 by draw position');
select is((select e.id from public.entries e where e.division_id = (select dv1 from fx) and e.seed = 1), (select r -> 'order' ->> 0 from d1), 'seed 1 is first in the draw');
select is((select status from public.division_stages where id = (select s1 from stg)), 'drawn', 'the stage is drawn');
select is((select status from public.divisions where id = (select dv1 from fx)), 'drawn', 'the division is drawn');
select is((select status from public.events where id = (select ev from fx)), 'registration_closed', 'the event waits for its other divisions');
select ok((select length(seed) = 64 from public.draws where id = (select r ->> 'draw_id' from d1)), 'a 256-bit seed is stored');
select is((select core.draw_order(seed, array(select jsonb_array_elements_text(d.result -> 'order'))) from public.draws d where d.id = (select r ->> 'draw_id' from d1))::text[],
  (select array(select jsonb_array_elements_text(r -> 'order')) from d1), 'the same seed reproduces the same draw');
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select is((select public.verify_draw((select r ->> 'draw_id' from d1)) ->> 'matches'), 'true', 'verify_draw confirms it');
select is((select public.run_draw((select s1 from stg)) ->> 'draw_id'), (select r ->> 'draw_id' from d1), 'a second run returns the existing draw');
select is((select public.run_draw((select s1 from stg)) ->> 'replayed'), 'true', 'and says so');
reset role;
select is((select count(*)::int from public.draws where division_stage_id = (select s1 from stg)), 1, 'there is still one draw');

-- the last open division drawn moves the event
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.cancel_division((select dv3 from fx), 'Only one entry');
select public.run_draw((select s2 from stg));
reset role;
select is((select status from public.events where id = (select ev from fx)), 'drawn', 'when every live division is drawn, the event is drawn');

-- ---- redo
insert into public.matches (id, org_id, division_stage_id, round_no, match_no, entry_a_id, entry_b_id)
select (select m1 from fx), (select org from fx), (select s1 from stg), 9, 1, (select r -> 'order' ->> 0 from d1), (select r -> 'order' ->> 1 from d1);
select pg_temp.as_user((select u from us where role = 'outsider')); set local role authenticated;
select throws_ok(format($f$select public.redo_draw(%L, 'Unfair', %L)$f$, (select s1 from stg), (select core.ulid())), '42501', null, 'a member cannot redo a draw');
reset role;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select throws_ok(format($f$select public.redo_draw(%L, null, %L)$f$, (select s1 from stg), (select core.ulid())), '22023', 'a reason of 3 to 500 characters is required', 'a redo needs a reason');
create temp table d2 as select public.redo_draw((select s1 from stg), 'Two friends were put in the same pool', (select k2 from fx)) as r;
reset role;
grant select on d2 to public;
select isnt((select r ->> 'draw_id' from d2), (select r ->> 'draw_id' from d1), 'a redo makes a new draw');
select is((select r ->> 'replaces' from d2), (select r ->> 'draw_id' from d1), 'that points back at the old one');
select is((select status from public.draws where id = (select r ->> 'draw_id' from d1)), 'superseded', 'the old draw is kept as superseded');
select is((select count(*)::int from public.draws where division_stage_id = (select s1 from stg) and status = 'active'), 1, 'exactly one draw is active');
select is((select redo_reason from public.draws where id = (select r ->> 'draw_id' from d2)), 'Two friends were put in the same pool', 'the reason is stored');
select is((select array_agg(seed order by seed) from public.entries where division_id = (select dv1 from fx) and status = 'active'), array[1, 2, 3, 4, 5], 'the entries are renumbered');
select is((select e.id from public.entries e where e.division_id = (select dv1 from fx) and e.seed = 1), (select r -> 'order' ->> 0 from d2), 'by the new draw');
select is((select status from public.matches where id = (select m1 from fx)), 'void', 'scheduled matches are voided for rebuilding');
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select is((select public.redo_draw((select s1 from stg), 'Two friends were put in the same pool', (select k2 from fx)) ->> 'draw_id'), (select r ->> 'draw_id' from d2), 'sending the same redo again changes nothing');
reset role;
select is((select count(*)::int from public.draws where division_stage_id = (select s1 from stg)), 2, 'so there are two draws in all');
select ok(exists (select 1 from core.audit_log where action = 'draw.redo' and record_id = (select r ->> 'draw_id' from d2)), 'the redo is audited');
select ok(exists (select 1 from core.audit_log where action = 'draw.run' and record_id = (select r ->> 'draw_id' from d1)), 'and so is the first run');

-- once play starts the draw is final
insert into public.matches (id, org_id, division_stage_id, round_no, match_no, entry_a_id, entry_b_id, status)
select (select m2 from fx), (select org from fx), (select s1 from stg), 9, 2, (select r -> 'order' ->> 2 from d2), (select r -> 'order' ->> 3 from d2), 'scheduled';
update public.matches set status = 'in_progress' where id = (select m2 from fx);
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select throws_ok(format($f$select public.redo_draw(%L, 'Too late', %L)$f$, (select s1 from stg), (select core.ulid())), '22023', 'the stage is already under way and cannot be redrawn', 'a draw cannot be redone after a match has started');
reset role;

-- the stored seed is for staff; members see the outcome through the entries and matches
select pg_temp.as_user((select u from us where role = 'outsider')); set local role authenticated;
select is((select count(*)::int from public.draws where division_stage_id = (select s2 from stg)), 0, 'a member cannot read the stored seed');
select is((select count(*)::int from public.entries where division_id = (select dv2 from fx) and seed is not null), 2, 'but sees the drawn entries and their positions');
reset role;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select is((select count(*)::int from public.draws where division_stage_id = (select s2 from stg)), 1, 'staff can read the draw');
reset role;

select * from finish();
rollback;
