begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create temp table hid as select core.ulid() as h1, core.ulid() as h2, core.ulid() as h3;
grant select on hid to public;
create temp table chain as select * from core.rank_chain((select id from public.orgs where code = 'cpc'));
grant select on chain to public;

create function pg_temp.mk(p_role text, p_no text, p_name text, p_idx int, p_active boolean) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); mid text := core.ulid(); org text := (select id from public.orgs where code = 'cpc');
begin
  insert into auth.users (id, email) values (u, lower(p_no) || '@members.example.test');
  insert into public.persons (id, org_id, display_name, gender, date_of_birth) values (per, org, p_name, 'male', '1990-01-01');
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (org, pid, (select id from public.roles where org_id = org and code = p_role));
  insert into public.members (id, org_id, person_id, profile_id, member_no) values (mid, org, per, pid, p_no);
  update public.members set status = 'invited' where id = mid;
  update public.members set status = 'pending_approval' where id = mid;
  update public.members set status = 'active' where id = mid;
  if p_idx is not null then
    insert into public.member_ranks (org_id, member_id, rank_id) values (org, mid, (select rank_id from chain where idx = p_idx));
  end if;
  if not p_active then
    update public.members set status = 'suspended', status_reason = 'test' where id = mid;
  end if;
  return u;
end $$;
create temp table us(role text primary key, u uuid, mid text);
grant select on us to public;
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2026-97601', 'Zzyzx Admin', null, true), null;
insert into us select 'low', pg_temp.mk('member', 'CPC-2026-97602', 'Zzyzx Low', 1, true), null;
insert into us select 'mid', pg_temp.mk('member', 'CPC-2026-97603', 'Zzyzx Mid', 4, true), null;
insert into us select 'high', pg_temp.mk('member', 'CPC-2026-97604', 'Zzyzx High', 7, true), null;
insert into us select 'twin', pg_temp.mk('member', 'CPC-2026-97605', 'Zzyzx Another Mid', 4, true), null;
insert into us select 'gone', pg_temp.mk('member', 'CPC-2026-97606', 'Zzyzx Suspended', 8, false), null;
insert into us select 'norank', pg_temp.mk('member', 'CPC-2026-97607', 'Zzyzx NoRank', null, true), null;
update us set mid = (select m.id from public.members m join public.profiles p on p.id = m.profile_id where p.auth_user_id = us.u);

-- ---- the ranking list
select pg_temp.as_user((select u from us where role = 'low')); set local role authenticated;
create temp table rl as select * from public.ranking_list();
reset role;
grant select on rl to public;
select ok((select count(*) from rl where display_name like 'Zzyzx%') = 4, 'four active, ranked members are listed (not the suspended one or the one without a rank)');
select is((select array_agg(display_name order by rank_idx desc, display_name) from rl where display_name like 'Zzyzx%'),
  array['Zzyzx High', 'Zzyzx Another Mid', 'Zzyzx Mid', 'Zzyzx Low'], 'highest rank first, ties by name');
select is((select rank_idx from rl where display_name = 'Zzyzx High'), 7, 'with the chain position');
select is((select rank_name from rl where display_name = 'Zzyzx Low'), (select r.name from public.ranks r join chain c on c.rank_id = r.id where c.idx = 1), 'and the rank name');
select ok((select bool_and(member_no like 'CPC-2026-%') from rl where display_name like 'Zzyzx%'), 'signed-in members see the actual member numbers in rankings');
select is((select count(*)::int from rl where member_id = (select mid from us where role = 'gone')), 0, 'a suspended member is not ranked');
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select is((select member_no from public.ranking_list() where display_name = 'Zzyzx High'), 'CPC-2026-97604', 'staff see the member ID');
select is((select count(*)::int from public.ranking_list((select category_id from rl where display_name = 'Zzyzx High')) where display_name = 'Zzyzx Low'), 0, 'a category filter leaves out the other categories');
reset role;
set local role anon;
select throws_ok($$select * from public.ranking_list()$$, '42501', null, 'the public cannot read the ranking');
reset role;

-- ---- the history screens read rank_history as it is
insert into public.rank_history (id, org_id, member_id, from_rank_id, to_rank_id, reason, occurred_at, revision)
values ((select h1 from hid), (select id from public.orgs where code = 'cpc'), (select mid from us where role = 'mid'),
  (select rank_id from chain where idx = 3), (select rank_id from chain where idx = 4), 'Override: first', now() - interval '3 days', 1);
insert into public.rank_history (id, org_id, member_id, from_rank_id, to_rank_id, reason, occurred_at, revision, reverses_id)
values ((select h2 from hid), (select id from public.orgs where code = 'cpc'), (select mid from us where role = 'mid'),
  (select rank_id from chain where idx = 4), (select rank_id from chain where idx = 3), 'Reversed after a correction: test', now() - interval '2 days', 1, (select h1 from hid));
insert into public.rank_history (id, org_id, member_id, from_rank_id, to_rank_id, reason, occurred_at, revision)
values ((select h3 from hid), (select id from public.orgs where code = 'cpc'), (select mid from us where role = 'mid'),
  (select rank_id from chain where idx = 3), (select rank_id from chain where idx = 4), 'Override: again', now() - interval '1 day', 1);
select pg_temp.as_user((select u from us where role = 'mid')); set local role authenticated;
create temp table hv as select * from public.rank_history_view();
reset role;
grant select on hv to public;
select is((select count(*)::int from hv), (select count(*)::int from public.rank_history where member_id = (select mid from us where role = 'mid')), 'the history list has one row for each rank_history row');
select is((select array_agg(id order by id) from hv), (select array_agg(id order by id) from public.rank_history where member_id = (select mid from us where role = 'mid')), 'and they are the same rows');
select is((select array_agg(id order by occurred_at desc, id desc) from hv), array[(select h3 from hid), (select h2 from hid), (select h1 from hid)], 'newest first');
select is((select reversed from hv where id = (select h1 from hid)), true, 'a move that was reversed says so');
select is((select is_reversal from hv where id = (select h2 from hid)), true, 'a reversal says so');
select is((select reversed from hv where id = (select h3 from hid)), false, 'a move still in force is not marked');
select is((select from_name || ' > ' || to_name from hv where id = (select h3 from hid)),
  (select (select r.name from public.ranks r join chain c on c.rank_id = r.id where c.idx = 3) || ' > ' || (select r.name from public.ranks r join chain c on c.rank_id = r.id where c.idx = 4)), 'with the rank names');

-- ---- who may read whose history
select pg_temp.as_user((select u from us where role = 'low')); set local role authenticated;
select throws_ok(format($f$select * from public.rank_history_view(%L)$f$, (select mid from us where role = 'mid')), '42501', 'you can read only your own rank history', 'a member cannot read another member''s history');
reset role;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select is((select count(*)::int from public.rank_history_view((select mid from us where role = 'mid'))), 3, 'staff can');
select throws_ok(format($f$select * from public.rank_history_view(%L)$f$, core.ulid()), '22023', null, 'an unknown member is refused');
reset role;
select is(has_function_privilege('anon', 'public.rank_history_view(text)', 'execute'), false, 'the public cannot call it');

select * from finish();
rollback;
