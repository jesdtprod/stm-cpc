begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create temp table chain as select * from core.rank_chain((select id from public.orgs where code = 'cpc'));
grant select on chain to public;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as ev, core.ulid() as dv,
  core.ulid() as k1, core.ulid() as k2, core.ulid() as k3, core.ulid() as k4,
  (select id from public.format_templates where lower(name) like 'split single elimination%' and deleted_at is null) as tpl,
  (select id from public.categories where code = 'novice' and deleted_at is null) as cat_novice,
  (select r.id from public.ranks r join public.rank_ladders l on l.id = r.ladder_id join public.categories c on c.id = l.category_id
    where c.code = 'novice' and r.deleted_at is null order by r.sort_order desc limit 1) as novice_top,
  current_date + 30 as day1;
grant select on fx to public;
create temp table rk as select
  (select novice_top from fx) as top,
  core.rank_move((select novice_top from fx), 1) as up1,
  core.rank_move((select novice_top from fx), -1) as down1,
  core.rank_move((select novice_top from fx), 2) as up2;
grant select on rk to public;

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
    insert into public.member_ranks (org_id, member_id, rank_id) values (org, mid, (select novice_top from fx));
  end if;
  return u;
end $$;
create temp table us(role text primary key, u uuid, mid text, strength int);
grant select on us to public;
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2033-98501', true), null, null;
insert into us select 'ref', pg_temp.mk('referee', 'CPC-2033-98502', false), null, null;
insert into us select 'outsider', pg_temp.mk('member', 'CPC-2033-98503', false), null, null;
insert into us select 'p' || i, pg_temp.mk('member', 'CPC-2033-9851' || i, true), null, i from generate_series(1, 8) i;
update us set mid = (select m.id from public.members m join public.profiles p on p.id = m.profile_id where p.auth_user_id = us.u);

select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.create_event((select ev from fx), 'Correction Test', (select day1 from fx), (select day1 from fx), 'Hall', 0, null, null);
select public.create_division((select dv from fx), (select ev from fx), 'Split Eight', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
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
select pg_temp.join_div('p' || i, (select dv from fx)) from generate_series(1, 8) i;
create temp table stg as select (select id from public.division_stages where division_id = (select dv from fx)) as s;
grant select on stg to public;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.set_event_status((select ev from fx), 'registration_closed', null);
reset role;
-- activation, and assessed starting points for the players (p8 left unrated on purpose)
-- the activation guard needs every active member prepared (unrated rows), as the real flow does
insert into public.member_cpc_ratings (org_id, unit_id, member_id, discipline)
select m.org_id, m.unit_id, m.id, d.discipline from public.members m cross join (values ('singles'), ('doubles')) d(discipline)
where m.deleted_at is null and m.status = 'active'
  and not exists (select 1 from public.member_cpc_ratings r where r.member_id = m.id and r.discipline = d.discipline and r.deleted_at is null);
update public.settings set value = 'true'::jsonb where key = 'ranks.cpc_points_enabled' and unit_id is null and deleted_at is null;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.set_member_cpc_rating((select mid from us where role = 'p' || i), 'singles', 2.900, coalesce((select version from public.member_cpc_ratings where discipline = 'singles' and member_id = (select mid from us where role = 'p' || i) and deleted_at is null), 0), core.ulid(), 'Fake assessed start') from generate_series(1, 7) i;
select throws_ok(format('select public.run_draw(%L)', (select s from stg)), '22023', null, 'a points-rated division cannot be drawn while a player is unrated');
select isnt((select status from public.divisions where id = (select dv from fx)), 'drawn', 'the failed draw left the division undrawn');
select public.set_member_cpc_rating((select mid from us where role = 'p8'), 'singles', 2.900, coalesce((select version from public.member_cpc_ratings where discipline = 'singles' and member_id = (select mid from us where role = 'p8') and deleted_at is null), 0), core.ulid(), 'Fake assessed start');
reset role;
-- p8 (the weakest, who loses every match) already has four eligible matches, so the second match of this division uses the established factor
update public.member_cpc_ratings set eligible_match_count = 4 where discipline = 'singles' and member_id = (select mid from us where role = 'p8') and deleted_at is null;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.run_draw((select s from stg));
reset role;
select is((select count(*)::int from public.division_cpc_rating_snapshots where division_id = (select dv from fx)), 8, 'the draw froze eight player inputs');
create temp table ent as
  select u.role, u.strength, e.id as entry from us u
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
create function pg_temp.final_of(g text) returns text language sql as $$
  select id from public.matches where division_stage_id = (select s from stg) and group_label = g and status <> 'void'
    and round_no = (select max(round_no) from public.matches where division_stage_id = (select s from stg) and group_label = g and status <> 'void')
$$;
grant execute on function pg_temp.final_of(text) to public;
-- games in which the weaker side wins the given match
create function pg_temp.upset(p_match text) returns jsonb language sql as $$
  select case when (select strength from ent where entry = m.entry_a_id) > (select strength from ent where entry = m.entry_b_id)
    then '[{"a":11,"b":5}]'::jsonb else '[{"a":5,"b":11}]'::jsonb end from public.matches m where m.id = p_match
$$;
grant execute on function pg_temp.upset(text) to public;

-- the same winner with a different score
create function pg_temp.same_winner(p_match text) returns jsonb language sql as $$
  select case when m.winner_entry_id = m.entry_a_id then '[{"a":11,"b":8}]'::jsonb else '[{"a":8,"b":11}]'::jsonb end from public.matches m where m.id = p_match
$$;
grant execute on function pg_temp.same_winner(text) to public;
select pg_temp.play_stage((select s from stg));
select pg_temp.play_stage((select s from stg));
select pg_temp.play_stage((select s from stg));
create function pg_temp.pts(p_entry text) returns numeric language sql as $$
  select r.points from public.member_cpc_ratings r join public.entry_members em on em.member_id = r.member_id
  where em.entry_id = p_entry and r.deleted_at is null and r.discipline = 'singles' $$;
grant execute on function pg_temp.pts(text) to public;
create function pg_temp.rank_code_of(p_entry text) returns text language sql as $$
  select k.code from public.member_ranks mr join public.entry_members em on em.member_id = mr.member_id
  join public.ranks k on k.id = mr.rank_id where em.entry_id = p_entry and mr.deleted_at is null $$;
grant execute on function pg_temp.rank_code_of(text) to public;
select is((select count(*)::int from public.member_cpc_ratings r where r.deleted_at is null and r.member_id in (select mid from us where mid is not null) and r.points <> 2.900), 0, 'nobody gains points before the division is finalized');

select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.finalize_division((select dv from fx));
reset role;
create temp table champ as select
  (select winner_entry_id from public.matches where id = pg_temp.final_of('H')) as h_champ,
  (select case when winner_entry_id = entry_a_id then entry_b_id else entry_a_id end from public.matches where id = pg_temp.final_of('H')) as h_second,
  (select winner_entry_id from public.matches where id = pg_temp.final_of('L')) as l_champ,
  (select case when winner_entry_id = entry_a_id then entry_b_id else entry_a_id end from public.matches where id = pg_temp.final_of('L')) as l_second;
grant select on champ to public;
-- equal 2.900 teams and 11-4 results: a provisional win is +0.0467 and a loss -0.0467
select is(pg_temp.pts((select h_champ from champ)), 3.040::numeric, 'H champion: three provisional wins give 3.040');
select is(pg_temp.pts((select h_second from champ)), 2.947::numeric, 'H runner-up: two wins and a loss give 2.947');
select is(pg_temp.pts((select l_champ from champ)), 2.947::numeric, 'L champion: a loss then two wins gives 2.947');
select is(pg_temp.pts((select l_second from champ)), 2.853::numeric, 'L runner-up: loss, win, loss gives 2.853');
select is((select r.eligible_match_count from public.member_cpc_ratings r where r.member_id = (select em.member_id from public.entry_members em where em.entry_id = (select h_champ from champ)) and r.deleted_at is null and r.discipline = 'singles'), 3, 'the played-match count grows by the matches played');
select is(pg_temp.pts((select entry from ent where role = 'p8')), 2.830::numeric, 'a player at four prior matches gets 0.2 then 0.1: 2.900 - 0.0467 - 0.0233 = 2.830');
select is((select r.eligible_match_count from public.member_cpc_ratings r where r.member_id = (select mid from us where role = 'p8') and r.deleted_at is null and r.discipline = 'singles'), 6, 'and has six matches, each counted once');
select is(pg_temp.rank_code_of((select h_champ from champ)), 'intermediate-low', 'the rank follows the points: 3.040 is Intermediate Low');
select is(pg_temp.rank_code_of((select l_second from champ)), 'novice-high', 'a player staying inside the band keeps the rank (2.853)');
select is((select count(*)::int from public.member_cpc_rating_history where division_id = (select dv from fx) and entry_type = 'division_finalization'), 8, 'one points history row for each player');
select is((select count(*)::int from public.rank_history where division_id = (select dv from fx)), 8, 'and one rank history row for each player');
select is((select count(*)::int from public.rank_history where division_id = (select dv from fx) and rule_id is not null), 0, 'no H/L rule moved anyone');
select is((select count(*)::int from public.division_results where division_id = (select dv from fx) and superseded_at is null), 8, 'placements are still recorded');

-- ---- finalizing again changes nothing
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select is((select public.finalize_division((select dv from fx)) ->> 'unchanged'), 'true', 'finalizing twice is a no-op');
reset role;
select is((select count(*)::int from public.member_cpc_rating_history where division_id = (select dv from fx)), 8, 'no duplicate points history');
select is(pg_temp.pts((select h_champ from champ)), 3.040::numeric, 'and no duplicate points');

-- ---- a score-only correction (same winner) is evaluated
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
create temp table c0 as select public.correct_match(pg_temp.final_of('H'), 'Score typed wrongly', pg_temp.same_winner(pg_temp.final_of('H'))) as r;
reset role;
grant select on c0 to public;
select is((select r -> 'ranks' ->> 'changed' from c0), 'true', 'a corrected score with the same winner is re-evaluated');
select is((select (r -> 'ranks' ->> 'reversed')::int from c0), 2, 'only the two players of that match are reversed');
select is((select (r -> 'ranks' ->> 'unchanged')::int from c0), 6, 'the other six are unchanged');
select is(pg_temp.pts((select h_champ from champ)), 3.009::numeric, 'the champion now has 3.009 (11-8 in the final)');
select is(pg_temp.pts((select h_second from champ)), 2.978::numeric, 'the runner-up has 2.978 (8-11 in the final)');
select is((select count(*)::int from public.division_results where division_id = (select dv from fx) and superseded_at is not null), 0, 'placements did not change, so the results stay');
select is((select count(*)::int from public.member_cpc_rating_history where division_id = (select dv from fx) and entry_type = 'reversal'), 2, 'two reversing points rows');
select is((select count(*)::int from public.member_cpc_rating_history where division_id = (select dv from fx) and entry_type = 'division_finalization'), 10, 'and two replacement rows (history is append-only)');

-- ---- a later administrator assessment is kept by a later correction
create temp table later as select (select em.member_id from public.entry_members em where em.entry_id = (select h_champ from champ)) as member_id;
grant select on later to public;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.set_member_cpc_rating((select member_id from later), 'singles', 4.000,
  (select version from public.member_cpc_ratings where discipline = 'singles' and member_id = (select member_id from later) and deleted_at is null), core.ulid(), 'Fake reassessment after the event');
create temp table c1 as select public.correct_match(pg_temp.final_of('H'), 'The final was won by the other player', pg_temp.upset(pg_temp.final_of('H'))) as r;
reset role;
grant select on c1 to public;
select is((select r -> 'ranks' ->> 'changed' from c1), 'true', 'a different champion re-evaluates the division');
select is(pg_temp.pts((select h_champ from champ)), 3.947::numeric, 'the old champion keeps the later 4.000 assessment: 4.000 - 0.109 + 0.056');
select is(pg_temp.pts((select h_second from champ)), 3.031::numeric, 'the new champion gets 3.031');
select is(pg_temp.rank_code_of((select h_champ from champ)), 'intermediate-high', 'the old champion rank follows 3.947');
select is((select count(*)::int from public.division_results where division_id = (select dv from fx) and superseded_at is not null), 8, 'the changed placements supersede the first results');
select is((select count(*)::int from public.division_results_view((select dv from fx))), 8, 'the results screen shows only the live ones');
select is((select count(*)::int from public.rank_history x where x.division_id = (select dv from fx) and x.reverses_id is null
  and not exists (select 1 from public.rank_history y where y.reverses_id = x.id)), 8, 'one live rank row for each player after corrections');

-- ---- rank bands are exact
select is(core.cpc_rank_for_points((select id from public.orgs where code = 'cpc'), 2.249), (select r.id from public.ranks r where r.code = 'beginner-low' and r.deleted_at is null), '2.249 is Beginner Low');
select is(core.cpc_rank_for_points((select id from public.orgs where code = 'cpc'), 2.250), (select r.id from public.ranks r where r.code = 'beginner-high' and r.deleted_at is null), '2.250 is Beginner High');
select is(core.cpc_rank_for_points((select id from public.orgs where code = 'cpc'), 4.999), (select r.id from public.ranks r where r.code = 'advanced-high' and r.deleted_at is null), '4.999 is Advanced High');
select is(core.cpc_rank_for_points((select id from public.orgs where code = 'cpc'), 8.000), (select r.id from public.ranks r where r.code = 'open' and r.deleted_at is null), '8.000 is Professional');
select throws_ok(format('select core.cpc_rank_for_points(%L, 8.5)', (select id from public.orgs where code = 'cpc')), '22023', null, 'points outside 2.000-8.000 have no rank');

-- ---- access
select is(has_function_privilege('authenticated', 'core.apply_cpc_points(text, text)', 'execute'), false, 'browsers cannot call the points engine');
select is(has_function_privilege('authenticated', 'core.cpc_division_outcomes(text)', 'execute'), false, 'or the calculation');
select is(core.cpc_points_enabled((select id from public.orgs where code = 'cpc')), true, 'activation reads the setting');
select * from finish();
rollback;
