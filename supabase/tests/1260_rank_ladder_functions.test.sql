begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as cat, core.ulid() as lad, core.ulid() as r1, core.ulid() as r2, core.ulid() as r3,
  core.ulid() as k1, core.ulid() as k2, core.ulid() as k3, core.ulid() as k4, core.ulid() as k5, core.ulid() as k6, core.ulid() as k7;
grant select on fx to public;

create function pg_temp.mk(p_org text, p_role text) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); rid text;
begin
  select id into rid from public.roles where org_id = p_org and code = p_role;
  insert into auth.users (id, email) values (u, p_role || '-' || u || '@example.test');
  insert into public.persons (id, org_id, display_name) values (per, p_org, 'Fake ' || p_role);
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, p_org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (p_org, pid, rid);
  return u;
end $$;
create temp table us(role text primary key, u uuid);
grant select on us to public;
insert into us values ('manager', pg_temp.mk((select org from fx), 'manager'));
insert into us values ('member', pg_temp.mk((select org from fx), 'member'));

insert into public.categories (id, org_id, code, name) values ((select cat from fx), (select org from fx), 't8-cat', 'T8 Cat');
insert into public.rank_ladders (id, org_id, category_id) values ((select lad from fx), (select org from fx), (select cat from fx));
insert into public.ranks (id, org_id, ladder_id, code, name, sort_order, is_starting) values
  ((select r1 from fx), (select org from fx), (select lad from fx), 't8-low', 'T8 Low', 0, true),
  ((select r2 from fx), (select org from fx), (select lad from fx), 't8-mid', 'T8 Mid', 1, false),
  ((select r3 from fx), (select org from fx), (select lad from fx), 't8-high', 'T8 High', 2, false);

-- ---- the club's rule is there
select is((select count(*)::int from public.rank_rules where deleted_at is null and conditions @> '{"bracket_tier": "H", "bracket_result": "won"}' and action = 'up' and levels = 1), 1, 'won the H bracket moves up one level');
select is((select count(*)::int from public.rank_rules where deleted_at is null and conditions @> '{"bracket_tier": "L", "bracket_result": "lost"}' and action = 'down' and levels = 1), 1, 'lost the L bracket moves down one level');
select is((select count(*)::int from public.rank_rules where deleted_at is null and action = 'retain' and levels = 0 and conditions ? 'bracket_tier'), 2, 'the other two retain');

-- ---- access
select is(has_function_privilege('anon', 'public.reorder_ranks(text,text[],text)', 'execute'), false, 'anonymous callers cannot reorder');
select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
select throws_ok(format($f$select public.reorder_ranks(%L, array[%L, %L, %L], %L)$f$, (select lad from fx), (select r3 from fx), (select r2 from fx), (select r1 from fx), (select k1 from fx)), '42501', null, 'a member cannot reorder ranks');
select throws_ok(format($f$select public.set_starting_rank(%L, %L)$f$, (select r2 from fx), (select k2 from fx)), '42501', null, 'nor change the starting rank');
reset role;

-- ---- reorder
select pg_temp.as_user((select u from us where role = 'manager'));
set local role authenticated;
select throws_ok(format($f$select public.reorder_ranks(%L, array[%L, %L], %L)$f$, (select lad from fx), (select r2 from fx), (select r1 from fx), (select k3 from fx)), '22023', 'the new order must list every rank of the ladder exactly once', 'a list that misses a rank is refused');
select throws_ok(format($f$select public.reorder_ranks(%L, array[%L, %L, %L], %L)$f$, (select lad from fx), (select r2 from fx), (select r2 from fx), (select r1 from fx), (select k3 from fx)), '22023', null, 'a repeated rank is refused');
create temp table o1 as select public.reorder_ranks((select lad from fx), array[(select r3 from fx), (select r1 from fx), (select r2 from fx)], (select k4 from fx)) as r;
reset role;
grant select on o1 to public;
select is((select r ->> 'ok' from o1), 'true', 'the new order is accepted');
select is((select string_agg(name, ', ' order by sort_order) from public.ranks where ladder_id = (select lad from fx) and deleted_at is null), 'T8 High, T8 Low, T8 Mid', 'the ranks are in the new order');
select is((select min(sort_order)::int from public.ranks where ladder_id = (select lad from fx)), 0, 'counting from 0');
select is((select count(*)::int from core.audit_log where action = 'ranks.reorder' and record_id = (select lad from fx)), 1, 'the change is in the audit log');
set local role authenticated;
select is((select public.reorder_ranks((select lad from fx), array[(select r3 from fx), (select r1 from fx), (select r2 from fx)], (select k4 from fx))), (select r from o1), 'the same key replays the first answer');
select is((select (public.reorder_ranks((select lad from fx), array[(select r3 from fx), (select r1 from fx), (select r2 from fx)], (select k5 from fx))) ->> 'unchanged'), 'true', 'the same order again changes nothing');
reset role;

-- ---- starting rank
select pg_temp.as_user((select u from us where role = 'manager'));
set local role authenticated;
select is((select public.set_starting_rank((select r2 from fx), (select k6 from fx)) ->> 'ok'), 'true', 'another rank becomes the starting rank');
reset role;
select is((select count(*)::int from public.ranks where ladder_id = (select lad from fx) and is_starting and deleted_at is null), 1, 'the ladder still has exactly one starting rank');
select is((select name from public.ranks where ladder_id = (select lad from fx) and is_starting and deleted_at is null), 'T8 Mid', 'and it is the new one');
set local role authenticated;
select is((select (public.set_starting_rank((select r2 from fx), (select k7 from fx))) ->> 'unchanged'), 'true', 'setting it again changes nothing');
reset role;

select * from finish();
rollback;
