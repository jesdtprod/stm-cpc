begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create function pg_temp.mk(p_org text, p_role text, p_person text default null) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := coalesce(p_person, core.ulid()); rid text;
begin
  select id into rid from public.roles where org_id = p_org and code = p_role;
  insert into auth.users (id, email) values (u, p_role || '-' || u || '@example.test');
  if p_person is null then
    insert into public.persons (id, org_id, display_name) values (per, p_org, 'Fake ' || p_role);
  end if;
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, p_org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (p_org, pid, rid);
  return u;
end $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as cat, core.ulid() as ev, core.ulid() as dv, core.ulid() as dv_b, core.ulid() as st, core.ulid() as st2,
  core.ulid() as p1, core.ulid() as p2, core.ulid() as p3, core.ulid() as p4,
  core.ulid() as m1, core.ulid() as m2, core.ulid() as m3, core.ulid() as m4,
  core.ulid() as r1, core.ulid() as r2, core.ulid() as r3, core.ulid() as r4,
  core.ulid() as e1, core.ulid() as e2, core.ulid() as e3, core.ulid() as e4,
  core.ulid() as court, core.ulid() as mt1, core.ulid() as mt2, core.ulid() as mt3, core.ulid() as mt4,
  core.ulid() as dr1, core.ulid() as dr2, core.ulid() as se1, core.ulid() as se2;
grant select on fx to public;

insert into public.persons (id, org_id, display_name) values
  ((select p1 from fx), (select org from fx), 'Fake A'), ((select p2 from fx), (select org from fx), 'Fake B'),
  ((select p3 from fx), (select org from fx), 'Fake C'), ((select p4 from fx), (select org from fx), 'Fake D');
insert into public.members (id, org_id, person_id, member_no, status) values
  ((select m1 from fx), (select org from fx), (select p1 from fx), 'CPC-2026-94001', 'pending_approval'),
  ((select m2 from fx), (select org from fx), (select p2 from fx), 'CPC-2026-94002', 'pending_approval'),
  ((select m3 from fx), (select org from fx), (select p3 from fx), 'CPC-2026-94003', 'pending_approval'),
  ((select m4 from fx), (select org from fx), (select p4 from fx), 'CPC-2026-94004', 'pending_approval');
update public.members set status = 'active' where id in ((select m1 from fx), (select m2 from fx), (select m3 from fx), (select m4 from fx));
insert into public.categories (id, org_id, code, name) values ((select cat from fx), (select org from fx), 't2-cat', 'T2 Cat');
insert into public.courts (id, org_id, code, name) values ((select court from fx), (select org from fx), 't2-court', 'T2 Court');
insert into public.events (id, org_id, name, starts_on, ends_on, payload_hash) values ((select ev from fx), (select org from fx), 'T2 Event', '2026-12-05', '2026-12-05', repeat('a', 64));
insert into public.divisions (id, org_id, event_id, name, category_id, format, format_snapshot, scoring_snapshot, payload_hash)
  values ((select dv from fx), (select org from fx), (select ev from fx), 'T2 Singles', (select cat from fx), 'singles', '[{"stage_type":"round_robin"},{"stage_type":"single_elimination"}]', '{}', repeat('b', 64)),
         ((select dv_b from fx), (select org from fx), (select ev from fx), 'T2 Other', (select cat from fx), 'singles', '[{"stage_type":"round_robin"}]', '{}', repeat('c', 64));
insert into public.division_stages (id, org_id, division_id, stage_no, stage_type, scoring_rule_snapshot) values
  ((select st from fx), (select org from fx), (select dv from fx), 1, 'round_robin', '{}'),
  ((select st2 from fx), (select org from fx), (select dv from fx), 2, 'single_elimination', '{}');
insert into public.registrations (id, org_id, event_id, division_id, member_id, fee_snapshot, payload_hash) values
  ((select r1 from fx), (select org from fx), (select ev from fx), (select dv from fx), (select m1 from fx), 0, repeat('1', 64)),
  ((select r2 from fx), (select org from fx), (select ev from fx), (select dv from fx), (select m2 from fx), 0, repeat('2', 64)),
  ((select r3 from fx), (select org from fx), (select ev from fx), (select dv from fx), (select m3 from fx), 0, repeat('3', 64)),
  ((select r4 from fx), (select org from fx), (select ev from fx), (select dv_b from fx), (select m4 from fx), 0, repeat('4', 64));
update public.registrations set status = 'confirmed' where id in ((select r1 from fx), (select r2 from fx), (select r3 from fx), (select r4 from fx));
insert into public.entries (id, org_id, division_id, registration_id, seed) values
  ((select e1 from fx), (select org from fx), (select dv from fx), (select r1 from fx), 1),
  ((select e2 from fx), (select org from fx), (select dv from fx), (select r2 from fx), 2),
  ((select e3 from fx), (select org from fx), (select dv from fx), (select r3 from fx), 3),
  ((select e4 from fx), (select org from fx), (select dv_b from fx), (select r4 from fx), 1);

-- ---- structure
select is((select count(*)::int from pg_class where relnamespace = 'public'::regnamespace and relrowsecurity
  and relname in ('draws', 'matches', 'match_games', 'score_events', 'division_results')), 5, 'RLS is on for all five tables');
select is((select count(*)::int from pg_class c where c.relnamespace = 'public'::regnamespace
  and c.relname in ('draws', 'matches', 'match_games', 'score_events', 'division_results') and obj_description(c.oid, 'pg_class') like 'class: %'), 5, 'every table has a class comment');

-- ---- draws
insert into public.draws (id, org_id, division_stage_id, seed, entrant_snapshot, result)
  values ((select dr1 from fx), (select org from fx), (select st from fx), repeat('ab', 16), '[{"entry":"e1","seed":1}]', '{"rounds":1}');
select throws_ok(format($f$insert into public.draws (org_id, division_stage_id, seed, entrant_snapshot, result) values (%L, %L, repeat('cd', 16), '[]', '{}')$f$, (select org from fx), (select st from fx)),
  '23505', null, 'a second first-time draw of a stage is refused (one active draw per stage)');
update public.division_stages set status = 'drawn' where id = (select st from fx);
select throws_ok(format($f$insert into public.draws (org_id, division_stage_id, seed, entrant_snapshot, result, replaces_draw_id, redo_reason) values (%L, %L, repeat('cd', 16), '[]', '{}', %L, 'seeding error')$f$,
  (select org from fx), (select st from fx), (select dr1 from fx)), '22023', null, 'a redo must first supersede the old draw');
select throws_ok(format($f$update public.draws set seed = repeat('ee', 16) where id = %L$f$, (select dr1 from fx)), '42501', null, 'a draw''s seed cannot be edited');
select lives_ok(format($f$update public.draws set status = 'superseded' where id = %L$f$, (select dr1 from fx)), 'a draw can be superseded');
select throws_ok(format($f$update public.draws set status = 'active' where id = %L$f$, (select dr1 from fx)), '22023', null, 'a superseded draw cannot come back');
select lives_ok(format($f$insert into public.draws (id, org_id, division_stage_id, seed, entrant_snapshot, result, replaces_draw_id, redo_reason) values (%L, %L, %L, repeat('cd', 16), '[]', '{}', %L, 'seeding error')$f$,
  (select dr2 from fx), (select org from fx), (select st from fx), (select dr1 from fx)), 'the replacement draw is recorded');
select throws_ok(format($f$insert into public.draws (org_id, division_stage_id, seed, entrant_snapshot, result, replaces_draw_id, redo_reason) values (%L, %L, repeat('ef', 16), '[]', '{}', %L, 'again')$f$,
  (select org from fx), (select st from fx), (select dr1 from fx)), '23505', null, 'only one draw per stage can be active');
select throws_ok(format($f$insert into public.draws (org_id, division_stage_id, seed, entrant_snapshot, result) values (%L, %L, 'nothex', '[]', '{}')$f$, (select org from fx), (select st2 from fx)), '23514', null, 'the seed must be hex');
select throws_ok(format($f$insert into public.draws (org_id, division_stage_id, seed, entrant_snapshot, result, redo_reason) values (%L, %L, repeat('ab', 16), '[]', '{}', 'why')$f$, (select org from fx), (select st2 from fx)), '23514', null, 'a redo reason needs a draw to replace');
select throws_ok(format($f$delete from public.draws where id = %L$f$, (select dr1 from fx)), '42501', null, 'draws cannot be hard-deleted');

-- ---- matches
insert into public.matches (id, org_id, division_stage_id, round_no, match_no, group_label, entry_a_id, entry_b_id)
  values ((select mt1 from fx), (select org from fx), (select st from fx), 1, 1, 'A', (select e1 from fx), (select e2 from fx));
select is((select status from public.matches where id = (select mt1 from fx)), 'scheduled', 'a match starts scheduled');
select throws_ok(format($f$insert into public.matches (org_id, division_stage_id, round_no, match_no, entry_a_id, entry_b_id) values (%L, %L, 1, 1, %L, %L)$f$, (select org from fx), (select st from fx), (select e1 from fx), (select e3 from fx)),
  '23505', null, 'a round and match number is unique within a stage');
select throws_ok(format($f$insert into public.matches (org_id, division_stage_id, round_no, match_no, entry_a_id, entry_b_id) values (%L, %L, 1, 2, %L, %L)$f$, (select org from fx), (select st from fx), (select e1 from fx), (select e1 from fx)),
  '23514', null, 'an entry cannot play itself');
select throws_ok(format($f$insert into public.matches (org_id, division_stage_id, round_no, match_no, entry_a_id) values (%L, %L, 1, 2, %L)$f$, (select org from fx), (select st from fx), (select e4 from fx)),
  '22023', null, 'an entry from another division cannot play here');
select throws_ok(format($f$insert into public.matches (org_id, division_stage_id, round_no, match_no, referee_member_id) values (%L, %L, 1, 2, core.ulid())$f$, (select org from fx), (select st from fx)),
  '22023', null, 'the referee must be an active member');
select throws_ok(format($f$insert into public.matches (org_id, division_stage_id, round_no, match_no, group_label) values (%L, %L, 1, 2, 'lowercase')$f$, (select org from fx), (select st from fx)),
  '23514', null, 'a group label is short and uppercase');
select throws_ok(format($f$insert into public.matches (org_id, division_stage_id, round_no, match_no, feeds_match_id) values (%L, %L, 1, 2, %L)$f$, (select org from fx), (select st from fx), (select mt1 from fx)),
  '23514', null, 'a feed needs a slot');
select throws_ok(format($f$insert into public.matches (org_id, division_stage_id, round_no, match_no, feeds_match_id, slot) values (%L, %L, 1, 2, %L, 'a')$f$, (select org from fx), (select st2 from fx), (select mt1 from fx)),
  '22023', null, 'a match can feed only a match of its own stage');

-- a knockout final fed by two semifinals; the final waits for its opponents
insert into public.matches (id, org_id, division_stage_id, round_no, match_no, entry_a_id, entry_b_id, court_id, referee_member_id)
  values ((select mt2 from fx), (select org from fx), (select st from fx), 1, 2, (select e3 from fx), null, (select court from fx), (select m4 from fx));
insert into public.matches (id, org_id, division_stage_id, round_no, match_no, feeds_match_id, slot)
  values ((select mt3 from fx), (select org from fx), (select st from fx), 2, 1, null, null);
insert into public.matches (id, org_id, division_stage_id, round_no, match_no, feeds_match_id, slot)
  values ((select mt4 from fx), (select org from fx), (select st from fx), 1, 3, (select mt3 from fx), 'a');

select lives_ok(format($f$update public.matches set entry_b_id = %L where id = %L$f$, (select e1 from fx), (select mt2 from fx)), 'an empty opponent slot can be filled');
select throws_ok(format($f$update public.matches set entry_b_id = %L where id = %L$f$, (select e2 from fx), (select mt2 from fx)), '42501', null, 'a known opponent cannot be swapped');
select throws_ok(format($f$update public.matches set round_no = 5 where id = %L$f$, (select mt1 from fx)), '42501', null, 'a match''s position cannot change');
select throws_ok(format($f$update public.matches set status = 'completed', winner_entry_id = %L where id = %L$f$, (select e1 from fx), (select mt1 from fx)), '22023', null, 'a scheduled match cannot jump to completed');
select lives_ok(format($f$update public.matches set status = 'in_progress' where id = %L$f$, (select mt1 from fx)), 'scheduled -> in_progress');
select throws_ok(format($f$update public.matches set status = 'completed' where id = %L$f$, (select mt1 from fx)), '23514', null, 'a completed match needs a winner');
select throws_ok(format($f$update public.matches set status = 'completed', winner_entry_id = %L where id = %L$f$, (select e3 from fx), (select mt1 from fx)), '23514', null, 'the winner must be one of the two entries');

-- games, while the match is live
insert into public.match_games (org_id, match_id, game_no, score_a, score_b) values ((select org from fx), (select mt1 from fx), 1, 11, 7);
select throws_ok(format($f$insert into public.match_games (org_id, match_id, game_no, score_a, score_b) values (%L, %L, 1, 11, 5)$f$, (select org from fx), (select mt1 from fx)), '23505', null, 'a game number is unique within a match');
select throws_ok(format($f$insert into public.match_games (org_id, match_id, game_no, score_a, score_b) values (%L, %L, 2, 9, 9)$f$, (select org from fx), (select mt1 from fx)), '23514', null, 'a game cannot end in a tie');
select throws_ok(format($f$insert into public.match_games (org_id, match_id, game_no, score_a, score_b) values (%L, %L, 2, -1, 9)$f$, (select org from fx), (select mt1 from fx)), '23514', null, 'a score cannot be negative');
select lives_ok(format($f$update public.match_games set score_b = 8 where match_id = %L and game_no = 1$f$, (select mt1 from fx)), 'a game can be corrected while the match is live');
select throws_ok(format($f$update public.match_games set game_no = 3 where match_id = %L$f$, (select mt1 from fx)), '42501', null, 'a game number cannot change');
select lives_ok(format($f$update public.matches set status = 'completed', winner_entry_id = %L where id = %L$f$, (select e1 from fx), (select mt1 from fx)), 'in_progress -> completed with a winner');
select throws_ok(format($f$insert into public.match_games (org_id, match_id, game_no, score_a, score_b) values (%L, %L, 2, 11, 3)$f$, (select org from fx), (select mt1 from fx)), '22023', null, 'games cannot be added to a finished match');
select throws_ok(format($f$update public.match_games set score_a = 0 where match_id = %L$f$, (select mt1 from fx)), '22023', null, 'or edited');
select throws_ok(format($f$update public.matches set winner_entry_id = %L where id = %L$f$, (select e2 from fx), (select mt1 from fx)), '42501', null, 'the winner cannot be changed');
select is((select count(*)::int from public.entity_events where entity_type = 'match' and entity_id = (select mt1 from fx)), 3, 'match status changes are logged');

-- a correction voids the match and a new one takes its place
select lives_ok(format($f$update public.matches set status = 'void', status_reason = 'wrong score' where id = %L$f$, (select mt1 from fx)), 'completed -> void');
select throws_ok(format($f$update public.matches set status = 'scheduled' where id = %L$f$, (select mt1 from fx)), '22023', null, 'void is final');
select lives_ok(format($f$insert into public.matches (org_id, division_stage_id, round_no, match_no, entry_a_id, entry_b_id) values (%L, %L, 1, 1, %L, %L)$f$, (select org from fx), (select st from fx), (select e1 from fx), (select e2 from fx)),
  'a voided match frees its place for the replacement');
select throws_ok(format($f$delete from public.matches where id = %L$f$, (select mt1 from fx)), '42501', null, 'matches cannot be hard-deleted');

-- forfeits and cancellations
select lives_ok(format($f$update public.matches set status = 'forfeited', winner_entry_id = %L, status_reason = 'no show' where id = %L$f$, (select e3 from fx), (select mt2 from fx)), 'scheduled -> forfeited with a winner');
select lives_ok(format($f$update public.matches set status = 'cancelled', status_reason = 'not needed' where id = %L$f$, (select mt4 from fx)), 'scheduled -> cancelled');
select throws_ok(format($f$update public.matches set status = 'in_progress' where id = %L$f$, (select mt4 from fx)), '22023', null, 'cancelled is final');

-- ---- score events
insert into public.score_events (id, org_id, match_id, kind, payload) values ((select se1 from fx), (select org from fx), (select mt2 from fx), 'finalized', '{"winner":"e3"}');
select throws_ok(format($f$insert into public.score_events (org_id, match_id, kind) values (%L, %L, 'finalized')$f$, (select org from fx), (select mt2 from fx)), '23505', null, 'a match has one live final result');
select lives_ok(format($f$insert into public.score_events (org_id, match_id, kind) values (%L, %L, 'entered')$f$, (select org from fx), (select mt2 from fx)), 'entered events can repeat');
select throws_ok(format($f$insert into public.score_events (org_id, match_id, kind, reverses_id) values (%L, %L, 'entered', %L)$f$, (select org from fx), (select mt2 from fx), (select se1 from fx)), '23514', null, 'only a correction reverses an event');
select throws_ok(format($f$insert into public.score_events (org_id, match_id, kind) values (%L, %L, 'corrected')$f$, (select org from fx), (select mt2 from fx)), '23514', null, 'a correction must say what it reverses');
select throws_ok(format($f$insert into public.score_events (org_id, match_id, kind, reverses_id) values (%L, %L, 'corrected', %L)$f$, (select org from fx), (select mt1 from fx), (select se1 from fx)), '22023', null, 'a correction must be on the same match');
select lives_ok(format($f$insert into public.score_events (id, org_id, match_id, kind, reverses_id) values (%L, %L, %L, 'corrected', %L)$f$, (select se2 from fx), (select org from fx), (select mt2 from fx), (select se1 from fx)), 'a correction reverses the final result');
select throws_ok(format($f$insert into public.score_events (org_id, match_id, kind, reverses_id) values (%L, %L, 'corrected', %L)$f$, (select org from fx), (select mt2 from fx), (select se1 from fx)), '23505', null, 'a result can be corrected only once');
select lives_ok(format($f$insert into public.score_events (org_id, match_id, kind, payload) values (%L, %L, 'finalized', '{"winner":"e1"}')$f$, (select org from fx), (select mt2 from fx)), 'after the correction a new final result may be recorded');
select throws_ok(format($f$insert into public.score_events (org_id, match_id, kind) values (%L, core.ulid(), 'entered')$f$, (select org from fx)), '22023', null, 'the match must exist');
select throws_ok($$update public.score_events set kind = 'entered'$$, '42501', null, 'score events cannot be edited');
select throws_ok($$delete from public.score_events$$, '42501', null, 'or deleted');

-- ---- division results
select throws_ok(format($f$insert into public.division_results (org_id, division_id, entry_id, placement) values (%L, %L, %L, 1)$f$, (select org from fx), (select dv from fx), (select e1 from fx)),
  '22023', null, 'results are refused until the division is in progress');
update public.divisions set status = 'drawn' where id = (select dv from fx);
update public.divisions set status = 'in_progress' where id = (select dv from fx);
insert into public.division_results (org_id, division_id, entry_id, placement, bracket_tier, bracket_result) values ((select org from fx), (select dv from fx), (select e1 from fx), 1, 'H', 'won');
select throws_ok(format($f$insert into public.division_results (org_id, division_id, entry_id, placement) values (%L, %L, %L, 2)$f$, (select org from fx), (select dv from fx), (select e1 from fx)), '23505', null, 'an entry has one result');
select throws_ok(format($f$insert into public.division_results (org_id, division_id, entry_id, placement) values (%L, %L, %L, 2)$f$, (select org from fx), (select dv from fx), (select e4 from fx)), '22023', null, 'a result must be for an entry of the division');
select throws_ok(format($f$insert into public.division_results (org_id, division_id, entry_id, placement, bracket_result) values (%L, %L, %L, 2, 'won')$f$, (select org from fx), (select dv from fx), (select e2 from fx)), '23514', null, 'a bracket result needs a bracket tier');
select throws_ok(format($f$insert into public.division_results (org_id, division_id, entry_id, placement, bracket_tier) values (%L, %L, %L, 0, 'H')$f$, (select org from fx), (select dv from fx), (select e2 from fx)), '23514', null, 'placement starts at 1');
select lives_ok(format($f$insert into public.division_results (org_id, division_id, entry_id, placement, bracket_tier, bracket_result) values (%L, %L, %L, 2, 'L', 'lost')$f$, (select org from fx), (select dv from fx), (select e2 from fx)), 'a loser-bracket result is accepted');
select throws_ok($$update public.division_results set placement = 5$$, '42501', null, 'results are final');
select lives_ok(format($f$update public.divisions set status = 'finalized', finalized_at = now() where id = %L$f$, (select dv from fx)), 'the division is finalized after its results');

-- ---- row-level security
create temp table us(role text primary key, u uuid);
grant select on us to public;
insert into us values ('manager', pg_temp.mk((select org from fx), 'manager'));
insert into us values ('referee', pg_temp.mk((select org from fx), 'referee', (select p4 from fx)));
insert into us values ('member', pg_temp.mk((select org from fx), 'member', (select p1 from fx)));
update public.members set profile_id = (select p.id from public.profiles p where p.auth_user_id = (select u from us where role = 'member')) where id = (select m1 from fx);
update public.members set profile_id = (select p.id from public.profiles p where p.auth_user_id = (select u from us where role = 'referee')) where id = (select m4 from fx);
update public.events set status = 'registration_open' where id = (select ev from fx);

select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
select is((select count(*)::int from public.matches where division_stage_id = (select st from fx) and status <> 'void'), 4, 'a member sees the bracket of a drawn division');
select cmp_ok((select count(*)::int from public.match_games), '>=', 0, 'and can read games');
select is((select count(*)::int from public.division_results), 2, 'and the results');
select is((select count(*)::int from public.draws), 0, 'but not the draw seed');
select is((select count(*)::int from public.score_events), 0, 'or the score events');
select throws_ok(format($f$insert into public.matches (org_id, division_stage_id, round_no, match_no) values (%L, %L, 9, 9)$f$, (select org from fx), (select st from fx)), '42501', null, 'a member cannot create a match');
select throws_ok($$update public.matches set status = 'cancelled'$$, '42501', null, 'or change one');
select throws_ok(format($f$insert into public.match_games (org_id, match_id, game_no, score_a, score_b) values (%L, %L, 1, 11, 0)$f$, (select org from fx), (select mt2 from fx)), '42501', null, 'or enter a score');
reset role;

select pg_temp.as_user((select u from us where role = 'referee'));
set local role authenticated;
select cmp_ok((select count(*)::int from public.matches), '>=', 3, 'a referee sees matches');
select cmp_ok((select count(*)::int from public.score_events), '>=', 1, 'and the score events (scores.enter)');
select is((select count(*)::int from public.draws), 0, 'but not the draws');
select throws_ok($$update public.match_games set score_a = 1$$, '42501', null, 'and cannot write scores directly (the RPC checks the assignment)');
reset role;

select pg_temp.as_user((select u from us where role = 'manager'));
set local role authenticated;
select cmp_ok((select count(*)::int from public.draws), '>=', 2, 'a manager reads the draws');
select cmp_ok((select count(*)::int from public.score_events), '>=', 1, 'and the score events');
select throws_ok($$update public.matches set status = 'cancelled'$$, '42501', null, 'but writes only through RPCs');
reset role;

select is((select has_any_column_privilege('authenticated', 'public.draws', 'insert') or has_any_column_privilege('authenticated', 'public.matches', 'update')
  or has_any_column_privilege('authenticated', 'public.match_games', 'insert') or has_any_column_privilege('authenticated', 'public.score_events', 'insert')
  or has_any_column_privilege('authenticated', 'public.division_results', 'insert')), false, 'clients cannot write any of the tournament tables');

select * from finish();
rollback;
