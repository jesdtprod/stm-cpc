begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  (select id from public.ranks where code = 'beginner-low' and deleted_at is null) as beginner_low;
grant select on fx to public;

-- calculated ratings keep their real value below 2.000
select is(core.cpc_rating_points(1.851), 1.851::numeric, 'a calculated 1.851 stays 1.851');
select is(core.cpc_rating_points(0.4), 0.400::numeric, 'and 0.400 stays 0.400');
select is(core.cpc_rating_points(-1), 0.000::numeric, 'the floor is 0.000');
select is(core.cpc_rating_points(8.4), 8.000::numeric, 'the ceiling stays 8.000');
-- classification: everything below 2.250 is Beginner Low
select is(core.cpc_rank_for_points((select org from fx), 1.851), (select beginner_low from fx), '1.851 is Beginner Low');
select is(core.cpc_rank_for_points((select org from fx), 0.000), (select beginner_low from fx), '0.000 is Beginner Low');
select is(core.cpc_rank_for_points((select org from fx), 2.249), (select beginner_low from fx), '2.249 is still Beginner Low');
select is(core.cpc_rank_for_points((select org from fx), 2.250), (select id from public.ranks where code = 'beginner-high' and deleted_at is null), 'and 2.250 is Beginner High');
-- typed (assessed) ratings keep the 2.000-8.000 range
select throws_ok($$select core.cpc_rating_band_code(1.851)$$, '22023', null, 'an assessed rating below 2.000 is still refused');

-- the stored rating, its history and the frozen division inputs accept a value below 2.000
create function pg_temp.mk() returns text language plpgsql as $$
declare pid text := core.ulid(); per text := core.ulid(); mid text := core.ulid(); org text := (select org from fx);
begin
  insert into public.persons (id, org_id, display_name) values (per, org, 'Fake Low');
  insert into public.members (id, org_id, person_id, member_no) values (mid, org, per, 'CPC-2044-99001');
  return mid;
end $$;
create temp table m as select pg_temp.mk() as id;
grant select on m to public;
select lives_ok(format($f$insert into public.member_cpc_ratings (org_id, member_id, discipline, points, source, assessed_at, assessed_by)
  values (%L, %L, 'singles', 1.851, 'division_finalization', now(), (select id from public.profiles limit 1))$f$, (select org from fx), (select id from m)),
  'a rating of 1.851 can be stored');
select throws_ok(format($f$insert into public.member_cpc_ratings (org_id, member_id, discipline, points, source, assessed_at, assessed_by)
  values (%L, %L, 'doubles', -0.001, 'division_finalization', now(), (select id from public.profiles limit 1))$f$, (select org from fx), (select id from m)),
  '23514', null, 'a negative rating cannot');
select is((select points from public.member_cpc_ratings where member_id = (select id from m) and discipline = 'singles'), 1.851::numeric, 'and is read back exactly');

select * from finish();
rollback;
