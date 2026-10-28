begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create function pg_temp.set_flag(p_key text, p_on boolean) returns void language sql as $$
  update public.settings set value = to_jsonb(p_on) where key = p_key and unit_id is null and deleted_at is null
$$;

create temp table chain as select * from core.rank_chain((select id from public.orgs where code = 'cpc'));
grant select on chain to public;
create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as ev, core.ulid() as dvR, core.ulid() as dvD,
  (select id from public.format_templates where stages -> 0 ->> 'stage_type' = 'round_robin' and jsonb_array_length(stages) = 1 and deleted_at is null order by id limit 1) as tpl,
  (select id from public.categories where code = 'novice' and deleted_at is null) as cat_novice,
  (select r.id from public.ranks r join public.rank_ladders l on l.id = r.ladder_id join public.categories c on c.id = l.category_id
    where c.code = 'novice' and r.deleted_at is null order by r.sort_order desc limit 1) as novice_top,
  current_date + 30 as day1;
grant select on fx to public;

create function pg_temp.mk(p_role text, p_no text, p_name text, p_idx int, p_active boolean) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); mid text := core.ulid(); org text := (select id from public.orgs where code = 'cpc');
begin
  insert into auth.users (id, email) values (u, lower(p_no) || '@members.example.test');
  insert into public.persons (id, org_id, display_name, gender, date_of_birth, email, mobile)
  values (per, org, p_name, 'male', '1990-01-01', 'zzyzx.' || lower(p_no) || '@example.test', '0917000' || right(p_no, 4));
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (org, pid, (select id from public.roles where org_id = org and code = p_role));
  insert into public.members (id, org_id, person_id, profile_id, member_no) values (mid, org, per, pid, p_no);
  update public.members set status = 'invited' where id = mid;
  update public.members set status = 'pending_approval' where id = mid;
  update public.members set status = 'active' where id = mid;
  if p_idx is not null then
    insert into public.member_ranks (org_id, member_id, rank_id) values (org, mid, (select rank_id from chain where idx = p_idx));
  end if;
  if not p_active then
    update public.members set status = 'suspended', status_reason = 'test' where id = mid;
  end if;
  return u;
end $$;
create temp table us(role text primary key, u uuid, mid text, strength int);
grant select on us to public;
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2026-97701', 'Zzyzx Admin', null, true), null, null;
insert into us select 'ref', pg_temp.mk('referee', 'CPC-2026-97702', 'Zzyzx Ref', null, true), null, null;
insert into us select 'p1', pg_temp.mk('member', 'CPC-2026-97711', 'Zzyzx Alpha', 4, true), null, 1;
insert into us select 'p2', pg_temp.mk('member', 'CPC-2026-97712', 'Zzyzx Bravo', 4, true), null, 2;
insert into us select 'p3', pg_temp.mk('member', 'CPC-2026-97713', 'Zzyzx Charlie', 3, true), null, 3;
insert into us select 'p4', pg_temp.mk('member', 'CPC-2026-97714', 'Zzyzx Delta', 3, true), null, 4;
insert into us select 'gone', pg_temp.mk('member', 'CPC-2026-97715', 'Zzyzx Suspended', 7, false), null, null;
insert into us select 'plain', pg_temp.mk('member', 'CPC-2026-97716', 'Zzyzx Unranked', null, true), null, null;
update us set mid = (select m.id from public.members m join public.profiles p on p.id = m.profile_id where p.auth_user_id = us.u);

-- ---- nothing is public until the club says so
select is(has_function_privilege('anon', 'public.public_results()', 'execute'), true, 'visitors can call the results page function');
set local role anon;
create temp table r0 as select public.public_results() as j;
create temp table l0 as select public.public_leaderboard() as j;
reset role;
grant select on r0, l0 to public;
select is((select j::text from r0), '{"enabled": false}', 'results answer only "not enabled" by default');
select is((select j::text from l0), '{"enabled": false}', 'and so does the leaderboard');

-- ---- a finished division
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.create_event((select ev from fx), 'Zzyzx Public Open', (select day1 from fx), (select day1 from fx), 'Hall', 0, null, null);
select public.create_division((select dvR from fx), (select ev from fx), 'Zzyzx Round Robin', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.create_division((select dvD from fx), (select ev from fx), 'Zzyzx Still Open', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.set_event_status((select ev from fx), 'registration_open', null);
reset role;
update public.settings set value = 'false'::jsonb where key = 'events.registration_approval_required' and unit_id is null and deleted_at is null;
create function pg_temp.join_div(p_role text, p_div text) returns void language plpgsql as $$
begin
  perform pg_temp.as_user((select u from us where role = p_role));
  set local role authenticated;
  perform public.register_for_event(core.ulid(), p_div);
  reset role;
end $$;
grant execute on function pg_temp.join_div(text, text) to public;
select pg_temp.join_div('p' || i, (select dvR from fx)) from generate_series(1, 4) i;
create temp table stg as select (select id from public.division_stages where division_id = (select dvR from fx)) as s;
grant select on stg to public;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.cancel_division((select dvD from fx), 'Not used');
select public.set_event_status((select ev from fx), 'registration_closed', null);
select public.run_draw((select s from stg));
reset role;
create temp table ent as
  select u.role, u.strength, e.id as entry from us u
  join public.entry_members em on em.member_id = u.mid join public.entries e on e.id = em.entry_id where u.strength is not null;
grant select on ent to public;
-- a rule that would move the winner, and the club switch that stops all movement
insert into public.rank_rules (org_id, name, conditions, action, levels, priority)
values ((select org from fx), 'Zzyzx winner up', '{"placement": 1}', 'up', 1, 1);
select pg_temp.set_flag('ranks.movement_enabled', false);
select pg_temp.as_user((select u from us where role = 'ref')); set local role authenticated;
select public.enter_score(m.id, case when (select strength from ent where entry = m.entry_a_id) < (select strength from ent where entry = m.entry_b_id)
    then '[{"a":11,"b":4}]'::jsonb else '[{"a":4,"b":11}]'::jsonb end)
  from public.matches m where m.division_stage_id = (select s from stg) and m.status = 'scheduled';
select public.finalize_match(m.id) from public.matches m where m.division_stage_id = (select s from stg) and m.status = 'in_progress';
reset role;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
create temp table fin as select public.finalize_division((select dvR from fx)) as r;
reset role;
grant select on fin to public;
select is((select r ->> 'disabled' from fin), 'true', 'with rank movement switched off the division still finalizes and says so');
select is((select count(*)::int from public.rank_history where division_id = (select dvR from fx)), 0, 'but nobody moves, although a rule would have moved the winner');
select is((select count(*)::int from public.division_results where division_id = (select dvR from fx)), 4, 'the results are recorded');

-- ---- the club turns the pages on
select pg_temp.set_flag('public.results_enabled', true);
select pg_temp.set_flag('public.leaderboard_enabled', true);
set local role anon;
create temp table r1 as select public.public_results() as j;
create temp table l1 as select public.public_leaderboard() as j;
reset role;
grant select on r1, l1 to public;
select is((select j ->> 'enabled' from r1), 'true', 'results are public once enabled');
select is((select count(*)::int from r1, jsonb_array_elements(j -> 'divisions') d where d ->> 'division' = 'Zzyzx Round Robin'), 1, 'the finished division is listed');
select is((select count(*)::int from r1, jsonb_array_elements(j -> 'divisions') d where d ->> 'division' = 'Zzyzx Still Open'), 0, 'a division that did not finish is not');
select is((select array_agg(k order by k) from r1, jsonb_array_elements(j -> 'divisions') d, jsonb_object_keys(d) k where d ->> 'division' = 'Zzyzx Round Robin'),
  array['category', 'division', 'event', 'finished_on', 'format', 'podium'], 'a division shows only its names, category, format, date and podium');
select is((select string_agg(p ->> 'placement' || ':' || (p ->> 'name'), ', ' order by (p ->> 'placement')::int)
  from r1, jsonb_array_elements(j -> 'divisions') d, jsonb_array_elements(d -> 'podium') p where d ->> 'division' = 'Zzyzx Round Robin'),
  '1:Zzyzx Alpha, 2:Zzyzx Bravo, 3:Zzyzx Charlie', 'the podium is the top three with display names, not the fourth');
select is((select array_agg(distinct k order by k) from r1, jsonb_array_elements(j -> 'divisions') d, jsonb_array_elements(d -> 'podium') p, jsonb_object_keys(p) k where d ->> 'division' = 'Zzyzx Round Robin'),
  array['name', 'placement'], 'a podium entry is a placement and a name');
select is(position('zzyzx.' in (select j::text from r1)), 0, 'no email address in the results');
select is(position('CPC-2026' in (select j::text from r1)), 0, 'no member ID');
select is(position('0917000' in (select j::text from r1)), 0, 'no phone number');
select is((select j ->> 'enabled' from l1), 'true', 'the leaderboard is public once enabled');
select is((select array_agg(p ->> 'name' order by ord) from l1, jsonb_array_elements(j -> 'players') with ordinality as t(p, ord) where p ->> 'name' like 'Zzyzx%'),
  array['Zzyzx Alpha', 'Zzyzx Bravo', 'Zzyzx Charlie', 'Zzyzx Delta'], 'ranked active players, highest rank first (the suspended and the unranked are left out)');
select is((select array_agg(k order by k) from l1, jsonb_array_elements(j -> 'players') p, jsonb_object_keys(p) k where p ->> 'name' = 'Zzyzx Alpha'),
  array['category', 'name', 'rank'], 'a player shows only a name, category and rank');
select is(position('zzyzx.' in (select j::text from l1)), 0, 'no email address in the leaderboard');
select is(position('CPC-2026' in (select j::text from l1)), 0, 'no member ID');
select is((select count(*)::int from l1, jsonb_array_elements(j -> 'categories')), (select count(*)::int from public.categories where org_id = (select org from fx) and deleted_at is null and is_active), 'the category list is offered for a filter');
select pg_temp.as_user((select u from us where role = 'p1')); set local role authenticated;
select is((select array_agg(display_name order by rank_idx desc, display_name) from public.ranking_list() where display_name like 'Zzyzx%'),
  (select array_agg(p ->> 'name' order by ord) from l1, jsonb_array_elements(j -> 'players') with ordinality as t(p, ord) where p ->> 'name' like 'Zzyzx%'), 'the public list matches the members'' ranking list');
reset role;

-- ---- and off again
select pg_temp.set_flag('public.leaderboard_enabled', false);
set local role anon;
select is((public.public_leaderboard())::text, '{"enabled": false}', 'turning the switch off hides the leaderboard at once');
reset role;
select is(public.public_landing_info() ->> 'results_public', 'true', 'the landing information says which public pages exist');
select is(public.public_landing_info() ->> 'leaderboard_public', 'false', 'and which do not');

-- ---- the switches are real settings, validated and changeable only with the permission
select pg_temp.as_user((select u from us where role = 'p1')); set local role authenticated;
select throws_ok($$select public.update_setting('public.leaderboard_enabled', 'true'::jsonb, 'I want it', core.ulid())$$, '42501', null, 'a member cannot switch a public page on');
reset role;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select throws_ok($$select public.update_setting('public.leaderboard_enabled', '"yes"'::jsonb, 'Wrong type', core.ulid())$$, null, null, 'the value must be true or false');
select lives_ok($$select public.update_setting('public.leaderboard_enabled', 'true'::jsonb, 'The club decided to publish it', core.ulid())$$, 'an administrator can switch it on, with a reason');
reset role;
set local role anon;
select is((public.public_leaderboard() ->> 'enabled'), 'true', 'and it is public again');
reset role;

select * from finish();
rollback;
