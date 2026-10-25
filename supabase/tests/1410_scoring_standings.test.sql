begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as ev, core.ulid() as dv1, core.ulid() as dv2,
  core.ulid() as r1, core.ulid() as r2, core.ulid() as r3, core.ulid() as r4, core.ulid() as r5, core.ulid() as r6, core.ulid() as r7,
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
create temp table us(role text primary key, u uuid, mid text);
grant select on us to public;
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2026-9701', false), null;
insert into us select 'ref', pg_temp.mk('referee', 'CPC-2026-9702', false), null;
insert into us select 'outsider', pg_temp.mk('member', 'CPC-2026-9703', false), null;
insert into us select 'whistle', pg_temp.mk('member', 'CPC-2026-9704', false), null;
insert into us select 'p1', pg_temp.mk('member', 'CPC-2026-9711', true), null;
insert into us select 'p2', pg_temp.mk('member', 'CPC-2026-9712', true), null;
insert into us select 'p3', pg_temp.mk('member', 'CPC-2026-9713', true), null;
insert into us select 'p4', pg_temp.mk('member', 'CPC-2026-9714', true), null;
update us set mid = (select m.id from public.members m join public.profiles p on p.id = m.profile_id where p.auth_user_id = us.u);

-- ---- game rules
select is(core.game_ok('{"points_per_game":11,"win_by":2,"point_cap":null}'::jsonb, 11, 5), true, '11-5 is a finished game');
select is(core.game_ok('{"points_per_game":11,"win_by":2,"point_cap":null}'::jsonb, 11, 10), false, '11-10 is not finished when winning by 2');
select is(core.game_ok('{"points_per_game":11,"win_by":2,"point_cap":null}'::jsonb, 12, 10), true, '12-10 is finished');
select is(core.game_ok('{"points_per_game":11,"win_by":2,"point_cap":null}'::jsonb, 13, 10), false, '13-10 should have ended earlier');
select is(core.game_ok('{"points_per_game":11,"win_by":2,"point_cap":null}'::jsonb, 10, 8), false, 'nobody reached 11');
select is(core.game_ok('{"points_per_game":11,"win_by":1,"point_cap":null}'::jsonb, 11, 10), true, 'win by 1: 11-10 is finished');
select is(core.game_ok('{"points_per_game":11,"win_by":2,"point_cap":15}'::jsonb, 15, 14), true, 'at the cap one point is enough');
select is(core.game_ok('{"points_per_game":11,"win_by":2,"point_cap":15}'::jsonb, 16, 14), false, 'above the cap is not possible');

-- ---- set-up: an event, two divisions, entries for the players
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select public.create_event((select ev from fx), 'Score Test', (select day1 from fx), (select day1 from fx), 'Hall', 0, null, null);
select public.create_division((select dv1 from fx), (select ev from fx), 'Four Players', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.create_division((select dv2 from fx), (select ev from fx), 'Three Players', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.set_event_status((select ev from fx), 'registration_open', null);
reset role;
update public.settings set value = 'false'::jsonb where key = 'events.registration_approval_required' and unit_id is null and deleted_at is null;
select pg_temp.as_user((select u from us where role = 'p1')); set local role authenticated;
select public.register_for_event((select r1 from fx), (select dv1 from fx)); select public.register_for_event((select r5 from fx), (select dv2 from fx)); reset role;
select pg_temp.as_user((select u from us where role = 'p2')); set local role authenticated;
select public.register_for_event((select r2 from fx), (select dv1 from fx)); select public.register_for_event((select r6 from fx), (select dv2 from fx)); reset role;
select pg_temp.as_user((select u from us where role = 'p3')); set local role authenticated;
select public.register_for_event((select r3 from fx), (select dv1 from fx)); select public.register_for_event((select r7 from fx), (select dv2 from fx)); reset role;
select pg_temp.as_user((select u from us where role = 'p4')); set local role authenticated;
select public.register_for_event((select r4 from fx), (select dv1 from fx)); reset role;

create temp table ent as
  select u.role, e.id as entry, e.division_id from us u
  join public.entry_members em on em.member_id = u.mid join public.entries e on e.id = em.entry_id where u.role like 'p%';
grant select on ent to public;
create temp table st as
  select (select id from public.division_stages where division_id = (select dv1 from fx)) as s1,
         (select id from public.division_stages where division_id = (select dv2 from fx)) as s2,
         core.ulid() as mA, core.ulid() as mB, core.ulid() as mC, core.ulid() as mD, core.ulid() as mE, core.ulid() as mF,
         core.ulid() as f1, core.ulid() as f2, core.ulid() as f3;
grant select on st to public;
create function pg_temp.en(p_role text, p_div text) returns text language sql as $$ select entry from ent where role = p_role and division_id = p_div $$;
grant execute on function pg_temp.en(text, text) to public;

-- ---- a knockout path: f1 and f2 feed f3
insert into public.matches (id, org_id, division_stage_id, round_no, match_no, entry_a_id, entry_b_id)
values ((select f3 from st), (select org from fx), (select s1 from st), 2, 1, null, null);
insert into public.matches (id, org_id, division_stage_id, round_no, match_no, entry_a_id, entry_b_id, feeds_match_id, slot, referee_member_id)
values ((select f1 from st), (select org from fx), (select s1 from st), 1, 1, pg_temp.en('p1', (select dv1 from fx)), pg_temp.en('p2', (select dv1 from fx)),
        (select f3 from st), 'a', (select mid from us where role = 'whistle'));
insert into public.matches (id, org_id, division_stage_id, round_no, match_no, entry_a_id, entry_b_id, feeds_match_id, slot)
values ((select f2 from st), (select org from fx), (select s1 from st), 1, 2, pg_temp.en('p3', (select dv1 from fx)), pg_temp.en('p4', (select dv1 from fx)),
        (select f3 from st), 'b');

-- ---- access
select is(has_function_privilege('anon', 'public.finalize_match(text)', 'execute'), false, 'anonymous callers cannot finalize');
select pg_temp.as_user((select u from us where role = 'outsider')); set local role authenticated;
select throws_ok(format($f$select public.enter_score(%L, '[{"a":11,"b":5}]')$f$, (select f1 from st)), '42501', null, 'an outsider cannot enter a score');
reset role;

-- ---- score entry
select pg_temp.as_user((select u from us where role = 'whistle')); set local role authenticated;
select throws_ok(format($f$select public.enter_score(%L, '[{"a":11,"b":11}]')$f$, (select f1 from st)), '22023', null, 'a level game is refused');
select throws_ok(format($f$select public.enter_score(%L, '[{"a":11,"b":5},{"a":11,"b":6}]')$f$, (select f1 from st)), '22023', null, 'a single-game match takes one game');
select is((select public.enter_score((select f1 from st), '[{"a":11,"b":10}]') ->> 'status'), 'in_progress', 'the assigned referee enters a score');
select throws_ok(format($f$select public.finalize_match(%L)$f$, (select f1 from st)), '42501', null, 'a referee without the finalize permission cannot finalize');
reset role;
select is((select status from public.matches where id = (select f1 from st)), 'in_progress', 'the match is in progress');

-- ---- finalizing
select pg_temp.as_user((select u from us where role = 'ref')); set local role authenticated;
select throws_ok(format($f$select public.finalize_match(%L)$f$, (select f1 from st)), '22023', null, '11-10 is not a finished game when winning by 2');
select public.enter_score((select f1 from st), '[{"a":11,"b":7}]');
select is((select public.finalize_match((select f1 from st)) ->> 'status'), 'completed', 'a referee finalizes 11-7');
select is((select public.finalize_match((select f1 from st)) ->> 'unchanged'), 'true', 'finalizing again returns the same result');
reset role;
select is((select winner_entry_id from public.matches where id = (select f1 from st)), pg_temp.en('p1', (select dv1 from fx)), 'the winner is recorded');
select is((select count(*)::int from public.score_events where match_id = (select f1 from st) and kind = 'finalized'), 1, 'there is exactly one final result');
select is((select entry_a_id from public.matches where id = (select f3 from st)), pg_temp.en('p1', (select dv1 from fx)), 'the winner moved into the next match');
select pg_temp.as_user((select u from us where role = 'ref')); set local role authenticated;
select throws_ok(format($f$select public.enter_score(%L, '[{"a":11,"b":1}]')$f$, (select f1 from st)), '22023', null, 'a finished match takes no more scores');
select throws_ok(format($f$select public.correct_match(%L, 'wrong score', '[{"a":11,"b":8}]')$f$, (select f1 from st)), '42501', null, 'a referee cannot correct a result');
reset role;

-- ---- forfeit
select pg_temp.as_user((select u from us where role = 'ref')); set local role authenticated;
select throws_ok(format($f$select public.forfeit_match(%L, %L, null)$f$, (select f2 from st), pg_temp.en('p4', (select dv1 from fx))), '22023', null, 'a forfeit needs a reason');
select throws_ok(format($f$select public.forfeit_match(%L, %L, 'no show')$f$, (select f2 from st), pg_temp.en('p1', (select dv1 from fx))), '22023', null, 'only one of the two sides can forfeit');
select is((select public.forfeit_match((select f2 from st), pg_temp.en('p4', (select dv1 from fx)), 'Did not turn up') ->> 'status'), 'forfeited', 'a forfeit is recorded');
select is((select public.forfeit_match((select f2 from st), pg_temp.en('p4', (select dv1 from fx)), 'Did not turn up') ->> 'unchanged'), 'true', 'and again is safe');
reset role;
select is((select winner_entry_id from public.matches where id = (select f2 from st)), pg_temp.en('p3', (select dv1 from fx)), 'the other side wins');
select is((select score_a || '-' || score_b from public.match_games where match_id = (select f2 from st) and game_no = 1), '11-0', 'with the rule''s forfeit score');
select is((select entry_b_id from public.matches where id = (select f3 from st)), pg_temp.en('p3', (select dv1 from fx)), 'and advances');

-- ---- corrections
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select throws_ok(format($f$select public.correct_match(%L, 'p2 really won', '[{"a":5,"b":11}]')$f$, (select f1 from st)), '22023', 'the next match already has a different opponent; void it first', 'a correction that changes an advanced winner is refused');
select throws_ok(format($f$select public.correct_match(%L, 'x', '[{"a":11,"b":8}]')$f$, (select f1 from st)), '22023', null, 'a correction needs a proper reason');
create temp table cx as select public.correct_match((select f1 from st), 'Score misread', '[{"a":11,"b":8}]') as r;
reset role;
grant select on cx to public;
select is((select status from public.matches where id = (select f1 from st)), 'void', 'the old match is voided');
select is((select count(*)::int from public.matches where division_stage_id = (select s1 from st) and round_no = 1 and match_no = 1 and status = 'completed'), 1, 'exactly one live match remains at that position');
select is((select score_a || '-' || score_b from public.match_games where match_id = (select (r ->> 'new_match_id') from cx)), '11-8', 'with the corrected score');
select is((select count(*)::int from public.score_events where match_id = (select f1 from st) and kind = 'corrected'), 1, 'the correction is a reversing event');
select is((select entry_a_id from public.matches where id = (select f3 from st)), pg_temp.en('p1', (select dv1 from fx)), 'the next match is unchanged');

-- ---- standings: four players, a full round robin (round 1 of stage 1 = knockouts above are excluded by using group null in stage 2 of dv2 below)
-- stage 1 has the knockout matches only; check its standings count only finished matches
select is((select count(*)::int from core.stage_standings((select s1 from st))), 4, 'standings list every entry with a match');
select is((select wins from core.stage_standings((select s1 from st)) where entry_id = pg_temp.en('p1', (select dv1 from fx))), 1, 'a winner has one win');

-- the final of stage 1: p1 beats p3. p2 and p4 have no win and never met, so head-to-head is silent and point difference decides.
select pg_temp.as_user((select u from us where role = 'ref')); set local role authenticated;
select public.enter_score((select f3 from st), '[{"a":11,"b":2}]');
select public.finalize_match((select f3 from st));
reset role;
select is((select array_agg(entry_id order by place) from core.stage_standings((select s1 from st))),
  array[pg_temp.en('p1', (select dv1 from fx)), pg_temp.en('p3', (select dv1 from fx)), pg_temp.en('p2', (select dv1 from fx)), pg_temp.en('p4', (select dv1 from fx))],
  'wins order the table; p2 (-3) is ahead of p4 (forfeit, -11) on point difference');
select is((select place from core.stage_standings((select s1 from st)) where entry_id = pg_temp.en('p4', (select dv1 from fx))), 4, 'and p4 is fourth');

-- stage 2: three players in a cycle
insert into public.matches (id, org_id, division_stage_id, round_no, match_no, entry_a_id, entry_b_id) values
 ((select mA from st), (select org from fx), (select s2 from st), 1, 1, pg_temp.en('p1', (select dv2 from fx)), pg_temp.en('p2', (select dv2 from fx))),
 ((select mB from st), (select org from fx), (select s2 from st), 1, 2, pg_temp.en('p2', (select dv2 from fx)), pg_temp.en('p3', (select dv2 from fx))),
 ((select mC from st), (select org from fx), (select s2 from st), 1, 3, pg_temp.en('p3', (select dv2 from fx)), pg_temp.en('p1', (select dv2 from fx)));
select pg_temp.as_user((select u from us where role = 'ref')); set local role authenticated;
select public.enter_score((select mA from st), '[{"a":11,"b":9}]');   -- p1 beats p2, +2
select public.finalize_match((select mA from st));
select public.enter_score((select mB from st), '[{"a":11,"b":5}]');   -- p2 beats p3, +6
select public.finalize_match((select mB from st));
select public.enter_score((select mC from st), '[{"a":11,"b":8}]');   -- p3 beats p1, +3
select public.finalize_match((select mC from st));
reset role;
-- wins tie 1-1-1 and head-to-head among all three is also 1-1-1, so point difference decides: p2 +4, p1 -1, p3 -3
select is((select array_agg(entry_id order by place) from core.stage_standings((select s2 from st))),
  array[pg_temp.en('p2', (select dv2 from fx)), pg_temp.en('p1', (select dv2 from fx)), pg_temp.en('p3', (select dv2 from fx))],
  'a three-way tie is split by point difference after head-to-head fails');
select is((select array_agg(place order by place) from core.stage_standings((select s2 from st))), array[1, 2, 3], 'places are 1, 2, 3');
select is((select bool_or(tied) from core.stage_standings((select s2 from st))), false, 'nobody is left tied');

-- with only match wins to go on, the three share first place
update public.division_stages set scoring_rule_snapshot = jsonb_set(scoring_rule_snapshot, '{tiebreak_order}', '["match_wins"]') where id = (select s2 from st);
select is((select array_agg(place) from core.stage_standings((select s2 from st))), array[1, 1, 1], 'unbroken ties share a place');
select is((select bool_and(tied) from core.stage_standings((select s2 from st))), true, 'and are marked tied');
-- a coin toss settles it, the same way every time
update public.division_stages set scoring_rule_snapshot = jsonb_set(scoring_rule_snapshot, '{tiebreak_order}', '["match_wins","coin_toss"]') where id = (select s2 from st);
select is((select array_agg(place order by place) from core.stage_standings((select s2 from st))), array[1, 2, 3], 'a coin toss gives everyone a place');
select is((select array_agg(entry_id order by place) from core.stage_standings((select s2 from st))),
  (select array_agg(entry_id order by place) from core.stage_standings((select s2 from st))), 'and gives the same order each time');
-- head-to-head decides a two-way tie
update public.division_stages set scoring_rule_snapshot = jsonb_set(scoring_rule_snapshot, '{tiebreak_order}', '["match_wins","head_to_head"]') where id = (select s1 from st);

-- ---- who can read standings
select pg_temp.as_user((select u from us where role = 'outsider')); set local role authenticated;
select is((select count(*)::int from public.stage_standings((select s2 from st))), 3, 'a member can read the standings');
reset role;
set local role anon;
select throws_ok(format($f$select * from public.stage_standings(%L)$f$, (select s2 from st)), '42501', null, 'the public cannot call the standings function');
reset role;

-- ---- audit
select ok(exists (select 1 from core.audit_log where action = 'match.correct' and record_id = (select f1 from st)), 'a correction is audited');
select ok(exists (select 1 from core.audit_log where action = 'match.finalize' and record_id = (select mA from st)), 'a finalization is audited');

select * from finish();
rollback;
