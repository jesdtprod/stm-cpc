begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as e1, core.ulid() as e2, core.ulid() as e3, core.ulid() as e4, core.ulid() as e5,
  core.ulid() as x1, core.ulid() as x2, core.ulid() as x3, core.ulid() as x4, core.ulid() as x5, core.ulid() as x6,
  core.ulid() as g_person, core.ulid() as g_part, core.ulid() as g_reg,
  (select id from public.categories where code = 'novice' and deleted_at is null) as cat_novice,
  (select r.id from public.ranks r join public.rank_ladders l on l.id = r.ladder_id join public.categories c on c.id = l.category_id
    where c.code = 'novice' and r.deleted_at is null order by r.sort_order desc limit 1) as novice_top,
  (select id from public.format_templates where stages -> 0 ->> 'stage_type' = 'round_robin' and jsonb_array_length(stages) = 1 and deleted_at is null order by id limit 1) as tpl,
  current_date + 40 as day1;
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
    insert into public.member_ranks (org_id, member_id, rank_id) values (org, mid, (select novice_top from fx));
  end if;
  return u;
end $$;
-- strength: the lower number wins every match it plays
create temp table us(role text primary key, u uuid, mid text, strength int);
grant select on us to public;
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2034-98601', true), null, null;
insert into us select 'ref', pg_temp.mk('referee', 'CPC-2034-98602', false), null, null;
insert into us select r, pg_temp.mk('member', 'CPC-2034-' || (98700 + n), true), null, s
from (values ('s1', 1, 1), ('s2', 2, 2), ('s3', 3, 3), ('u1', 4, 1), ('u2', 5, 2), ('u3', 6, 1), ('u4', 7, 2),
  ('d1', 8, 1), ('d2', 9, 1), ('d3', 10, 3), ('d4', 11, 3), ('o1', 12, 1), ('o2', 13, 2)) v(r, n, s);
update us set mid = (select m.id from public.members m join public.profiles p on p.id = m.profile_id where p.auth_user_id = us.u);
select is((select count(*)::int from us where mid is not null), 15, 'fifteen fake members');

select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.create_event((select e1 from fx), 'Scenario One', (select day1 from fx), (select day1 from fx), 'Hall', 0, null, null);
select public.create_event((select e2 from fx), 'Scenario Two', (select day1 from fx) + 1, (select day1 from fx) + 1, 'Hall', 0, null, null);
select public.create_event((select e3 from fx), 'Scenario Limits', (select day1 from fx) + 2, (select day1 from fx) + 2, 'Hall', 0, null, null);
select public.create_event((select e4 from fx), 'Scenario Opt Out', (select day1 from fx) + 3, (select day1 from fx) + 3, 'Hall', 0, null, null);
select public.update_event((select e4 from fx), 'Scenario Opt Out', (select day1 from fx) + 3, (select day1 from fx) + 3, 'Hall', 0, null, null, false, (select tpl from fx), false);
select public.create_event((select e5 from fx), 'Scenario Doubles', (select day1 from fx) + 4, (select day1 from fx) + 4, 'Hall', 0, null, null);
select public.set_event_guest_policy((select e1 from fx), true, core.ulid());
select public.create_division((select x1 from fx), (select e1 from fx), 'Singles With Guest', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.create_division((select x2 from fx), (select e2 from fx), 'Singles Again', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.create_division((select x3 from fx), (select e3 from fx), 'Top Limit', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.create_division((select x4 from fx), (select e3 from fx), 'Bottom Limit', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.create_division((select x5 from fx), (select e4 from fx), 'Opted Out', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.create_division((select x6 from fx), (select e5 from fx), 'Doubles Pairs', (select cat_novice from fx), 'doubles', null, null, null, null, null, (select tpl from fx), null);
select public.set_event_status(e, 'registration_open', null) from (select e1 e from fx union all select e2 from fx union all select e3 from fx union all select e4 from fx union all select e5 from fx) z;
select public.create_guest_event_participant((select g_part from fx), (select e1 from fx), (select g_person from fx), 'Fake Guest', null, null, null, null);
reset role;
update public.settings set value = 'false'::jsonb where key = 'events.registration_approval_required' and unit_id is null and deleted_at is null;

create function pg_temp.join_div(p_role text, p_div text) returns void language plpgsql as $$
begin
  perform pg_temp.as_user((select u from us where role = p_role)); set local role authenticated;
  perform public.register_for_event(core.ulid(), p_div);
  reset role;
end $$;
create function pg_temp.join_pair(p_role text, p_partner text, p_div text) returns void language plpgsql as $$
begin
  perform pg_temp.as_user((select u from us where role = p_role)); set local role authenticated;
  perform public.register_for_event(core.ulid(), p_div, (select mid from us where role = p_partner));
  reset role;
end $$;
select pg_temp.join_div(r, (select x1 from fx)) from (values ('s1'), ('s2'), ('s3')) v(r);
select pg_temp.join_div(r, (select x2 from fx)) from (values ('s1'), ('s2'), ('s3')) v(r);
select pg_temp.join_div('u1', (select x3 from fx)); select pg_temp.join_div('u2', (select x3 from fx));
select pg_temp.join_div('u3', (select x4 from fx)); select pg_temp.join_div('u4', (select x4 from fx));
select pg_temp.join_div('o1', (select x5 from fx)); select pg_temp.join_div('o2', (select x5 from fx));
select pg_temp.join_pair('d1', 'd2', (select x6 from fx)); select pg_temp.join_pair('d3', 'd4', (select x6 from fx));
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.register_guest_for_event((select g_reg from fx), (select x1 from fx), (select g_part from fx), (select novice_top from fx));
select is((select count(*)::int from public.entries where division_id = (select x6 from fx)), 2, 'two doubles teams');
select is((select count(*)::int from public.entry_members em join public.entries e on e.id = em.entry_id where e.division_id = (select x6 from fx)), 4, 'with four players');

-- assessed starting points, then close registration and draw
select public.set_member_cpc_rating((select mid from us where role = v.r), case when v.r like 'd%' then 'doubles' else 'singles' end, v.p,
  (select version from public.member_cpc_ratings where member_id = (select mid from us where role = v.r) and discipline = case when v.r like 'd%' then 'doubles' else 'singles' end and deleted_at is null), core.ulid(), 'Fake assessed start')
from (values ('s1', 2.900), ('s2', 2.900), ('s3', 2.900), ('u1', 7.990), ('u2', 7.990), ('u3', 2.010), ('u4', 2.010),
  ('d1', 2.800), ('d2', 3.200), ('d3', 2.400), ('d4', 2.600), ('o1', 2.900), ('o2', 2.900)) v(r, p);
select public.set_event_participant_cpc_rating((select g_part from fx), 'singles', 3.500, 0, core.ulid(), 'Fake guest start');
select public.set_member_cpc_rating((select mid from us where role = 'd2'), 'singles', 4.200,
  (select version from public.member_cpc_ratings where member_id = (select mid from us where role = 'd2') and discipline = 'singles' and deleted_at is null), core.ulid(), 'Fake singles start');
select public.set_event_status(e, 'registration_closed', null) from (select e1 e from fx union all select e2 from fx union all select e3 from fx union all select e4 from fx union all select e5 from fx) z;
reset role;
-- the activation guard needs every active member prepared (unrated rows), as the real flow does
insert into public.member_cpc_ratings (org_id, unit_id, member_id, discipline)
select m.org_id, m.unit_id, m.id, d.discipline from public.members m cross join (values ('singles'), ('doubles')) d(discipline)
where m.deleted_at is null and m.status = 'active'
  and not exists (select 1 from public.member_cpc_ratings r where r.member_id = m.id and r.discipline = d.discipline and r.deleted_at is null);
update public.settings set value = 'true'::jsonb where key = 'ranks.cpc_points_enabled' and unit_id is null and deleted_at is null;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.run_draw(s.id) from public.division_stages s where s.division_id in (select x1 from fx union all select x2 from fx union all select x3 from fx union all select x4 from fx union all select x5 from fx union all select x6 from fx);
reset role;
select is((select count(*)::int from public.division_cpc_rating_snapshots where division_id = (select x1 from fx)), 4, 'the guest and three members are frozen');
select is((select count(*)::int from public.division_cpc_rating_snapshots where division_id = (select x5 from fx)), 0, 'an event that opted out of CPC changes freezes nothing');
select is((select team_strength from public.division_cpc_rating_snapshots where division_id = (select x6 from fx) and member_id = (select mid from us where role = 'd1')), 3.000::numeric, 'a doubles team is the mean of its partners (2.800 and 3.200)');
select is((select team_strength from public.division_cpc_rating_snapshots where division_id = (select x6 from fx) and member_id = (select mid from us where role = 'd4')), 2.500::numeric, 'the other team is 2.500');

-- every match: the lower strength number wins 11-4
create temp table ent as
  select e.id as entry, min(u.strength) as strength from public.entries e
  join public.entry_members em on em.entry_id = e.id join us u on u.mid = em.member_id group by e.id
  union all select eg.entry_id, 99 from public.entry_guests eg;
grant select on ent to public;
select pg_temp.as_user((select u from us where role = 'ref')); set local role authenticated;
select public.enter_score(m.id, case when (select strength from ent where entry = m.entry_a_id) < (select strength from ent where entry = m.entry_b_id)
    then '[{"a":11,"b":4}]'::jsonb else '[{"a":4,"b":11}]'::jsonb end)
  from public.matches m join public.division_stages s on s.id = m.division_stage_id
  where s.division_id in (select x1 from fx union all select x2 from fx union all select x3 from fx union all select x4 from fx union all select x5 from fx union all select x6 from fx)
    and m.status = 'scheduled' and m.entry_a_id is not null and m.entry_b_id is not null;
select public.finalize_match(m.id) from public.matches m join public.division_stages s on s.id = m.division_stage_id
  where s.division_id in (select x1 from fx union all select x2 from fx union all select x3 from fx union all select x4 from fx union all select x5 from fx union all select x6 from fx)
    and m.status = 'in_progress';
reset role;
select is((select count(*)::int from public.division_stages where division_id in (select x1 from fx union all select x2 from fx union all select x3 from fx union all select x4 from fx union all select x5 from fx union all select x6 from fx) and status = 'completed'), 6, 'all six round robins are complete');

select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.finalize_division((select x1 from fx));
select public.finalize_division((select x2 from fx));
select public.finalize_division((select x3 from fx));
select public.finalize_division((select x4 from fx));
select public.finalize_division((select x5 from fx));
select public.finalize_division((select x6 from fx));
reset role;

-- cpc-v2: a first match to 11 (K 0.250); the team strengths no longer matter, only the margin
create function pg_temp.d(t numeric, o numeric, pf int, pa int) returns numeric language sql as $$ select core.cpc_margin_delta(pf, pa, 11, 1, 0) $$;
create function pg_temp.fin(p numeric, delta numeric) returns numeric language sql as $$ select core.cpc_rating_points(p + delta) $$;
create function pg_temp.pts(p_role text) returns numeric language sql as
$$ select r.points from public.member_cpc_ratings r where r.member_id = (select mid from us where role = p_role) and r.deleted_at is null
  and r.discipline = case when p_role like 'd%' then 'doubles' else 'singles' end $$;
create function pg_temp.cnt(p_role text) returns integer language sql as
$$ select r.eligible_match_count from public.member_cpc_ratings r where r.member_id = (select mid from us where role = p_role) and r.deleted_at is null
  and r.discipline = case when p_role like 'd%' then 'doubles' else 'singles' end $$;
create function pg_temp.rank_code(p_role text) returns text language sql as
$$ select k.code from public.member_ranks mr join public.ranks k on k.id = mr.rank_id where mr.member_id = (select mid from us where role = p_role) and mr.deleted_at is null $$;

-- ---- two divisions with the same frozen 2.900 start: each change is applied relative to the current points
select is(pg_temp.pts('s1'),
  pg_temp.fin(pg_temp.fin(2.900, 2 * pg_temp.d(2.9, 2.9, 11, 4) + pg_temp.d(2.9, 3.5, 11, 4)),
    pg_temp.fin(2.900, 2 * pg_temp.d(2.9, 2.9, 11, 4)) - 2.900),
  's1 (wins all) keeps both divisions: the second applies its own change to the points after the first');
select is(pg_temp.pts('s3'),
  pg_temp.fin(pg_temp.fin(2.900, 2 * pg_temp.d(2.9, 2.9, 4, 11) + pg_temp.d(2.9, 3.5, 11, 4)),
    pg_temp.fin(2.900, 2 * pg_temp.d(2.9, 2.9, 4, 11)) - 2.900),
  's3 (loses to the members, beats the 3.500 guest) keeps both divisions');
select is(pg_temp.cnt('s1'), 5, 'three matches in the first division and two in the second: five, each counted once');
select is((select count(*)::int from public.member_cpc_rating_history h where h.member_id = (select mid from us where role = 's1') and h.entry_type = 'division_finalization'), 2, 'one history row for each division');
select is((select count(*)::int from public.member_cpc_rating_history h where h.member_id = (select mid from us where role = 's1') and h.entry_type = 'division_finalization' and h.points_before is not null), 2, 'with before and after values');

-- ---- a guest: used as an opponent strength, never rated or ranked
select is((select points from public.event_participant_cpc_ratings where discipline = 'singles' and participant_id = (select g_part from fx)), 3.500::numeric, 'the guest keeps the assessed 3.500');
select is((select version from public.event_participant_cpc_ratings where discipline = 'singles' and participant_id = (select g_part from fx)), 1, 'and it was never rewritten');
select is((select count(*)::int from public.member_cpc_rating_history where division_id = (select x1 from fx)), 3, 'only the three members have points history in that division');

-- ---- 8.000 and 2.000 limits
select is(pg_temp.pts('u1'), 8.000::numeric, 'a 7.990 player who beats an equal player is capped at 8.000');
select is(pg_temp.rank_code('u1'), 'open', 'and is Professional (Open)');
select is(pg_temp.pts('u2'), pg_temp.fin(7.990, pg_temp.d(7.99, 7.99, 4, 11)), 'the equal 7.990 player who lost drops by the same amount');
select is(pg_temp.pts('u4'), 2.000::numeric, 'a 2.010 player who loses to an equal player is floored at 2.000');
select is(pg_temp.pts('u3'), pg_temp.fin(2.010, pg_temp.d(2.01, 2.01, 11, 4)), 'the equal 2.010 winner gains');
select is(pg_temp.rank_code('u4'), 'beginner-low', 'a 2.000 player is Beginner Low');

-- ---- the event opt-out
select is((select count(*)::int from public.member_cpc_rating_history where division_id = (select x5 from fx)), 0, 'no points history for the opted-out event');
select is(pg_temp.pts('o1'), 2.900::numeric, 'the opted-out winner keeps 2.900');
select is(pg_temp.pts('o2'), 2.900::numeric, 'and the loser keeps 2.900');
select is(pg_temp.cnt('o1'), 0, 'and no played matches are counted');

-- ---- doubles: each partner gets the change of the match (K 0.250 x margin 7/11) added to their own starting rating
select is(pg_temp.pts('d1'), pg_temp.fin(2.800, pg_temp.fin(2.800, pg_temp.d(3.0, 2.5, 11, 4)) - 2.800), 'partner 1 of the winning pair');
select is(pg_temp.pts('d2'), pg_temp.fin(3.200, pg_temp.fin(2.800, pg_temp.d(3.0, 2.5, 11, 4)) - 2.800), 'partner 2 gets the same team result from their own start');
select is(pg_temp.pts('d3'), pg_temp.fin(2.400, pg_temp.fin(2.400, pg_temp.d(2.5, 3.0, 4, 11)) - 2.400), 'a partner of the losing pair (an upset score gains)');
select cmp_ok(pg_temp.pts('d1'), '>', 2.800::numeric, 'a partner of the winning pair gains: 11-4 at K 0.250');
select cmp_ok(pg_temp.pts('d3'), '<', 2.400::numeric, 'and a partner of the losing pair loses');
select is(pg_temp.cnt('d2'), 1, 'one match counted for each doubles partner');
select is(pg_temp.rank_code('d2'), 'advanced-low', 'the club rank follows the higher rating: doubles 3.165 but singles 4.200 stays Advanced Low');
select is((select r.points from public.member_cpc_ratings r where r.member_id = (select mid from us where role = 'd2') and r.discipline = 'singles' and r.deleted_at is null), 4.200::numeric, 'a doubles division never changes the singles rating');
select is(pg_temp.rank_code('d1'), 'novice-high', 'a doubles-only player is ranked by the doubles rating (2.765 is Novice High)');
select is((select count(*)::int from public.member_cpc_rating_history where division_id = (select x6 from fx) and discipline = 'doubles'), 4, 'the doubles division wrote four doubles history rows');
select is((select count(*)::int from public.member_cpc_rating_history where division_id = (select x1 from fx) and discipline = 'singles'), 3, 'and a singles division wrote singles rows');

select * from finish();
rollback;
