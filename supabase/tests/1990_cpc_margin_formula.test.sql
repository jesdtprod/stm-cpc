begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

-- ---- K by completed rated matches
select is(core.cpc_rating_k(0), 0.250::numeric, 'K is 0.250 with no completed matches (NR)');
select is(core.cpc_rating_k(5), 0.250::numeric, 'and 0.250 up to five (provisional)');
select is(core.cpc_rating_k(6), 0.150::numeric, '0.150 from six (developing)');
select is(core.cpc_rating_k(15), 0.150::numeric, 'to fifteen');
select is(core.cpc_rating_k(16), 0.100::numeric, '0.100 from sixteen (established)');
select is(core.cpc_rating_k(30), 0.100::numeric, 'to thirty');
select is(core.cpc_rating_k(31), 0.050::numeric, '0.050 from thirty-one (highly established)');
select is(core.cpc_rating_k(500), 0.050::numeric, 'and stays there');
select throws_ok('select core.cpc_rating_k(-1)', '22023', null, 'a negative match count is refused');

-- ---- the worked example: everyone NR (3.500), K 0.250, A wins 11-5, T 11
select is(core.cpc_rating_points(3.500 + core.cpc_margin_delta(11, 5, 11, 1, 0)), 3.636::numeric, 'Team A: 3.500 + 0.250 x (11 - 5) / 11 = 3.636');
select is(core.cpc_rating_points(3.500 + core.cpc_margin_delta(5, 11, 11, 1, 0)), 3.364::numeric, 'Team B: 3.500 - 0.250 x (11 - 5) / 11 = 3.364');
select is(core.cpc_rating_band_code(3.636), 'intermediate-high', 'Team A is Intermediate High');
select is(core.cpc_rating_band_code(3.364), 'intermediate-low', 'Team B is Intermediate Low');
-- an existing rating is used instead of 3.500
select is(core.cpc_rating_points(2.800 + core.cpc_margin_delta(11, 5, 11, 1, 0)), 2.936::numeric, 'a rated player starts from their own rating: 2.800 -> 2.936');
-- the match's own target and K
select is(round(core.cpc_margin_delta(11, 5, 11, 1, 6), 6), 0.081818::numeric, 'at six completed matches K is 0.150');
select is(round(core.cpc_margin_delta(21, 15, 21, 1, 0), 6), 0.071429::numeric, 'a final played to 21 divides by 21');
select is(round(core.cpc_margin_delta(29, 25, 11, 3, 0), 6), 0.030303::numeric, 'a best of three (11-8, 7-11, 11-6) counts the total margin over three games');
select is(core.cpc_margin_delta(11, 11, 11, 1, 0), 0.000::numeric, 'a tied total margin changes nothing');
select throws_ok('select core.cpc_margin_delta(11, 5, 0, 1, 0)', '22023', null, 'a zero target is refused');
select throws_ok('select core.cpc_margin_delta(-1, 5, 11, 1, 0)', '22023', null, 'negative points are refused');
select throws_ok('select core.cpc_margin_delta(11, 5, 11, 0, 0)', '22023', null, 'a match with no games is refused');
select is(has_function_privilege('authenticated', 'core.cpc_margin_delta(integer,integer,integer,integer,integer)', 'execute'), false, 'browsers cannot call the calculation');

-- ---- a division with players who have no rating (NR): they start at 3.500 and are rated by the division
create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as ev, core.ulid() as x1, core.ulid() as x2,
  (select id from public.categories where code = 'novice' and deleted_at is null) as cat_novice,
  (select id from public.format_templates where stages -> 0 ->> 'stage_type' = 'round_robin' and jsonb_array_length(stages) = 1 and deleted_at is null order by id limit 1) as tpl,
  current_date + 100 as day1;
grant select on fx to public;
create function pg_temp.mk(p_role text, p_no text) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); mid text := core.ulid(); org text := (select org from fx);
begin
  insert into auth.users (id, email) values (u, lower(p_no) || '@members.example.test');
  insert into public.persons (id, org_id, display_name) values (per, org, 'Fake ' || p_no);
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (org, pid, (select id from public.roles where org_id = org and code = p_role));
  insert into public.members (id, org_id, person_id, profile_id, member_no) values (mid, org, per, pid, p_no);
  update public.members set status = 'invited' where id = mid;
  update public.members set status = 'pending_approval' where id = mid;
  update public.members set status = 'active' where id = mid;
  return u;
end $$;
create temp table us(role text primary key, u uuid, mid text, strength int);
grant select on us to public;
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2042-99001'), null, null;
insert into us select 'ref', pg_temp.mk('referee', 'CPC-2042-99002'), null, null;
insert into us select r, pg_temp.mk('member', 'CPC-2042-9901' || n), null, s from (values ('n1', 1, 1), ('n2', 2, 2), ('r1', 3, 1), ('n3', 4, 2)) v(r, n, s);
update us set mid = (select m.id from public.members m join public.profiles p on p.id = m.profile_id where p.auth_user_id = us.u);

update public.settings set value = 'false'::jsonb where key = 'events.registration_approval_required' and unit_id is null and deleted_at is null;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.set_member_cpc_rating((select mid from us where role = 'r1'), 'singles', 2.800, 0, core.ulid(), 'Fake assessment');
select public.create_event((select ev from fx), 'NR Test', (select day1 from fx), (select day1 from fx), 'Hall', 0, null, null);
select public.create_division((select x1 from fx), (select ev from fx), 'NR Singles', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.create_division((select x2 from fx), (select ev from fx), 'Rated And NR', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.set_event_status((select ev from fx), 'registration_open', null);
-- unrated players are entered by an administrator override (registration itself still checks the rating)
select public.register_for_event(core.ulid(), (select x1 from fx), null, (select mid from us where role = r), 'Fake override: NR entry') from (values ('n1'), ('n2')) v(r);
select public.register_for_event(core.ulid(), (select x2 from fx), null, (select mid from us where role = r), 'Fake override: NR entry') from (values ('r1'), ('n3')) v(r);
reset role;
insert into public.member_cpc_ratings (org_id, unit_id, member_id, discipline)
select m.org_id, m.unit_id, m.id, d.discipline from public.members m cross join (values ('singles'), ('doubles')) d(discipline)
where m.deleted_at is null and m.status = 'active'
  and not exists (select 1 from public.member_cpc_ratings r where r.member_id = m.id and r.discipline = d.discipline and r.deleted_at is null);
update public.settings set value = 'true'::jsonb where key = 'ranks.cpc_points_enabled' and unit_id is null and deleted_at is null;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.set_event_status((select ev from fx), 'registration_closed', null);
select lives_ok(format('select public.run_draw(%L)', (select id from public.division_stages where division_id = (select x1 from fx))), 'a division of players with no rating can be drawn');
select lives_ok(format('select public.run_draw(%L)', (select id from public.division_stages where division_id = (select x2 from fx))), 'so can one with a rated and an unrated player');
reset role;
select is((select starting_points from public.division_cpc_rating_snapshots where division_id = (select x1 from fx) and member_id = (select mid from us where role = 'n1')), 3.500::numeric, 'an NR player is frozen at 3.500');
select is((select starting_points from public.division_cpc_rating_snapshots where division_id = (select x2 from fx) and member_id = (select mid from us where role = 'r1')), 2.800::numeric, 'a rated player is frozen at their own rating');
select is((select algorithm_version from public.division_cpc_rating_snapshots where division_id = (select x1 from fx) limit 1), 'cpc-v2', 'the snapshots record the formula version');

create temp table ent as
  select u.role, u.strength, e.id as entry from us u join public.entry_members em on em.member_id = u.mid join public.entries e on e.id = em.entry_id where u.strength is not null;
grant select on ent to public;
-- the lower strength number wins 11-5
select pg_temp.as_user((select u from us where role = 'ref')); set local role authenticated;
select public.enter_score(m.id, case when (select strength from ent where entry = m.entry_a_id) < (select strength from ent where entry = m.entry_b_id)
    then '[{"a":11,"b":5}]'::jsonb else '[{"a":5,"b":11}]'::jsonb end)
  from public.matches m join public.division_stages s on s.id = m.division_stage_id where s.division_id in (select x1 from fx union all select x2 from fx) and m.status = 'scheduled';
select public.finalize_match(m.id) from public.matches m join public.division_stages s on s.id = m.division_stage_id
  where s.division_id in (select x1 from fx union all select x2 from fx) and m.status = 'in_progress';
reset role;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.finalize_division((select x1 from fx));
select public.finalize_division((select x2 from fx));
reset role;
create function pg_temp.pts(p_role text) returns numeric language sql as
$$ select r.points from public.member_cpc_ratings r where r.member_id = (select mid from us where role = p_role) and r.discipline = 'singles' and r.deleted_at is null $$;
create function pg_temp.code(p_role text) returns text language sql as
$$ select k.code from public.member_ranks mr join public.ranks k on k.id = mr.rank_id where mr.member_id = (select mid from us where role = p_role) and mr.deleted_at is null $$;
select is(pg_temp.pts('n1'), 3.636::numeric, 'the NR winner of an 11-5 match is rated 3.636');
select is(pg_temp.pts('n2'), 3.364::numeric, 'the NR loser is rated 3.364');
select is(pg_temp.pts('r1'), 2.936::numeric, 'a rated player who wins 11-5 from 2.800 is 2.936');
select is(pg_temp.pts('n3'), 3.364::numeric, 'an NR player who loses to a rated player is 3.364 (NR start is 3.500)');
select is(pg_temp.code('n1'), 'intermediate-high', 'their Club Rank follows: Intermediate High');
select is(pg_temp.code('n2'), 'intermediate-low', 'and Intermediate Low');
select is(pg_temp.code('r1'), 'novice-high', 'and 2.936 is Novice High');
select is((select r.eligible_match_count from public.member_cpc_ratings r where r.member_id = (select mid from us where role = 'n1') and r.discipline = 'singles' and r.deleted_at is null), 1, 'the NR player now has one completed rated match');
select is((select algorithm_version from public.member_cpc_rating_history where member_id = (select mid from us where role = 'n1') and entry_type = 'division_finalization'), 'cpc-v2', 'the history records the formula version');

select * from finish();
rollback;
