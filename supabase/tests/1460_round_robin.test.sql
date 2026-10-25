begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

-- ---- the schedule itself: every pair once, nobody twice in a round, for several sizes
create temp table sizes(n int);
insert into sizes select generate_series(2, 9);
select is((select count(*)::int from (
  select s.n from sizes s where (select count(*) from core.rr_schedule((select array_agg('e' || i) from generate_series(1, s.n) i))) <> s.n * (s.n - 1) / 2) bad), 0,
  'each size from 2 to 9 gets n(n-1)/2 matches');
select is((select count(*)::int from (
  select s.n from sizes s where (select count(*) from (select distinct least(a, b), greatest(a, b) from core.rr_schedule((select array_agg('e' || i) from generate_series(1, s.n) i))) d) <> s.n * (s.n - 1) / 2) bad), 0,
  'and every pair meets exactly once');
select is((select count(*)::int from (
  select s.n from sizes s where exists (
    select 1 from (select round_no, x, count(*) c from core.rr_schedule((select array_agg('e' || i) from generate_series(1, s.n) i)) r, lateral (values (r.a), (r.b)) v(x) group by 1, 2) t where t.c > 1)) bad), 0,
  'nobody plays twice in a round');
select is((select count(distinct round_no)::int from core.rr_schedule(array['a', 'b', 'c', 'd'])), 3, 'four entries take 3 rounds');
select is((select count(distinct round_no)::int from core.rr_schedule(array['a', 'b', 'c', 'd', 'e'])), 5, 'five entries take 5 rounds, one resting each time');
select is((select count(*)::int from core.rr_schedule(array['solo'])), 0, 'one entry has no matches');

-- ---- a real tournament
create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as ev, core.ulid() as dvA, core.ulid() as dvB,
  core.ulid() as g1, core.ulid() as g2, core.ulid() as g3, core.ulid() as g4, core.ulid() as g5,
  core.ulid() as h1, core.ulid() as h2, core.ulid() as h3, core.ulid() as h4,
  (select id from public.format_templates where lower(name) = 'round robin' and deleted_at is null) as tpl,
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
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2026-97101', false), null, null;
insert into us select 'ref', pg_temp.mk('referee', 'CPC-2026-97102', false), null, null;
insert into us select 'outsider', pg_temp.mk('member', 'CPC-2026-97103', false), null, null;
insert into us select 'p1', pg_temp.mk('member', 'CPC-2026-97111', true), null, 1;
insert into us select 'p2', pg_temp.mk('member', 'CPC-2026-97112', true), null, 2;
insert into us select 'p3', pg_temp.mk('member', 'CPC-2026-97113', true), null, 3;
insert into us select 'p4', pg_temp.mk('member', 'CPC-2026-97114', true), null, 4;
insert into us select 'p5', pg_temp.mk('member', 'CPC-2026-97115', true), null, 5;
update us set mid = (select m.id from public.members m join public.profiles p on p.id = m.profile_id where p.auth_user_id = us.u);

select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.create_event((select ev from fx), 'Round Robin Test', (select day1 from fx), (select day1 from fx), 'Hall', 0, null, null);
select public.create_division((select dvA from fx), (select ev from fx), 'Five Players', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.create_division((select dvB from fx), (select ev from fx), 'Four Players', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.set_event_status((select ev from fx), 'registration_open', null);
reset role;
update public.settings set value = 'false'::jsonb where key = 'events.registration_approval_required' and unit_id is null and deleted_at is null;
select pg_temp.as_user((select u from us where role = 'p1')); set local role authenticated;
select public.register_for_event((select g1 from fx), (select dvA from fx)); select public.register_for_event((select h1 from fx), (select dvB from fx)); reset role;
select pg_temp.as_user((select u from us where role = 'p2')); set local role authenticated;
select public.register_for_event((select g2 from fx), (select dvA from fx)); select public.register_for_event((select h2 from fx), (select dvB from fx)); reset role;
select pg_temp.as_user((select u from us where role = 'p3')); set local role authenticated;
select public.register_for_event((select g3 from fx), (select dvA from fx)); select public.register_for_event((select h3 from fx), (select dvB from fx)); reset role;
select pg_temp.as_user((select u from us where role = 'p4')); set local role authenticated;
select public.register_for_event((select g4 from fx), (select dvA from fx)); select public.register_for_event((select h4 from fx), (select dvB from fx)); reset role;
select pg_temp.as_user((select u from us where role = 'p5')); set local role authenticated;
select public.register_for_event((select g5 from fx), (select dvA from fx)); reset role;

create temp table stg as select (select id from public.division_stages where division_id = (select dvA from fx)) as sA,
  (select id from public.division_stages where division_id = (select dvB from fx)) as sB;
grant select on stg to public;

select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.set_event_status((select ev from fx), 'registration_closed', null);
select public.run_draw((select sA from stg));
select public.run_draw((select sB from stg));
reset role;

create temp table ent as
  select u.role, u.strength, e.id as entry, e.division_id from us u
  join public.entry_members em on em.member_id = u.mid join public.entries e on e.id = em.entry_id where u.strength is not null;
grant select on ent to public;

-- ---- the draw builds the matches
select is((select count(*)::int from public.matches where division_stage_id = (select sA from stg) and status = 'scheduled'), 10, 'five players: 10 matches');
select is((select count(*)::int from public.matches where division_stage_id = (select sB from stg) and status = 'scheduled'), 6, 'four players: 6 matches');
select is((select count(distinct least(entry_a_id, entry_b_id) || greatest(entry_a_id, entry_b_id))::int from public.matches where division_stage_id = (select sA from stg)), 10, 'every pair of the five meets once');
select is((select min(c)::int || '-' || max(c)::int from (select e, count(*) c from (select entry_a_id e from public.matches where division_stage_id = (select sA from stg) union all select entry_b_id from public.matches where division_stage_id = (select sA from stg)) q group by e) t), '4-4', 'and each plays four matches');
select is((select count(*)::int from public.matches where division_stage_id = (select sA from stg) and group_label is not null), 0, 'a round robin has no groups');

-- ---- a redo rebuilds them from the new draw
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.redo_draw((select sA from stg), 'Rebuild test', core.ulid());
reset role;
select is((select count(*)::int from public.matches where division_stage_id = (select sA from stg) and status = 'scheduled'), 10, 'after a redo there are again 10 live matches');
select is((select count(*)::int from public.matches where division_stage_id = (select sA from stg) and status = 'void'), 10, 'and the earlier 10 are voided');

-- ---- members see the matches with names once drawn
select pg_temp.as_user((select u from us where role = 'outsider')); set local role authenticated;
select is((select count(*)::int from public.stage_matches((select sA from stg))), 10, 'a member can list the matches');
select ok((select bool_and(a_name is not null and b_name is not null) from public.stage_matches((select sA from stg))), 'with the names of both sides');
reset role;

-- ---- play: the lower number always wins 11-5
select pg_temp.as_user((select u from us where role = 'ref')); set local role authenticated;
select public.enter_score(m.id, case when (select strength from ent where entry = m.entry_a_id) < (select strength from ent where entry = m.entry_b_id)
    then '[{"a":11,"b":5}]'::jsonb else '[{"a":5,"b":11}]'::jsonb end)
  from public.matches m where m.division_stage_id = (select sA from stg) and m.status = 'scheduled' and m.round_no = 1 and m.match_no = 1;
reset role;
select is((select status from public.division_stages where id = (select sA from stg)), 'in_progress', 'the first score starts the stage');
select is((select status from public.divisions where id = (select dvA from fx)), 'in_progress', 'and the division');
select is((select status from public.events where id = (select ev from fx)), 'in_progress', 'and the event');
select is((select status from public.division_stages where id = (select sB from stg)), 'drawn', 'another division is untouched');

select pg_temp.as_user((select u from us where role = 'ref')); set local role authenticated;
select public.enter_score(m.id, case when (select strength from ent where entry = m.entry_a_id) < (select strength from ent where entry = m.entry_b_id)
    then '[{"a":11,"b":5}]'::jsonb else '[{"a":5,"b":11}]'::jsonb end)
  from public.matches m where m.division_stage_id in ((select sA from stg), (select sB from stg)) and m.status = 'scheduled';
select public.finalize_match(m.id) from public.matches m where m.division_stage_id = (select sA from stg) and m.status = 'in_progress' and m.id <> (
  select id from public.matches where division_stage_id = (select sA from stg) and status = 'in_progress' order by round_no desc, match_no desc limit 1);
reset role;
select is((select status from public.division_stages where id = (select sA from stg)), 'in_progress', 'with one match still to finalize the stage is not complete');
select pg_temp.as_user((select u from us where role = 'ref')); set local role authenticated;
select public.finalize_match(m.id) from public.matches m where m.division_stage_id = (select sA from stg) and m.status = 'in_progress';
reset role;
select is((select status from public.division_stages where id = (select sA from stg)), 'completed', 'the last result completes the stage');
select is((select status from public.divisions where id = (select dvA from fx)), 'in_progress', 'the division waits for its finalization');

-- ---- standings for five players
select is((select array_agg(wins order by place) from core.stage_standings((select sA from stg))), array[4, 3, 2, 1, 0], 'five players: wins 4, 3, 2, 1, 0');
select is((select array_agg(place order by place) from core.stage_standings((select sA from stg))), array[1, 2, 3, 4, 5], 'places 1 to 5');
select is((select array_agg(entry_id order by place) from core.stage_standings((select sA from stg))),
  (select array_agg(entry order by strength) from ent where division_id = (select dvA from fx)), 'in order of strength');
select is((select bool_and(played = 4) from core.stage_standings((select sA from stg))), true, 'each played four');
select is((select points_for from core.stage_standings((select sA from stg)) where place = 1), 44, 'the leader scored 4 x 11');
select is((select points_for from core.stage_standings((select sA from stg)) where place = 5), 20, 'the last scored 4 x 5');
select is((select sum(games_won) = sum(games_lost) from core.stage_standings((select sA from stg)))::text, 'true', 'games won equal games lost across the table');

-- ---- four players, one result by forfeit
select pg_temp.as_user((select u from us where role = 'ref')); set local role authenticated;
select public.finalize_match(m.id) from public.matches m where m.division_stage_id = (select sB from stg) and m.status = 'in_progress' and not (
  least((select strength from ent where entry = m.entry_a_id), (select strength from ent where entry = m.entry_b_id)) = 3
  and greatest((select strength from ent where entry = m.entry_a_id), (select strength from ent where entry = m.entry_b_id)) = 4);
reset role;
select is((select status from public.division_stages where id = (select sB from stg)), 'in_progress', 'the stage waits for the last match');
select pg_temp.as_user((select u from us where role = 'ref')); set local role authenticated;
select public.forfeit_match(m.id, (select entry from ent where role = 'p4' and division_id = (select dvB from fx)), 'Did not turn up')
  from public.matches m where m.division_stage_id = (select sB from stg) and m.status = 'in_progress'
    and (select entry from ent where role = 'p4' and division_id = (select dvB from fx)) in (m.entry_a_id, m.entry_b_id)
    and (select entry from ent where role = 'p3' and division_id = (select dvB from fx)) in (m.entry_a_id, m.entry_b_id);
reset role;
select is((select status from public.division_stages where id = (select sB from stg)), 'completed', 'a forfeit completes the stage too');
select is((select array_agg(wins order by place) from core.stage_standings((select sB from stg))), array[3, 2, 1, 0], 'four players: wins 3, 2, 1, 0');
select is((select array_agg(entry_id order by place) from core.stage_standings((select sB from stg))),
  (select array_agg(entry order by strength) from ent where division_id = (select dvB from fx)), 'in order of strength');
select is((select count(*)::int from public.matches where division_stage_id = (select sB from stg) and status = 'forfeited'), 1, 'one match was a forfeit');

select * from finish();
rollback;
