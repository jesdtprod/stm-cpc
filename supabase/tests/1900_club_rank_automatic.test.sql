begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as ev, core.ulid() as dv_s, core.ulid() as dv_d,
  (select id from public.categories where code = 'novice' and deleted_at is null) as cat_novice,
  (select id from public.format_templates where stages -> 0 ->> 'stage_type' = 'round_robin' and jsonb_array_length(stages) = 1 and deleted_at is null order by id limit 1) as tpl,
  current_date + 50 as day1;
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
create temp table us(role text primary key, u uuid, mid text);
grant select on us to public;
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2036-99001'), null;
insert into us select r, pg_temp.mk('member', 'CPC-2036-9901' || n), null
from (values ('a', 1), ('b', 2), ('c', 3), ('d', 4), ('e', 5), ('f', 6), ('g', 7), ('h', 8)) v(r, n);
update us set mid = (select m.id from public.members m join public.profiles p on p.id = m.profile_id where p.auth_user_id = us.u);

create function pg_temp.assess(p_role text, p_disc text, p_points numeric) returns void language plpgsql as $$
declare v integer;
begin
  select version into v from public.member_cpc_ratings where member_id = (select mid from us where role = p_role) and discipline = p_disc and deleted_at is null;
  perform public.set_member_cpc_rating((select mid from us where role = p_role), p_disc, p_points, coalesce(v, 0), core.ulid(), 'Fake assessment');
end $$;
grant execute on function pg_temp.assess(text, text, numeric) to public;
create function pg_temp.club(p_role text) returns jsonb language sql as
$$ select public.get_member_ratings((select mid from us where role = p_role)) -> 'club_rank' $$;
grant execute on function pg_temp.club(text) to public;
create function pg_temp.stored_rank(p_role text) returns text language sql as
$$ select k.code from public.member_ranks mr join public.ranks k on k.id = mr.rank_id where mr.member_id = (select mid from us where role = p_role) and mr.deleted_at is null $$;
grant execute on function pg_temp.stored_rank(text) to public;
create function pg_temp.rank_rows(p_role text) returns integer language sql as
$$ select count(*)::int from public.rank_history where member_id = (select mid from us where role = p_role) $$;
grant execute on function pg_temp.rank_rows(text) to public;

select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select pg_temp.assess('a', 'singles', 3.865); select pg_temp.assess('a', 'doubles', 2.929);
select pg_temp.assess('b', 'singles', 2.500); select pg_temp.assess('b', 'doubles', 3.750);
select pg_temp.assess('c', 'singles', 3.200); select pg_temp.assess('c', 'doubles', 3.200);
select pg_temp.assess('d', 'singles', 3.200);
select pg_temp.assess('e', 'doubles', 2.850);
reset role;

-- ---- the Club Rank is Classification(MAX(Singles, Doubles))
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select is(pg_temp.club('a') ->> 'name', 'Intermediate High', '1. Singles 3.865 above Doubles 2.929: the Club Rank follows Singles');
select is(pg_temp.club('a') ->> 'source', 'singles', '   and says it is based on Singles');
select is((pg_temp.club('a') ->> 'best_points')::numeric, 3.865::numeric, '   with the highest rating used');
select is(pg_temp.club('a') ->> 'range', '3.500–3.999', '   and the classification range');
select is(pg_temp.club('b') ->> 'name', 'Intermediate High', '2. Doubles 3.750 above Singles 2.500: the Club Rank follows Doubles');
select is(pg_temp.club('b') ->> 'source', 'doubles', '   based on Doubles');
select is(pg_temp.club('c') ->> 'name', 'Intermediate Low', '3. equal ratings share one classification');
select is(pg_temp.club('d') ->> 'name', 'Intermediate Low', '4. only Singles: follows Singles');
select is((public.get_member_ratings((select mid from us where role = 'd')) -> 'doubles' ->> 'points'), null::text, '   and Doubles is NR (NULL, not zero)');
select is((public.get_member_ratings((select mid from us where role = 'd')) -> 'doubles' ->> 'status'), 'NR', '   shown as NR');
select is(pg_temp.club('e') ->> 'name', 'Novice High', '5. only Doubles 2.850: follows Doubles');
select is(pg_temp.club('f') ->> 'name', 'Not Rated', '6. neither rating: Not Rated');
select is(pg_temp.club('f') ->> 'best_points', null::text, '   with no rating used');
reset role;
select is(pg_temp.stored_rank('a'), 'intermediate-high', 'the stored Club Rank matches (member a)');
select is(pg_temp.stored_rank('b'), 'intermediate-high', 'and member b');
select is(pg_temp.stored_rank('f'), null::text, 'an unrated member has no stored Club Rank');
select is(pg_temp.rank_rows('a'), 1, 'two ratings for one classification wrote one history row, not two');

-- ---- an administrator updating either rating recalculates the Club Rank immediately
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select pg_temp.assess('a', 'singles', 4.250);
select is(pg_temp.club('a') ->> 'name', 'Advanced Low', '7. admin raises Singles to 4.250: the Club Rank becomes Advanced Low');
select pg_temp.assess('a', 'doubles', 4.600);
select is(pg_temp.club('a') ->> 'name', 'Advanced High', '8. admin raises Doubles to 4.600: Advanced High');
select is(pg_temp.club('a') ->> 'source', 'doubles', '   now based on Doubles');
select is((public.get_member_ratings((select mid from us where role = 'a')) -> 'singles' ->> 'points')::numeric, 4.250::numeric, 'saving Doubles did not overwrite Singles');
reset role;
select is(pg_temp.stored_rank('a'), 'advanced-high', 'and the stored rank follows at once');
select is(pg_temp.rank_rows('a'), 3, 'one history row for each change of classification');

-- ---- no duplicate history when the classification does not change
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select pg_temp.assess('d', 'singles', 3.300);
select pg_temp.assess('d', 'singles', 3.450);
reset role;
select is(pg_temp.rank_rows('d'), 1, '10. updating a rating inside the same classification adds no rank history');
select is(pg_temp.stored_rank('d'), 'intermediate-low', '    and the rank is unchanged');

-- ---- boundaries at three decimals
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select pg_temp.assess('h', 'singles', 2.249);
select is(pg_temp.club('h') ->> 'name', 'Beginner Low', '2.249 is Beginner Low');
select pg_temp.assess('h', 'singles', 2.250);
select is(pg_temp.club('h') ->> 'name', 'Beginner High', '2.250 is Beginner High');
select pg_temp.assess('h', 'singles', 4.999);
select is(pg_temp.club('h') ->> 'name', 'Advanced High', '4.999 is Advanced High');
select pg_temp.assess('h', 'singles', 5.000);
select is(pg_temp.club('h') ->> 'name', 'Open/Professional', '5.000 is Professional (Open/Professional)');
reset role;

-- ---- initial self-submission, then locked
select pg_temp.as_user((select u from us where role = 'g')); set local role authenticated;
select is((public.get_member_ratings() ->> 'can_self_submit')::boolean, true, 'a member who has not submitted may submit');
select lives_ok(format('select public.submit_member_ratings(3.100, 2.800, %L)', (select core.ulid())), 'the member submits Singles and Doubles');
select is((public.get_member_ratings() -> 'singles' ->> 'status'), 'self', 'their Singles shows as self-assessed');
select is((public.get_member_ratings() -> 'club_rank' ->> 'name'), 'Intermediate Low', 'and the Club Rank follows the higher one (3.100)');
select throws_ok(format('select public.submit_member_ratings(3.500, null, %L)', core.ulid()), '42501', null, '9. a submitted rating is locked: the member cannot change it');
select throws_ok(format('select public.set_member_cpc_rating(%L, ''singles'', 3.500, 1, %L, ''Trying'')', (select mid from us where role = 'g'), core.ulid()), '42501', null, '   nor assess it through the administrator function');
select is((public.get_member_ratings() ->> 'can_self_submit')::boolean, false, '   and the form is no longer offered');
select throws_ok(format('select public.submit_member_ratings(1.500, null, %L)', core.ulid()), '22023', null, 'an out-of-range rating is refused');
reset role;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select pg_temp.assess('g', 'singles', 3.600);
select is(pg_temp.club('g') ->> 'name', 'Intermediate High', 'an administrator can still update it, and the Club Rank follows');
reset role;

-- ---- event eligibility uses the rating for the division's format
insert into public.member_cpc_ratings (org_id, unit_id, member_id, discipline)
select m.org_id, m.unit_id, m.id, d.discipline from public.members m cross join (values ('singles'), ('doubles')) d(discipline)
where m.deleted_at is null and m.status = 'active'
  and not exists (select 1 from public.member_cpc_ratings r where r.member_id = m.id and r.discipline = d.discipline and r.deleted_at is null);
update public.settings set value = 'true'::jsonb where key = 'ranks.cpc_points_enabled' and unit_id is null and deleted_at is null;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.create_event((select ev from fx), 'Eligibility Test', (select day1 from fx), (select day1 from fx), 'Hall', 0, null, null);
select public.create_division((select dv_s from fx), (select ev from fx), 'Singles Novice', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.create_division((select dv_d from fx), (select ev from fx), 'Doubles Novice', (select cat_novice from fx), 'doubles', null, null, null, null, null, (select tpl from fx), null);
select public.set_event_status((select ev from fx), 'registration_open', null);
reset role;
select is(core.registration_problem((select mid from us where role = 'b'), (select dv_s from fx), true), null::text,
  'b: Singles 2.500 is Novice, so the Novice singles division is open to them');
select ok(core.registration_problem((select mid from us where role = 'b'), (select dv_d from fx), true) like 'This division is for a different category%',
  'b: their Doubles 3.750 is Intermediate, so the Novice doubles division is not, even though their Singles fits (the Club Rank is not used)');
select is(core.registration_problem((select mid from us where role = 'd'), (select dv_d from fx), true),
  'You have no doubles rating yet, so you cannot join a ranked division.', 'd has no Doubles rating, so a doubles division needs one');
select is(core.registration_problem((select mid from us where role = 'e'), (select dv_s from fx), true),
  'You have no singles rating yet, so you cannot join a ranked division.', 'e has no Singles rating, so a singles division needs one');
select is(core.registration_problem((select mid from us where role = 'e'), (select dv_d from fx), true), null::text,
  'e: Doubles 2.850 is Novice High, so the doubles division is open to them');

-- ---- the Club Rank cannot be set by hand while ratings are on (migration 1910)
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select throws_ok(format('select public.override_member_rank(%L, (select id from public.ranks where code = ''novice-low'' and deleted_at is null), ''Trying by hand'', %L)', (select mid from us where role = 'b'), core.ulid()),
  '22023', null, 'a manual Club Rank override is refused while ratings are on');
reset role;
select is(pg_temp.stored_rank('b'), 'intermediate-high', 'and the Club Rank is unchanged');

select * from finish();
rollback;
