begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as e1, core.ulid() as d1, core.ulid() as d2, core.ulid() as d3, core.ulid() as d4,
  (select id from public.format_templates where stages -> 0 ->> 'stage_type' = 'round_robin' and jsonb_array_length(stages) = 1 and deleted_at is null order by id limit 1) as tpl_rr,
  (select id from public.format_templates where stages -> 0 ->> 'stage_type' = 'pool_play' and deleted_at is null order by id limit 1) as tpl_reg,
  (select id from public.categories where code = 'novice' and deleted_at is null) as cat_novice,
  (select id from public.categories where code = 'advanced' and deleted_at is null) as cat_adv,
  current_date + 30 as day1;
grant select on fx to public;

create function pg_temp.mk(p_role text, p_no text) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); mid text := core.ulid(); org text := (select id from public.orgs where code = 'cpc');
begin
  insert into auth.users (id, email) values (u, lower(p_no) || '@members.example.test');
  insert into public.persons (id, org_id, display_name) values (per, org, 'Fake ' || p_no);
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (org, pid, (select id from public.roles where org_id = org and code = p_role));
  insert into public.members (id, org_id, person_id, profile_id, member_no) values (mid, org, per, pid, p_no);
  update public.members set status = 'invited' where id = mid;
  update public.members set status = 'pending_approval' where id = mid;
  update public.members set status = 'active' where id = mid;
  return u;
end $$;
create temp table us(role text primary key, u uuid);
grant select on us to public;
insert into us values ('member', pg_temp.mk('member', 'CPC-2026-9701'));
insert into us values ('admin', pg_temp.mk('admin', 'CPC-2026-9702'));
insert into us values ('desk', pg_temp.mk('front_desk', 'CPC-2026-9703'));

-- ---- access
select is(has_function_privilege('anon', 'public.create_event(text,text,date,date,text,numeric,timestamptz,timestamptz)', 'execute'), false, 'anonymous callers cannot create events');
select is(has_function_privilege('authenticated', 'core.hash_of(jsonb)', 'execute'), false, 'the hash helper is private');

select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
select throws_ok(format($f$select public.create_event(%L, 'Nope', %L, %L, null, 0, null, null)$f$, (select e1 from fx), (select day1 from fx), (select day1 from fx)), '42501', null, 'a member cannot create an event');
reset role;
select pg_temp.as_user((select u from us where role = 'desk'));
set local role authenticated;
select throws_ok(format($f$select public.create_event(%L, 'Nope', %L, %L, null, 0, null, null)$f$, (select e1 from fx), (select day1 from fx), (select day1 from fx)), '42501', null, 'front desk cannot create an event');
reset role;

-- ---- an event
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
create temp table r1 as select public.create_event((select e1 from fx), '  Test Open  ', (select day1 from fx), (select day1 + 1 from fx), 'Main hall', 300, null, null) as r;
reset role;
grant select on r1 to public;
select is((select r ->> 'status' from r1), 'draft', 'a new event is a draft');
select ok((select r ->> 'doc_no' from r1) ~ '^EV-\d{4}-\d{5}$', 'it gets an event number');
select is((select name from public.events where id = (select e1 from fx)), 'Test Open', 'the name is trimmed');

select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select is((select public.create_event((select e1 from fx), 'Test Open', (select day1 from fx), (select day1 + 1 from fx), 'Main hall', 300, null, null) ->> 'replayed'), 'true', 'the same request again returns the same event');
select throws_ok(format($f$select public.create_event(%L, 'Other', %L, %L, null, 0, null, null)$f$, (select e1 from fx), (select day1 from fx), (select day1 from fx)), 'CP422', null, 'another request under the same ID is refused');
select throws_ok(format($f$select public.create_event(%L, 'Bad dates', %L, %L, null, 0, null, null)$f$, core.ulid(), (select day1 from fx), (select day1 - 1 from fx)), '22023', null, 'an end date before the start is refused');
select throws_ok(format($f$select public.create_event(%L, 'Negative', %L, %L, null, -5, null, null)$f$, core.ulid(), (select day1 from fx), (select day1 from fx)), '22023', null, 'a negative fee is refused');
select throws_ok(format($f$select public.create_event('not-a-ulid', 'Bad id', %L, %L, null, 0, null, null)$f$, (select day1 from fx), (select day1 from fx)), '22023', null, 'an event needs a made ID');

-- a draft cannot open without a division
select throws_ok(format($f$select public.set_event_status(%L, 'registration_open', null)$f$, (select e1 from fx)), '22023', 'add at least one division before opening registration', 'registration needs a division first');

-- ---- divisions
create temp table r2 as select public.create_division((select d1 from fx), (select e1 from fx), 'Novice Singles', (select cat_novice from fx), 'singles', null, null, null, null, 16, (select tpl_reg from fx), null) as r;
reset role;
grant select on r2 to public;
select is((select r ->> 'status' from r2), 'open', 'a new division is open');
select is((select (r ->> 'stages')::int from r2), 2, 'Regular (Bracketing) copies its two stages');
select is((select count(*)::int from public.division_stages where division_id = (select d1 from fx)), 2, 'the stage rows exist');
select is((select array_agg(stage_type order by stage_no) from public.division_stages where division_id = (select d1 from fx)), array['pool_play', 'single_elimination'], 'in order');
select is((select scoring_snapshot ->> 'name' from public.divisions where id = (select d1 from fx)), 'Single game to 11', 'the default scoring rule is copied in');
select is((select jsonb_array_length(format_snapshot) from public.divisions where id = (select d1 from fx)), 2, 'the format is copied in');

-- a later template edit does not change the division
update public.format_templates set stages = '[{"stage_type": "round_robin", "config": {}}]'::jsonb where id = (select tpl_reg from fx);
select is((select jsonb_array_length(format_snapshot) from public.divisions where id = (select d1 from fx)), 2, 'editing the template later does not change the division');

select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select is((select public.create_division((select d1 from fx), (select e1 from fx), 'Novice Singles', (select cat_novice from fx), 'singles', null, null, null, null, 16, (select tpl_reg from fx), null) ->> 'replayed'), 'true', 'the same division request returns the same division');
select throws_ok(format($f$select public.create_division(%L, %L, 'Novice Singles', %L, 'singles', null, null, null, null, 16, %L, null)$f$, (select d2 from fx), (select e1 from fx), (select cat_novice from fx), (select tpl_rr from fx)), '23505', null, 'two live divisions cannot share a name');
select throws_ok(format($f$select public.create_division(%L, %L, 'Advanced Mixed', %L, 'pairs', null, null, null, null, null, %L, null)$f$, (select d2 from fx), (select e1 from fx), (select cat_adv from fx), (select tpl_rr from fx)), '22023', null, 'only singles or doubles');
select throws_ok(format($f$select public.create_division(%L, %L, 'Advanced Singles', %L, 'singles', null, null, (select id from public.ranks where code like 'novice-%%' limit 1), null, null, %L, null)$f$, (select d2 from fx), (select e1 from fx), (select cat_adv from fx), (select tpl_rr from fx)), '22023', 'the rank band must belong to the category''s ladder', 'a rank band from another category is refused');
create temp table r3 as select public.create_division((select d3 from fx), (select e1 from fx), 'Advanced Doubles', (select cat_adv from fx), 'doubles', 'mixed', '35+', null, null, 8, (select tpl_rr from fx), null) as r;

-- ---- editing a division
select is((select public.update_division((select d3 from fx), 'Advanced Mixed Doubles', 'mixed', '35+', null, null, 12) ->> 'ok'), 'true', 'a division can be edited while open');
select is((select max_entries from public.divisions where id = (select d3 from fx)), 12, 'the new limit is saved');
select throws_ok(format($f$select public.update_division(%L, 'Novice Singles', null, null, null, null, null)$f$, (select d3 from fx)), '23505', null, 'renaming onto another division name is refused');
select throws_ok(format($f$select public.update_division(%L, 'X', null, null, null, null, 1)$f$, (select d3 from fx)), '22023', null, 'an entry limit under 2 is refused');

-- ---- the event goes through its states
select is((select public.set_event_status((select e1 from fx), 'registration_open', null) ->> 'status'), 'registration_open', 'registration opens');
select is((select public.set_event_status((select e1 from fx), 'registration_open', null) ->> 'replayed'), 'true', 'opening twice is safe');
select throws_ok(format($f$select public.set_event_status(%L, 'drawn', null)$f$, (select e1 from fx)), '22023', null, 'drawn is set by the draw, not by hand');
select throws_ok(format($f$select public.set_event_status(%L, 'cancelled', null)$f$, (select e1 from fx)), '22023', 'a reason is required', 'cancelling needs a reason');
select throws_ok(format($f$select public.set_event_status(%L, 'completed', null)$f$, (select e1 from fx)), '22023', null, 'completed is refused while divisions are open');
select is((select public.set_event_status((select e1 from fx), 'registration_closed', null) ->> 'status'), 'registration_closed', 'registration closes');
select is((select public.set_event_status((select e1 from fx), 'registration_open', null) ->> 'status'), 'registration_open', 'and can reopen');

-- ---- cancelling a division
select throws_ok(format($f$select public.cancel_division(%L, null)$f$, (select d3 from fx)), '22023', null, 'a division needs a reason to be cancelled');
select is((select public.cancel_division((select d3 from fx), 'Too few entries') ->> 'status'), 'cancelled', 'a division can be cancelled');
select is((select public.cancel_division((select d3 from fx), 'Too few entries') ->> 'replayed'), 'true', 'cancelling twice is safe');
select is((select count(*)::int from public.division_stages where division_id = (select d3 from fx) and status = 'cancelled'), 1, 'its stages are cancelled with it');
select throws_ok(format($f$select public.update_division(%L, 'Back', null, null, null, null, null)$f$, (select d3 from fx)), '22023', null, 'a cancelled division cannot be edited');
select is((select public.create_division((select d4 from fx), (select e1 from fx), 'Advanced Mixed Doubles', (select cat_adv from fx), 'doubles', null, null, null, null, null, (select tpl_rr from fx), null) ->> 'status'), 'open', 'a cancelled division frees its name');

-- ---- cancelling the event takes open divisions with it
select is((select public.set_event_status((select e1 from fx), 'cancelled', 'Venue unavailable') ->> 'status'), 'cancelled', 'an event can be cancelled with a reason');
select is((select count(*)::int from public.divisions where event_id = (select e1 from fx) and status = 'cancelled'), 3, 'all its divisions are cancelled');
select throws_ok(format($f$select public.update_event(%L, 'Revived', %L, %L, null, 0, null, null)$f$, (select e1 from fx), (select day1 from fx), (select day1 from fx)), '22023', null, 'a cancelled event cannot be edited');
select throws_ok(format($f$select public.create_division(%L, %L, 'Late', %L, 'singles', null, null, null, null, null, %L, null)$f$, core.ulid(), (select e1 from fx), (select cat_novice from fx), (select tpl_rr from fx)), '22023', null, 'a cancelled event takes no new divisions');
select throws_ok(format($f$update public.events set name = 'sneaky' where id = %L$f$, (select e1 from fx)), '42501', null, 'the app cannot write events directly');
reset role;

-- ---- history and audit
select ok((select count(*) from public.entity_events where entity_type = 'event' and entity_id = (select e1 from fx)) >= 4, 'every event status change is in the history');
select ok(exists (select 1 from core.audit_log where action = 'division.cancel' and record_id = (select d3 from fx)), 'a division cancellation is audited');

select * from finish();
rollback;
