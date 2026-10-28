begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

-- ---- the bracket order and the layout, for many sizes
select is(core.se_slots(2), array[1, 2], 'a bracket of 2: 1 v 2');
select is(core.se_slots(4), array[1, 4, 2, 3], 'a bracket of 4: 1 v 4, 2 v 3');
select is(core.se_slots(8), array[1, 8, 4, 5, 2, 7, 3, 6], 'a bracket of 8: 1 v 8, 4 v 5, 2 v 7, 3 v 6');
select is((core.se_slots(16))[1:4], array[1, 16, 8, 9], 'and of 16 starts 1 v 16, 8 v 9');
select throws_ok($$select core.se_slots(6)$$, '22023', null, 'only a power of two');

create temp table sizes(n int);
insert into sizes select generate_series(2, 33);
select is((select count(*)::int from sizes s where (select count(*) from core.se_layout(s.n)) <> s.n - 1), 0, 'every size from 2 to 33 has n-1 matches');
select is((select count(*)::int from sizes s where (select max(round_no) from core.se_layout(s.n)) <> ceil(log(2, s.n))::int), 0, 'and ceil(log2 n) rounds');
select is((select count(*)::int from sizes s where (select count(*) from core.se_layout(s.n) where round_no = 1) <> s.n - (select 2 ^ ceil(log(2, s.n)) / 2)::int), 0, 'round 1 has n minus half the bracket matches: the rest are byes');
select is((select count(*)::int from sizes s where (select count(*) from core.se_layout(s.n) where round_no = (select max(round_no) from core.se_layout(s.n))) <> 1), 0, 'one final');
-- every seed is placed exactly once: in a round-1 match or by a bye into round 2
select is((select count(*)::int from sizes s where (
  select count(distinct x) from (
    select seed_a x from core.se_layout(s.n) where round_no <= 2 and seed_a is not null
    union all select seed_b from core.se_layout(s.n) where round_no <= 2 and seed_b is not null) q) <> s.n), 0, 'every seed is placed once, by match or by bye');
-- the best seeds get the byes
select is((select array_agg(seed_a order by match_no) from core.se_layout(6) where round_no = 2 and seed_a is not null), array[1, 2]::int[], '6 entries: seeds 1 and 2 have byes');
select is((select count(*)::int from core.se_layout(5) where round_no = 2 and seed_a is not null) + (select count(*)::int from core.se_layout(5) where round_no = 2 and seed_b is not null), 3, '5 entries: three byes');
select is((select seed_a || 'v' || seed_b from core.se_layout(5) where round_no = 1), '4v5', '5 entries: the only first-round match is 4 v 5');
select is((select feeds_round || '/' || feeds_match || '/' || slot from core.se_layout(8) where round_no = 1 and match_no = 3), '2/2/a', 'match 3 of round 1 feeds slot a of match 2');
select is((select feeds_round || '/' || feeds_match || '/' || slot from core.se_layout(8) where round_no = 1 and match_no = 4), '2/2/b', 'and match 4 feeds slot b of the same match');

-- ---- real brackets
-- the seeded "Single elimination" template was retired (migration 1860), so this suite brings its own
create temp table tpl1470 as select core.ulid() as id;
grant select on tpl1470 to public;
insert into public.format_templates (id, org_id, name, stages)
values ((select id from tpl1470), (select id from public.orgs where code = 'cpc'), 'T Knockout 1470',
  '[{"stage_type": "single_elimination", "config": {"third_place_game": false}}]'::jsonb);
create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as ev, core.ulid() as dvA, core.ulid() as dvB,
  core.ulid() as a1, core.ulid() as a2, core.ulid() as a3, core.ulid() as a4, core.ulid() as a5, core.ulid() as a6, core.ulid() as a7, core.ulid() as a8,
  core.ulid() as b1, core.ulid() as b2, core.ulid() as b3, core.ulid() as b4, core.ulid() as b5,
  (select id from tpl1470) as tpl,
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
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2026-97201', false), null, null;
insert into us select 'ref', pg_temp.mk('referee', 'CPC-2026-97202', false), null, null;
insert into us select 'p' || i, pg_temp.mk('member', 'CPC-2026-9721' || i, true), null, i from generate_series(1, 8) i;
update us set mid = (select m.id from public.members m join public.profiles p on p.id = m.profile_id where p.auth_user_id = us.u);

select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.create_event((select ev from fx), 'Knockout Test', (select day1 from fx), (select day1 from fx), 'Hall', 0, null, null);
select public.create_division((select dvA from fx), (select ev from fx), 'Eight Players', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.create_division((select dvB from fx), (select ev from fx), 'Five Players', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.set_event_status((select ev from fx), 'registration_open', null);
reset role;
update public.settings set value = 'false'::jsonb where key = 'events.registration_approval_required' and unit_id is null and deleted_at is null;
create function pg_temp.join_div(p_role text, p_id text, p_div text) returns void language plpgsql as $$
begin
  perform pg_temp.as_user((select u from us where role = p_role));
  set local role authenticated;
  perform public.register_for_event(p_id, p_div);
  reset role;
end $$;
grant execute on function pg_temp.join_div(text, text, text) to public;
select pg_temp.join_div('p1', (select a1 from fx), (select dvA from fx)); select pg_temp.join_div('p2', (select a2 from fx), (select dvA from fx));
select pg_temp.join_div('p3', (select a3 from fx), (select dvA from fx)); select pg_temp.join_div('p4', (select a4 from fx), (select dvA from fx));
select pg_temp.join_div('p5', (select a5 from fx), (select dvA from fx)); select pg_temp.join_div('p6', (select a6 from fx), (select dvA from fx));
select pg_temp.join_div('p7', (select a7 from fx), (select dvA from fx)); select pg_temp.join_div('p8', (select a8 from fx), (select dvA from fx));
select pg_temp.join_div('p1', (select b1 from fx), (select dvB from fx)); select pg_temp.join_div('p2', (select b2 from fx), (select dvB from fx));
select pg_temp.join_div('p3', (select b3 from fx), (select dvB from fx)); select pg_temp.join_div('p4', (select b4 from fx), (select dvB from fx));
select pg_temp.join_div('p5', (select b5 from fx), (select dvB from fx));

create temp table stg as select (select id from public.division_stages where division_id = (select dvA from fx)) as sA,
  (select id from public.division_stages where division_id = (select dvB from fx)) as sB;
grant select on stg to public;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.set_event_status((select ev from fx), 'registration_closed', null);
select public.run_draw((select sA from stg));
select public.run_draw((select sB from stg));
reset role;
create temp table ent as
  select u.role, u.strength, e.id as entry, e.division_id, e.seed from us u
  join public.entry_members em on em.member_id = u.mid join public.entries e on e.id = em.entry_id where u.strength is not null;
grant select on ent to public;

-- ---- the draw builds the bracket
select is((select count(*)::int from public.matches where division_stage_id = (select sA from stg)), 7, 'eight players: 7 matches');
select is((select string_agg(round_no || ':' || c, ' ' order by round_no) from (select round_no, count(*) c from public.matches where division_stage_id = (select sA from stg) group by 1) q), '1:4 2:2 3:1', 'four, two and one per round');
select is((select array_agg(least(x.seed, y.seed) || 'v' || greatest(x.seed, y.seed) order by least(x.seed, y.seed))
  from public.matches m join ent x on x.entry = m.entry_a_id join ent y on y.entry = m.entry_b_id where m.division_stage_id = (select sA from stg) and m.round_no = 1),
  array['1v8', '2v7', '3v6', '4v5'], 'round 1 follows the draw seeds: 1 v 8, 2 v 7, 3 v 6, 4 v 5');
select is((select count(*)::int from public.matches where division_stage_id = (select sA from stg) and round_no > 1 and (entry_a_id is not null or entry_b_id is not null)), 0, 'later rounds wait for the winners');
select is((select count(*)::int from public.matches where division_stage_id = (select sA from stg) and round_no < 3 and feeds_match_id is null), 0, 'every match before the final feeds another');
select is((select count(*)::int from public.matches where division_stage_id = (select sB from stg)), 4, 'five players: 4 matches');
select is((select count(*)::int from public.matches where division_stage_id = (select sB from stg) and round_no = 1), 1, 'only one first-round match, the others have byes');
select is((select least(x.seed, y.seed) || 'v' || greatest(x.seed, y.seed) from public.matches m join ent x on x.entry = m.entry_a_id join ent y on y.entry = m.entry_b_id
  where m.division_stage_id = (select sB from stg) and m.round_no = 1), '4v5', 'it is seed 4 v seed 5');
select is((select count(*)::int from public.matches where division_stage_id = (select sB from stg) and round_no = 2 and entry_a_id is not null and entry_b_id is not null), 1, 'the seeds that met a bye wait in round 2: 2 v 3 is already set');

-- ---- a redo rebuilds the bracket
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.redo_draw((select sB from stg), 'Rebuild test', core.ulid());
reset role;
select is((select count(*)::int from public.matches where division_stage_id = (select sB from stg) and status = 'scheduled'), 4, 'after a redo there are 4 live matches');
select is((select count(*)::int from public.matches where division_stage_id = (select sB from stg) and status = 'void'), 4, 'and the old 4 are voided');
-- entries were renumbered by the redo
delete from ent where division_id = (select dvB from fx);
insert into ent select u.role, u.strength, e.id, e.division_id, e.seed from us u join public.entry_members em on em.member_id = u.mid join public.entries e on e.id = em.entry_id
  where u.strength is not null and e.division_id = (select dvB from fx);

-- ---- play every round: the lower number always wins, winners move on
create function pg_temp.play_round(p_stage text, p_round int) returns void language plpgsql as $$
begin
  perform pg_temp.as_user((select u from us where role = 'ref'));
  set local role authenticated;
  perform public.enter_score(m.id, case when (select strength from ent where entry = m.entry_a_id) < (select strength from ent where entry = m.entry_b_id)
      then '[{"a":11,"b":4}]'::jsonb else '[{"a":4,"b":11}]'::jsonb end)
    from public.matches m where m.division_stage_id = p_stage and m.round_no = p_round and m.status = 'scheduled' and m.entry_a_id is not null and m.entry_b_id is not null;
  perform public.finalize_match(m.id) from public.matches m where m.division_stage_id = p_stage and m.round_no = p_round and m.status = 'in_progress';
  reset role;
end $$;
grant execute on function pg_temp.play_round(text, int) to public;

select pg_temp.play_round((select sA from stg), 1);
select is((select count(*)::int from public.matches where division_stage_id = (select sA from stg) and round_no = 2 and entry_a_id is not null and entry_b_id is not null), 2, 'round 1 over: both semifinals have their players');
select is((select status from public.division_stages where id = (select sA from stg)), 'in_progress', 'the stage is under way');
select pg_temp.play_round((select sA from stg), 2);
select is((select count(*)::int from public.matches where division_stage_id = (select sA from stg) and round_no = 3 and entry_a_id is not null and entry_b_id is not null), 1, 'round 2 over: the final is set');
select is((select status from public.division_stages where id = (select sA from stg)), 'in_progress', 'but the stage is not complete before the final');
select pg_temp.play_round((select sA from stg), 3);
select is((select winner_entry_id from public.matches where division_stage_id = (select sA from stg) and round_no = 3), (select entry from ent where role = 'p1' and division_id = (select dvA from fx)), 'the strongest player is champion');
select is((select status from public.division_stages where id = (select sA from stg)), 'completed', 'the final completes the stage');
select is((select count(*)::int from public.matches where division_stage_id = (select sA from stg) and status = 'completed'), 7, 'all 7 matches were played');

select pg_temp.play_round((select sB from stg), 1);
select pg_temp.play_round((select sB from stg), 2);
select pg_temp.play_round((select sB from stg), 3);
select is((select winner_entry_id from public.matches where division_stage_id = (select sB from stg) and round_no = 3 and status <> 'void'), (select entry from ent where role = 'p1' and division_id = (select dvB from fx)), 'five players: the strongest wins the bracket');
select is((select status from public.division_stages where id = (select sB from stg)), 'completed', 'and the stage completes');
select is((select count(*)::int from public.matches where division_stage_id = (select sB from stg) and status = 'completed'), 4, 'with 4 matches played');

select * from finish();
rollback;
