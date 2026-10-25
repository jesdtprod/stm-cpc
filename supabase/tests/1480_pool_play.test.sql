begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as ev, core.ulid() as dvA, core.ulid() as dvB, core.ulid() as dvC,
  (select id from public.format_templates where lower(name) = 'regular (bracketing)' and deleted_at is null) as tpl,
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
create temp table us(role text primary key, u uuid, mid text, strength int);
grant select on us to public;
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2026-97301', false), null, null;
insert into us select 'ref', pg_temp.mk('referee', 'CPC-2026-97302', false), null, null;
insert into us select 'outsider', pg_temp.mk('member', 'CPC-2026-97303', false), null, null;
insert into us select 'p' || i, pg_temp.mk('member', 'CPC-2026-973' || lpad((10 + i)::text, 2, '0'), true), null, i from generate_series(1, 20) i;
update us set mid = (select m.id from public.members m join public.profiles p on p.id = m.profile_id where p.auth_user_id = us.u);

select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.create_event((select ev from fx), 'Regular Test', (select day1 from fx), (select day1 from fx), 'Hall', 0, null, null);
select public.create_division((select dvA from fx), (select ev from fx), 'Twenty Players', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.create_division((select dvB from fx), (select ev from fx), 'Nine Players', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.create_division((select dvC from fx), (select ev from fx), 'Six Players', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
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
select pg_temp.join_div('p' || i, (select dvA from fx)) from generate_series(1, 20) i;
select pg_temp.join_div('p' || i, (select dvB from fx)) from generate_series(1, 9) i;
select pg_temp.join_div('p' || i, (select dvC from fx)) from generate_series(1, 6) i;

create temp table stg as select
  (select id from public.division_stages where division_id = (select dvA from fx) and stage_no = 1) as a1,
  (select id from public.division_stages where division_id = (select dvA from fx) and stage_no = 2) as a2,
  (select id from public.division_stages where division_id = (select dvB from fx) and stage_no = 1) as b1,
  (select id from public.division_stages where division_id = (select dvB from fx) and stage_no = 2) as b2,
  (select id from public.division_stages where division_id = (select dvC from fx) and stage_no = 1) as c1,
  (select id from public.division_stages where division_id = (select dvC from fx) and stage_no = 2) as c2;
grant select on stg to public;

-- ---- format settings
select pg_temp.as_user((select u from us where role = 'outsider')); set local role authenticated;
select throws_ok(format($f$select public.set_stage_config(%L, '{"target_group_size": 3}')$f$, (select b1 from stg)), '42501', null, 'a member cannot change a format');
reset role;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select throws_ok(format($f$select public.set_stage_config(%L, '{"target_group_size": 99}')$f$, (select b1 from stg)), '22023', null, 'a bracket size out of range is refused');
select throws_ok(format($f$select public.set_stage_config(%L, '{"nonsense": 1}')$f$, (select b1 from stg)), '22023', 'unknown setting: nonsense', 'an unknown setting is refused');
select throws_ok(format($f$select public.set_stage_config(%L, '{"group_assignment": "by_hair_colour"}')$f$, (select b1 from stg)), '22023', null, 'an unknown way of filling brackets is refused');
select throws_ok(format($f$select public.set_stage_config(%L, '{"target_group_size": 3}')$f$, (select a2 from stg)), '22023', 'only a pool play stage has these settings', 'a knockout stage has none');
select is((select public.set_stage_config((select b1 from stg), '{"target_group_size": 3}') -> 'config' ->> 'target_group_size'), '3', 'the target bracket size is saved');
select is((select public.set_stage_config((select b1 from stg), '{"target_group_size": 3}') -> 'config' ->> 'advance_per_group'), '2', 'and the other settings are kept');
select public.set_stage_config((select c1 from stg), '{"target_group_size": 3}');
select public.set_event_status((select ev from fx), 'registration_closed', null);
select public.run_draw((select a1 from stg));
select public.run_draw((select b1 from stg));
select public.run_draw((select c1 from stg));
select throws_ok(format($f$select public.set_stage_config(%L, '{"target_group_size": 4}')$f$, (select b1 from stg)), '22023', 'format settings can change only before the draw', 'after the draw the format is fixed');
reset role;

create temp table ent as
  select u.role, u.strength, e.id as entry, e.division_id from us u
  join public.entry_members em on em.member_id = u.mid join public.entries e on e.id = em.entry_id where u.strength is not null;
grant select on ent to public;

-- ---- twenty entries: four brackets of five, 40 pool games
select is((select count(*)::int from public.matches where division_stage_id = (select a1 from stg)), 40, '20 entries: 40 pool games');
select is((select string_agg(group_label || ':' || c, ' ' order by group_label) from (select group_label, count(*) c from public.matches where division_stage_id = (select a1 from stg) group by 1) q), 'A:10 B:10 C:10 D:10', 'four brackets of 10 games each');
select is((select string_agg(group_label || ':' || n, ' ' order by group_label) from (select group_label, count(distinct e) n from (
  select group_label, entry_a_id e from public.matches where division_stage_id = (select a1 from stg) union all
  select group_label, entry_b_id from public.matches where division_stage_id = (select a1 from stg)) q group by 1) t), 'A:5 B:5 C:5 D:5', 'five players in each bracket');
select is((select count(*)::int from (select entry_a_id e from public.matches where division_stage_id = (select a1 from stg) union select entry_b_id from public.matches where division_stage_id = (select a1 from stg)) q), 20, 'all twenty are placed');
select is((select count(*)::int from (select entry_id from (
  select entry_a_id entry_id, group_label from public.matches where division_stage_id = (select a1 from stg) union select entry_b_id, group_label from public.matches where division_stage_id = (select a1 from stg)) q
  group by entry_id having count(distinct group_label) > 1) t), 0, 'nobody is in two brackets');
select is((select status from public.division_stages where id = (select a2 from stg)), 'pending', 'the knockout waits for the pools');
select is((select count(*)::int from public.matches where division_stage_id = (select a2 from stg)), 0, 'and has no matches yet');
select is((select count(*)::int from public.matches where division_stage_id = (select b1 from stg)), 9, 'nine entries in brackets of 3: 9 pool games');
select is((select count(distinct group_label)::int from public.matches where division_stage_id = (select b1 from stg)), 3, 'three brackets');
select is((select count(*)::int from public.matches where division_stage_id = (select c1 from stg)), 6, 'six entries in brackets of 3: 6 pool games');
select is((select count(distinct group_label)::int from public.matches where division_stage_id = (select c1 from stg)), 2, 'two brackets');

-- ---- play the pools: the lower number always wins
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

select pg_temp.play_stage((select a1 from stg));
select is((select status from public.division_stages where id = (select a1 from stg)), 'completed', 'the pools are complete');
select is((select status from public.division_stages where id = (select a2 from stg)), 'drawn', 'so the knockout is built');
select is((select count(*)::int from public.matches where division_stage_id = (select a2 from stg)), 7, 'with 7 matches: 4 quarterfinals, 2 semifinals, a final');
select is((select string_agg(round_no || ':' || c, ' ' order by round_no) from (select round_no, count(*) c from public.matches where division_stage_id = (select a2 from stg) group by 1) q), '1:4 2:2 3:1', 'round by round');
select is((select meta ->> 'crossover' from public.division_stages where id = (select a2 from stg)), 'paired_groups_same_rank', 'the club crossover rule was used');

-- the crossover: A1 v D1, A2 v D2, B1 v C1, B2 v C2, by finish in each bracket
create temp table fin as
  select group_label, place, entry_id from core.stage_standings((select a1 from stg)) where place <= 2;
grant select on fin to public;
select is((select count(*)::int from fin), 8, 'two advance from each bracket');
create function pg_temp.fin(g text, p int) returns text language sql as $$ select entry_id from fin where group_label = g and place = p $$;
grant execute on function pg_temp.fin(text, int) to public;
select is((select entry_a_id from public.matches where division_stage_id = (select a2 from stg) and round_no = 1 and match_no = 1), pg_temp.fin('A', 1), 'quarterfinal 1: A1 ...');
select is((select entry_b_id from public.matches where division_stage_id = (select a2 from stg) and round_no = 1 and match_no = 1), pg_temp.fin('D', 1), '... v D1');
select is((select entry_a_id from public.matches where division_stage_id = (select a2 from stg) and round_no = 1 and match_no = 2), pg_temp.fin('A', 2), 'quarterfinal 2: A2 ...');
select is((select entry_b_id from public.matches where division_stage_id = (select a2 from stg) and round_no = 1 and match_no = 2), pg_temp.fin('D', 2), '... v D2');
select is((select entry_a_id from public.matches where division_stage_id = (select a2 from stg) and round_no = 1 and match_no = 3), pg_temp.fin('B', 1), 'quarterfinal 3: B1 ...');
select is((select entry_b_id from public.matches where division_stage_id = (select a2 from stg) and round_no = 1 and match_no = 3), pg_temp.fin('C', 1), '... v C1');
select is((select entry_a_id from public.matches where division_stage_id = (select a2 from stg) and round_no = 1 and match_no = 4), pg_temp.fin('B', 2), 'quarterfinal 4: B2 ...');
select is((select entry_b_id from public.matches where division_stage_id = (select a2 from stg) and round_no = 1 and match_no = 4), pg_temp.fin('C', 2), '... v C2');
select is((select a_label || ' v ' || b_label from public.stage_matches((select a2 from stg)) where round_no = 1 and match_no = 1), 'A1 v D1', 'the crossover table says where each side came from');
select is((select feeds_match_id from public.matches where division_stage_id = (select a2 from stg) and round_no = 1 and match_no = 1),
  (select feeds_match_id from public.matches where division_stage_id = (select a2 from stg) and round_no = 1 and match_no = 2), 'quarterfinals 1 and 2 meet in the same semifinal');
select is((select feeds_match_id from public.matches where division_stage_id = (select a2 from stg) and round_no = 1 and match_no = 3),
  (select feeds_match_id from public.matches where division_stage_id = (select a2 from stg) and round_no = 1 and match_no = 4), 'and 3 and 4 in the other');

select pg_temp.play_stage((select a2 from stg));
select pg_temp.play_stage((select a2 from stg));
select pg_temp.play_stage((select a2 from stg));
select is((select winner_entry_id from public.matches where division_stage_id = (select a2 from stg) and round_no = 3), (select entry from ent where role = 'p1' and division_id = (select dvA from fx)), 'the strongest player wins the knockout');
select is((select status from public.division_stages where id = (select a2 from stg)), 'completed', 'the knockout completes');
select is((select count(*)::int from public.matches m join public.division_stages s on s.id = m.division_stage_id where s.division_id = (select dvA from fx) and m.status = 'completed'), 47, 'the club example: 47 games in all');

-- ---- six entries: two brackets, a four-player crossover
select pg_temp.play_stage((select c1 from stg));
select is((select count(*)::int from public.matches where division_stage_id = (select c2 from stg)), 3, 'six entries: two semifinals and a final');
select is((select meta ->> 'crossover' from public.division_stages where id = (select c2 from stg)), 'paired_groups_same_rank', 'by the club rule');
select is((select a_label || ' v ' || b_label from public.stage_matches((select c2 from stg)) where round_no = 1 and match_no = 1), 'A1 v B1', 'A1 v B1 ...');
select is((select a_label || ' v ' || b_label from public.stage_matches((select c2 from stg)) where round_no = 1 and match_no = 2), 'A2 v B2', '... and A2 v B2');
select pg_temp.play_stage((select c2 from stg));
select pg_temp.play_stage((select c2 from stg));
select is((select winner_entry_id from public.matches where division_stage_id = (select c2 from stg) and round_no = 2), (select entry from ent where role = 'p1' and division_id = (select dvC from fx)), 'and the strongest wins it');

-- ---- nine entries: three brackets do not fit the rule, so a seeded bracket is built and flagged
select pg_temp.play_stage((select b1 from stg));
select is((select count(*)::int from public.matches where division_stage_id = (select b2 from stg)), 5, 'nine entries: six advance into a 5-match seeded bracket');
select is((select meta ->> 'crossover' from public.division_stages where id = (select b2 from stg)), 'seeded_fallback', 'and the stage says it is a fallback');
select is((select count(*)::int from public.matches where division_stage_id = (select b2 from stg) and round_no = 1), 2, 'two first-round matches, two byes');
select pg_temp.play_stage((select b2 from stg));
select pg_temp.play_stage((select b2 from stg));
select pg_temp.play_stage((select b2 from stg));
select is((select winner_entry_id from public.matches where division_stage_id = (select b2 from stg) and round_no = 3), (select entry from ent where role = 'p1' and division_id = (select dvB from fx)), 'the strongest wins that too');
select ok(exists (select 1 from core.audit_log where action = 'stage.crossover' and record_id = (select a2 from stg)), 'the crossover is audited');

select * from finish();
rollback;
