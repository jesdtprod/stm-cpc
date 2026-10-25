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
  (select id from public.format_templates where lower(name) = 'round robin' and deleted_at is null) as tpl_rr,
  (select id from public.format_templates where lower(name) = 'regular (bracketing)' and deleted_at is null) as tpl_reg,
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
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2026-97401', false), null, null;
insert into us select 'ref', pg_temp.mk('referee', 'CPC-2026-97402', false), null, null;
insert into us select 'outsider', pg_temp.mk('member', 'CPC-2026-97403', false), null, null;
insert into us select 'p' || i, pg_temp.mk('member', 'CPC-2026-974' || lpad((10 + i)::text, 2, '0'), true), null, i from generate_series(1, 16) i;
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

-- ---- split single elimination: round 1 for everyone, then H and L
select is((select count(*)::int from public.matches where division_stage_id = (select s from stg)), 8, 'sixteen entries: 8 first-round matches');
select pg_temp.play_stage((select s from stg));
select is((select count(*)::int from public.matches where division_stage_id = (select s from stg) and group_label = 'H'), 7, 'the winners get a 7-match H bracket');
select is((select count(*)::int from public.matches where division_stage_id = (select s from stg) and group_label = 'L'), 7, 'the losers a 7-match L bracket');
select is((select status from public.division_stages where id = (select s from stg)), 'in_progress', 'the stage is not over when round 1 is');
select is((select count(*)::int from public.matches where division_stage_id = (select s from stg) and group_label = 'H' and entry_a_id is not null and entry_b_id is not null and round_no = 2), 4, 'the H quarterfinals have their players');
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select throws_ok(format($f$select public.finalize_division(%L)$f$, (select dvS from fx)), '22023', 'every stage must be completed first', 'a division cannot be finalized while play continues');
reset role;
select pg_temp.play_stage((select s from stg));
select pg_temp.play_stage((select s from stg));
select pg_temp.play_stage((select s from stg));
select is((select status from public.division_stages where id = (select s from stg)), 'completed', 'after the two finals the stage is complete');
select is((select count(*)::int from public.matches where division_stage_id = (select s from stg) and status = 'completed'), 22, 'the club example: 22 games');
select is((select winner_entry_id from public.matches where division_stage_id = (select s from stg) and group_label = 'H' and round_no = 4), (select entry from ent where role = 'p1' and division_id = (select dvS from fx)), 'the strongest player is H champion');

-- ---- finalizing
select pg_temp.as_user((select u from us where role = 'outsider')); set local role authenticated;
select throws_ok(format($f$select public.finalize_division(%L)$f$, (select dvS from fx)), '42501', null, 'a member cannot finalize a division');
reset role;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
create temp table f1 as select public.finalize_division((select dvS from fx)) as r;
reset role;
grant select on f1 to public;
select is((select r ->> 'status' from f1), 'finalized', 'the division is finalized');
select is((select (r ->> 'results')::int from f1), 16, 'with 16 results');
select is((select status from public.divisions where id = (select dvS from fx)), 'finalized', 'its status says so');
select is((select string_agg(placement::text, ',' order by placement) from public.division_results where division_id = (select dvS from fx)), '1,2,3,3,5,5,5,5,9,10,11,11,13,13,13,13', 'placements: H 1, 2, 3, 3, 5 x 4 and L 9, 10, 11, 11, 13 x 4');
select is((select count(*)::int from public.division_results where division_id = (select dvS from fx) and bracket_tier = 'H'), 8, 'eight in the H tier');
select is((select count(*)::int from public.division_results where division_id = (select dvS from fx) and bracket_tier = 'L'), 8, 'eight in the L tier');
select is((select count(*)::int from public.division_results where division_id = (select dvS from fx) and bracket_result = 'won'), 2, 'two bracket champions');
select is((select bracket_tier || bracket_result from public.division_results where division_id = (select dvS from fx) and placement = 9), 'Lwon', 'the L champion is 9th');

-- ---- the rank movement: 1 up, 7 retain, 1 retain, 7 down
create temp table moves as
  select h.member_id, h.reason, h.rule_id, (select idx from chain where rank_id = h.from_rank_id) as f, (select idx from chain where rank_id = h.to_rank_id) as t
  from public.rank_history h where h.division_id = (select dvS from fx);
grant select on moves to public;
select is((select count(*)::int from moves), 16, 'every player has a history row');
select is((select count(*)::int from moves where t > f), 1, 'one moves up (the H champion)');
select is((select count(*)::int from moves where t = f), 8, 'eight keep their rank (7 lost the H final stages, 1 won the L bracket)');
select is((select count(*)::int from moves where t < f), 7, 'seven move down (they lost in the L bracket)');
select is((select m.t - m.f from moves m join us u on u.mid = m.member_id where u.role = 'p1'), 1, 'the strongest player moved up one level');
select is((select count(*)::int from public.member_ranks where member_id in (select mid from us where strength is not null) and rank_id = (select novice_top from fx)), 8, 'eight are still at the top of Novice');
select ok((select bool_and(source_division_id is not null) from public.member_ranks mr join moves m on m.member_id = mr.member_id where m.t <> m.f), 'a moved rank remembers its division');
select is((select count(distinct rule_id)::int from moves), 4, 'the four club rules were applied');

-- ---- finalizing again changes nothing
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select is((select public.finalize_division((select dvS from fx)) ->> 'unchanged'), 'true', 'finalizing twice returns the same outcome');
reset role;
select is((select count(*)::int from public.rank_history where division_id = (select dvS from fx)), 16, 'with no new history');
select is((select count(*)::int from public.division_results where division_id = (select dvS from fx)), 16, 'and no new results');
select throws_ok(format($f$insert into public.rank_history (org_id, member_id, from_rank_id, to_rank_id, division_id) values (%L, %L, %L, %L, %L)$f$,
  (select org from fx), (select mid from us where role = 'p1'), (select novice_top from fx), (select novice_top from fx), (select dvS from fx)), '23505', null, 'the database itself refuses a second move for the same division and member');
select throws_ok(format($f$update public.division_results set placement = 1 where division_id = %L$f$, (select dvS from fx)), '42501', null, 'results cannot be edited');

-- ---- a round robin has no tier, so no rule moves anyone
select pg_temp.play_stage((select r from stg));
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select is((select public.finalize_division((select dvR from fx)) ->> 'results'), '4', 'the round robin finalizes with 4 results');
reset role;
select is((select string_agg(placement::text, ',' order by placement) from public.division_results where division_id = (select dvR from fx)), '1,2,3,4', 'placed by the table');
select is((select count(*)::int from public.rank_history where division_id = (select dvR from fx)), 0, 'and with no matching rule nobody moves');
select is((select status from public.events where id = (select ev from fx)), 'in_progress', 'the event waits for its other division');

-- ---- pool play into a knockout: advancers first, then the rest of the brackets
select pg_temp.play_stage((select g1 from stg));
select pg_temp.play_stage((select g2 from stg));
select pg_temp.play_stage((select g2 from stg));
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.finalize_division((select dvG from fx));
reset role;
select is((select count(*)::int from public.division_results where division_id = (select dvG from fx)), 6, 'six results');
select is((select string_agg(placement::text, ',' order by placement) from public.division_results where division_id = (select dvG from fx) and placement <= 3), '1,2,3,3', 'champion, runner-up and two semifinal losers');
select is((select min(placement) from public.division_results where division_id = (select dvG from fx) and placement > 3), 5, 'the two who went out in the pools follow from 5th');
select is((select entry_id from public.division_results where division_id = (select dvG from fx) and placement = 1), (select entry from ent where role = 'p1' and division_id = (select dvG from fx)), 'the strongest player is first');
select is((select status from public.events where id = (select ev from fx)), 'completed', 'the last division finalized completes the event');

-- ---- what members can read
select pg_temp.as_user((select u from us where role = 'outsider')); set local role authenticated;
select is((select count(*)::int from public.division_results_view((select dvS from fx))), 16, 'a member can read the final placements');
select is((select count(*)::int from public.division_results_view((select dvS from fx)) where rank_from is not null), 0, 'without anyone else''s rank changes');
reset role;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select is((select count(*)::int from public.division_results_view((select dvS from fx)) where rank_from is not null and rank_to is not null), 16, 'staff see each result with the rank change');
reset role;
select ok(exists (select 1 from core.audit_log where action = 'division.finalize' and record_id = (select dvS from fx)), 'finalization is audited');

select * from finish();
rollback;
