begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

-- ---- moving along the chain of ranks
create temp table chain as select * from core.rank_chain((select id from public.orgs where code = 'cpc'));
grant select on chain to public;
select ok((select count(*) from chain) >= 4, 'the club has a chain of ranks');
select is(core.rank_move((select rank_id from chain order by idx desc limit 1), 1), (select rank_id from chain order by idx desc limit 1), 'the top of the chain cannot go higher');
select is(core.rank_move((select rank_id from chain order by idx limit 1), -1), (select rank_id from chain order by idx limit 1), 'the bottom cannot go lower');
select is(core.rank_move((select rank_id from chain order by idx limit 1), 1), (select rank_id from chain where idx = 2), 'one up from the bottom is the second rank');
select is(core.rank_move((select rank_id from chain order by idx limit 1), 2), (select rank_id from chain where idx = 3), 'two levels move two places');
select is(core.rank_move((select rank_id from chain order by idx limit 1), 100), (select rank_id from chain order by idx desc limit 1), 'a long move stops at the top');
-- the top of one ladder continues into the next, unless that ladder stops at its edge
create temp table edge as select c1.rank_id as top_rank, c2.rank_id as next_rank, c1.ladder_id as ladder
  from chain c1 join chain c2 on c2.idx = c1.idx + 1 and c2.ladder_id <> c1.ladder_id order by c1.idx limit 1;
grant select on edge to public;
select is(core.rank_move((select top_rank from edge), 1), (select next_rank from edge), 'by default the top of a ladder continues into the next category');
select is(core.rank_move((select next_rank from edge), -1), (select top_rank from edge), 'and the bottom of the next one comes back');
update public.rank_ladders set overflow = 'stop' where id = (select ladder from edge);
select is(core.rank_move((select top_rank from edge), 1), (select top_rank from edge), 'a ladder set to stop keeps its own top rank');
update public.rank_ladders set overflow = 'chain' where id = (select ladder from edge);

-- ---- a real division: 16 players, split single elimination
create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as ev, core.ulid() as dvS, core.ulid() as dvR, core.ulid() as dvG,
  (select id from public.format_templates where lower(name) like 'split single elimination%' and deleted_at is null) as tpl_split,
  (select id from public.format_templates where stages -> 0 ->> 'stage_type' = 'round_robin' and jsonb_array_length(stages) = 1 and deleted_at is null order by id limit 1) as tpl_rr,
  (select id from public.format_templates where stages -> 0 ->> 'stage_type' = 'pool_play' and deleted_at is null order by id limit 1) as tpl_reg,
  (select id from public.categories where code = 'novice' and deleted_at is null) as cat_novice,
  (select r.id from public.ranks r join public.rank_ladders l on l.id = r.ladder_id join public.categories c on c.id = l.category_id
    where c.code = 'novice' and r.deleted_at is null order by r.sort_order desc limit 1) as novice_top,
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
    -- everyone starts at the top of Novice, so a move can go either way
    insert into public.member_ranks (org_id, member_id, rank_id) values (org, mid, (select novice_top from fx));
  end if;
  return u;
end $$;
create temp table us(role text primary key, u uuid, mid text, strength int);
grant select on us to public;
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2037-97401', false), null, null;
insert into us select 'ref', pg_temp.mk('referee', 'CPC-2037-97402', false), null, null;
insert into us select 'outsider', pg_temp.mk('member', 'CPC-2037-97403', false), null, null;
insert into us select 'p' || i, pg_temp.mk('member', 'CPC-2037-974' || lpad((10 + i)::text, 2, '0'), true), null, i from generate_series(1, 16) i;
update us set mid = (select m.id from public.members m join public.profiles p on p.id = m.profile_id where p.auth_user_id = us.u);

select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.create_event((select ev from fx), 'Rank Test', (select day1 from fx), (select day1 from fx), 'Hall', 0, null, null);
select public.create_division((select dvS from fx), (select ev from fx), 'Split Sixteen', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl_split from fx), null);
select public.create_division((select dvR from fx), (select ev from fx), 'Round Robin Four', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl_rr from fx), null);
select public.create_division((select dvG from fx), (select ev from fx), 'Regular Six', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl_reg from fx), null);
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
select pg_temp.join_div('p' || i, (select dvS from fx)) from generate_series(1, 16) i;
select pg_temp.join_div('p' || i, (select dvR from fx)) from generate_series(1, 4) i;
select pg_temp.join_div('p' || i, (select dvG from fx)) from generate_series(1, 6) i;
create temp table stg as select
  (select id from public.division_stages where division_id = (select dvS from fx)) as s,
  (select id from public.division_stages where division_id = (select dvR from fx)) as r,
  (select id from public.division_stages where division_id = (select dvG from fx) and stage_no = 1) as g1,
  (select id from public.division_stages where division_id = (select dvG from fx) and stage_no = 2) as g2;
grant select on stg to public;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.set_stage_config((select g1 from stg), '{"target_group_size": 3}');
select public.set_event_status((select ev from fx), 'registration_closed', null);
select public.run_draw((select s from stg));
select public.run_draw((select r from stg));
select public.run_draw((select g1 from stg));
reset role;
create temp table ent as
  select u.role, u.strength, e.id as entry, e.division_id from us u
  join public.entry_members em on em.member_id = u.mid join public.entries e on e.id = em.entry_id where u.strength is not null;
grant select on ent to public;
create function pg_temp.play_stage(p_stage text) returns void language plpgsql as $$
begin
  perform pg_temp.as_user((select u from us where role = 'ref'));
  set local role authenticated;
  perform public.enter_score(m.id, case when (select strength from ent where entry = m.entry_a_id) < (select strength from ent where entry = m.entry_b_id)
      then '[{"a":11,"b":4}]'::jsonb else '[{"a":4,"b":11}]'::jsonb end)
    from public.matches m where m.division_stage_id = p_stage and m.status = 'scheduled' and m.entry_a_id is not null and m.entry_b_id is not null;
  perform public.finalize_match(m.id) from public.matches m where m.division_stage_id = p_stage and m.status = 'in_progress';
  reset role;
end $$;
grant execute on function pg_temp.play_stage(text) to public;

-- ---- the bracket round rules (migration 1940): set after Round 1 and before the quarterfinals start
create temp table rules as select
  (select id from public.scoring_rules where name = 'Single Game to 11' and deleted_at is null) as r11,
  (select id from public.scoring_rules where name = 'Single Game to 15' and deleted_at is null) as r15,
  (select id from public.scoring_rules where name = 'Single Game to 21' and deleted_at is null) as r21,
  core.ulid() as k1, core.ulid() as k2, core.ulid() as k3;
grant select on rules to public;
create function pg_temp.rule_of(p_group text, p_round integer, p_no integer default 1) returns jsonb language sql as
$$ select core.match_scoring_rule(id) from public.matches
   where division_stage_id = (select s from stg) and group_label = p_group and round_no = p_round and status <> 'void'
   order by match_no limit 1 $$;
grant execute on function pg_temp.rule_of(text, integer, integer) to public;

select is((select count(*)::int from public.matches where division_stage_id = (select s from stg)), 8, 'sixteen teams: 8 first-round games');

-- permissions and input checks
select pg_temp.as_user((select u from us where role = 'outsider')); set local role authenticated;
select throws_ok(format('select public.set_stage_round_scoring(%L, ''{}'', %L)', (select s from stg), core.ulid()), '42501', null, 'a member cannot set the round scoring');
reset role;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select throws_ok(format('select public.set_stage_round_scoring(%L, ''{}'', %L)', (select r from stg), core.ulid()), '22023', null, 'only Split Single Elimination has round scoring');
select throws_ok(format('select public.set_stage_round_scoring(%L, ''{"X": {}}'', %L)', (select s from stg), core.ulid()), '22023', null, 'only the H and L brackets can be set');
select throws_ok(format('select public.set_stage_round_scoring(%L, %L, %L)', (select s from stg), '{"H": {"third_place": "x"}}', core.ulid()), '22023', null, 'only quarterfinal, semifinal and final can be set');
select throws_ok(format('select public.set_stage_round_scoring(%L, %L, %L)', (select s from stg), '{"H": {"final": "no-such-rule"}}', core.ulid()), '22023', null, 'the rule must exist');

-- H: QF 11, SF 15, Final 21. L: QF 11, SF 11, Final 15 (the two brackets differ)
create temp table req as select jsonb_build_object(
  'H', jsonb_build_object('quarterfinal', r11, 'semifinal', r15, 'final', r21),
  'L', jsonb_build_object('quarterfinal', r11, 'semifinal', r11, 'final', r15)) as j from rules;
grant select on req to public;
select lives_ok(format('select public.set_stage_round_scoring(%L, %L, %L)', (select s from stg), (select j from req), (select k1 from rules)), 'an event manager sets the bracket round rules');
select lives_ok(format('select public.set_stage_round_scoring(%L, %L, %L)', (select s from stg), (select j from req), (select k1 from rules)), 'sending it again is safe');
select is((select round_scoring -> 'H' -> 'final' ->> 'name' from public.division_stages where id = (select s from stg)), 'Single Game to 21', 'the H final rule is stored');
select is((select round_scoring -> 'L' -> 'final' ->> 'name' from public.division_stages where id = (select s from stg)), 'Single Game to 15', 'and the L final rule is different');
reset role;

-- Round 1 is played with the division's own rule
select pg_temp.play_stage((select s from stg));
select is((select count(*)::int from public.matches where division_stage_id = (select s from stg) and group_label = 'H'), 7, 'the H bracket exists: 4 quarterfinals, 2 semifinals, 1 final');
select is((select (select core.match_scoring_rule(id) ->> 'name' from public.matches where division_stage_id = (select s from stg) and round_no = 1 and match_no = 1)), 'Single Game to 11', 'Round 1 uses the division rule');
select is(pg_temp.rule_of('H', 2) ->> 'name', 'Single Game to 11', 'H quarterfinal: to 11');
select is(pg_temp.rule_of('H', 3) ->> 'name', 'Single Game to 15', 'H semifinal: to 15');
select is(pg_temp.rule_of('H', 4) ->> 'name', 'Single Game to 21', 'H final: to 21');
select is(pg_temp.rule_of('L', 2) ->> 'name', 'Single Game to 11', 'L quarterfinal: to 11');
select is(pg_temp.rule_of('L', 3) ->> 'name', 'Single Game to 11', 'L semifinal: to 11 (set apart from H)');
select is(pg_temp.rule_of('L', 4) ->> 'name', 'Single Game to 15', 'L final: to 15');
select is((pg_temp.rule_of('H', 4) ->> 'forfeit_score')::int, 21, 'a forfeit in the H final scores 21');

-- still settable after Round 1, before any quarterfinal starts
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select lives_ok(format('select public.set_stage_round_scoring(%L, %L, %L)', (select s from stg), (select j from req), (select k2 from rules)), 'the rules can still be set after Round 1');
reset role;

-- quarterfinals are played to 11
select pg_temp.play_stage((select s from stg));
select is((select count(*)::int from public.matches where division_stage_id = (select s from stg) and round_no = 2 and status = 'completed'), 8, 'all eight quarterfinals were played to 11');
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select throws_ok(format('select public.set_stage_round_scoring(%L, %L, %L)', (select s from stg), (select j from req), (select k3 from rules)), '22023', 'the bracket rounds have started; the round scoring is locked', 'once a quarterfinal has started the rules are locked');
reset role;

-- the H semifinal is to 15: a game to 11 is not a finished game, a game to 15 is
create temp table sf as select
  (select id from public.matches where division_stage_id = (select s from stg) and group_label = 'H' and round_no = 3 order by match_no limit 1) as h_sf,
  (select id from public.matches where division_stage_id = (select s from stg) and group_label = 'L' and round_no = 3 order by match_no limit 1) as l_sf;
grant select on sf to public;
select pg_temp.as_user((select u from us where role = 'ref')); set local role authenticated;
select public.enter_score((select h_sf from sf), '[{"a":11,"b":4}]');
select throws_ok(format('select public.finalize_match(%L)', (select h_sf from sf)), '22023', null, 'H semifinal: 11-4 is refused because the game is to 15');
select public.enter_score((select h_sf from sf), '[{"a":15,"b":9}]');
select lives_ok(format('select public.finalize_match(%L)', (select h_sf from sf)), 'H semifinal: 15-9 is accepted');
-- the L semifinal is to 11
select public.enter_score((select l_sf from sf), '[{"a":11,"b":4}]');
select lives_ok(format('select public.finalize_match(%L)', (select l_sf from sf)), 'L semifinal: 11-4 is accepted');
reset role;

select * from finish();
rollback;
