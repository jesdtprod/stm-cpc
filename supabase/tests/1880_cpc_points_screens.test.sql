begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  (select r.id from public.ranks r where r.code = 'novice-high' and r.deleted_at is null) as rank_id,
  core.ulid() as k1, core.ulid() as k2, core.ulid() as k3, core.ulid() as k4, core.ulid() as k5;
grant select on fx to public;
create function pg_temp.mk(p_role text, p_no text, p_ranked boolean) returns uuid language plpgsql as $$
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
  if p_ranked then insert into public.member_ranks (org_id, member_id, rank_id) values (org, mid, (select rank_id from fx)); end if;
  return u;
end $$;
create temp table us(role text primary key, u uuid, mid text);
grant select on us to public;
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2035-98801', true), null;
insert into us select 'a', pg_temp.mk('member', 'CPC-2035-98802', true), null;   -- provisional, 3.100
insert into us select 'b', pg_temp.mk('member', 'CPC-2035-98803', true), null;   -- established, 3.400
insert into us select 'c', pg_temp.mk('member', 'CPC-2035-98804', false), null;  -- unrated and unranked
update us set mid = (select m.id from public.members m join public.profiles p on p.id = m.profile_id where p.auth_user_id = us.u);

-- the live setting may already be on; this suite starts from off (rolled back at the end)
update public.settings set value = 'false'::jsonb where key = 'ranks.cpc_points_enabled' and unit_id is null and deleted_at is null;
-- ---- the activation guard: refused until every active member has a points record
select throws_ok($$update public.settings set value = 'true'::jsonb where key = 'ranks.cpc_points_enabled' and unit_id is null and deleted_at is null$$,
  '22023', null, 'points cannot be turned on before the members are prepared');
select throws_ok($$update public.settings set value = '"yes"'::jsonb where key = 'ranks.cpc_points_enabled' and unit_id is null and deleted_at is null$$,
  '22023', 'this setting is on or off', 'the setting only accepts on or off');
select is((select value from public.settings where key = 'ranks.cpc_points_enabled' and unit_id is null and deleted_at is null), 'false'::jsonb, 'and it is still off');

select pg_temp.as_user((select u from us where role = 'a')); set local role authenticated;
select throws_ok(format('select public.initialize_member_cpc_ratings(%L)', (select k1 from fx)), '42501', null, 'a member cannot prepare the members');
select throws_ok('select public.cpc_points_status()', '42501', null, 'or read the admin counts');
reset role;

select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select lives_ok(format('select public.initialize_member_cpc_ratings(%L)', (select k2 from fx)), 'an administrator prepares the members');
select is((select (public.cpc_points_status() ->> 'prepared')::int), (select (public.cpc_points_status() ->> 'active_members')::int), 'every active member has a points record');
select is((select public.cpc_points_status() ->> 'enabled'), 'false', 'points are still off');
select public.set_member_cpc_rating((select mid from us where role = 'a'), 'singles', 3.100, 0 + (select version from public.member_cpc_ratings where discipline = 'singles' and member_id = (select mid from us where role = 'a') and deleted_at is null), (select k3 from fx), 'Fake assessed start');
select public.set_member_cpc_rating((select mid from us where role = 'b'), 'singles', 3.400, (select version from public.member_cpc_ratings where discipline = 'singles' and member_id = (select mid from us where role = 'b') and deleted_at is null), (select k4 from fx), 'Fake assessed start');
select public.set_member_cpc_rating((select mid from us where role = 'c'), 'doubles', 2.500, (select version from public.member_cpc_ratings where discipline = 'doubles' and member_id = (select mid from us where role = 'c') and deleted_at is null), (select k5 from fx), 'Fake doubles start');
select throws_ok(format('select public.set_member_cpc_rating(%L,''mixed'',2.500,0,%L,%L)', (select mid from us where role = 'c'), core.ulid(), 'Bad discipline'), '22023', null, 'the discipline must be singles or doubles');
reset role;
update public.member_cpc_ratings set eligible_match_count = 7 where discipline = 'singles' and member_id = (select mid from us where role = 'b') and deleted_at is null;
select lives_ok($$update public.settings set value = 'true'::jsonb where key = 'ranks.cpc_points_enabled' and unit_id is null and deleted_at is null$$, 'with every member prepared, points can be turned on');
update public.settings set value = 'false'::jsonb where key = 'ranks.cpc_points_enabled' and unit_id is null and deleted_at is null;

-- ---- ranking list as an administrator
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
create temp table staff_list as select * from public.cpc_ranking_list();
reset role;
grant select on staff_list to public;
select is((select singles_points from staff_list where member_id = (select mid from us where role = 'b')), 3.400::numeric, 'staff see points');
select is((select singles_provisional from staff_list where member_id = (select mid from us where role = 'a')), true, 'under five matches is provisional');
select is((select singles_provisional from staff_list where member_id = (select mid from us where role = 'b')), false, 'five or more is established');
select is((select singles_points from staff_list where member_id = (select mid from us where role = 'c')), null::numeric, 'a member with no assessment is unrated (NULL, not zero)');
select is((select singles_provisional from staff_list where member_id = (select mid from us where role = 'c')), false, 'and is not called provisional');
select is((select rank_name from staff_list where member_id = (select mid from us where role = 'c')), 'Novice Low (2.500–2.749)', 'a member rated only in Doubles has the Club Rank of that rating');
select is((select singles_matches from staff_list where member_id = (select mid from us where role = 'b')), 7, 'staff see the played-match count');
select ok((select singles_version from staff_list where member_id = (select mid from us where role = 'b')) >= 1, 'and the version needed to reassess');
select is((select array_agg(member_id order by pos) from (select member_id, row_number() over () as pos from staff_list
  where member_id in (select mid from us where mid is not null)) z where member_id in (select mid from us where role in ('a', 'b', 'c'))),
  (select array[(select mid from us where role = 'b'), (select mid from us where role = 'a'), (select mid from us where role = 'c')]), 'ordered by points, highest first, unrated last');
select ok((select count(*) from staff_list where member_id = (select mid from us where role = 'c')) = 1, 'unranked members are listed too');

select is((select doubles_points from staff_list where member_id = (select mid from us where role = 'c')), 2.500::numeric, 'doubles points are kept apart from singles');
select is((select singles_points from staff_list where member_id = (select mid from us where role = 'c')), null::numeric, 'the singles side of that member is still unrated');
select is((select doubles_provisional from staff_list where member_id = (select mid from us where role = 'c')), true, 'the doubles side has its own provisional status');
select is((select doubles_points from staff_list where member_id = (select mid from us where role = 'a')), null::numeric, 'a member rated only in singles has no doubles points');
select is((select doubles_version from staff_list where member_id = (select mid from us where role = 'c')) >= 1, true, 'staff get the doubles version for reassessment');

-- ---- a member sees only their own points
select pg_temp.as_user((select u from us where role = 'a')); set local role authenticated;
create temp table my_list as select * from public.cpc_ranking_list();
reset role;
grant select on my_list to public;
select is((select singles_points from my_list where member_id = (select mid from us where role = 'a')), 3.100::numeric, 'a member sees their own points');
select is((select singles_provisional from my_list where member_id = (select mid from us where role = 'a')), true, 'and their own provisional status');
select is((select singles_points from my_list where member_id = (select mid from us where role = 'b')), null::numeric, 'but not another member''s points');
select is((select singles_version from my_list where member_id = (select mid from us where role = 'b')), null::integer, 'or their version');

-- ---- the points history
select pg_temp.as_user((select u from us where role = 'a')); set local role authenticated;
select is((select count(*)::int from public.cpc_points_history_view()), 1, 'a member reads their own points history');
select is((select entry_type from public.cpc_points_history_view() limit 1), 'admin_assessment', 'an assessment row');
select is((select points_after from public.cpc_points_history_view() limit 1), 3.100::numeric, 'with the new points');
select is((select points_before from public.cpc_points_history_view() limit 1), null::numeric, 'and unrated before');
select is((select points_delta from public.cpc_points_history_view() limit 1), null::numeric, 'an assessment has no change amount');
select throws_ok(format('select * from public.cpc_points_history_view(%L)', (select mid from us where role = 'b')), '42501', null, 'a member cannot read another member''s points history');
reset role;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select is((select count(*)::int from public.cpc_points_history_view((select mid from us where role = 'b'))), 1, 'staff read anyone''s points history');
reset role;
select set_config('request.jwt.claims', '', true);
select throws_ok($$select * from core.cpc_ranking_list()$$, '42501', null, 'signed-out callers get nothing');

-- ---- browsers cannot call anything else
select is(has_function_privilege('anon', 'public.cpc_ranking_list(text)', 'execute'), false, 'the public cannot read the list');
select is(has_function_privilege('authenticated', 'public.cpc_points_history_view(text)', 'execute'), true, 'members can call the history view');

select * from finish();
rollback;
