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
  core.ulid() as cat1, core.ulid() as cat2, core.ulid() as lad1, core.ulid() as lad2,
  core.ulid() as rk0, core.ulid() as rk1, core.ulid() as rk2, core.ulid() as rk_other,
  core.ulid() as per1, core.ulid() as per2, core.ulid() as mem1, core.ulid() as mem2, core.ulid() as rule1;
grant select on fx to public;

-- ---- structure
select is((select count(*)::int from pg_class where relnamespace = 'public'::regnamespace and relrowsecurity
  and relname in ('categories', 'rank_ladders', 'ranks', 'rank_rules', 'member_ranks', 'rank_history')), 6, 'RLS is on for all six tables');
select is((select count(*)::int from pg_class c where c.relnamespace = 'public'::regnamespace
  and c.relname in ('categories', 'rank_ladders', 'ranks', 'rank_rules', 'member_ranks', 'rank_history')
  and obj_description(c.oid, 'pg_class') like 'class: %'), 6, 'every table has a class comment');

-- ---- categories
insert into public.categories (id, org_id, code, name, sort_order) values
  ((select cat1 from fx), (select org from fx), 't1-novice', 'Novice', 1),
  ((select cat2 from fx), (select org from fx), 't1-inter', 'Intermediate', 2);
select throws_ok(format($f$insert into public.categories (org_id, code, name) values (%L, 't1-novice', 'Again')$f$, (select org from fx)),
  '23505', null, 'a category code is unique among active categories');
select throws_ok(format($f$insert into public.categories (org_id, code, name) values (%L, 'Bad Code', 'x')$f$, (select org from fx)),
  '23514', null, 'a category code is lowercase letters, digits, dash or underscore');
select throws_ok(format($f$insert into public.categories (org_id, code, name) values (%L, 'blank', '   ')$f$, (select org from fx)),
  '23514', null, 'a category needs a name');

-- ---- ladders and ranks
insert into public.rank_ladders (id, org_id, category_id) values ((select lad1 from fx), (select org from fx), (select cat1 from fx));
select is((select overflow from public.rank_ladders where id = (select lad1 from fx)), 'stop', 'a ladder stops at its ends by default');
select throws_ok(format($f$insert into public.rank_ladders (org_id, category_id) values (%L, %L)$f$, (select org from fx), (select cat1 from fx)),
  '23505', null, 'a category has one active ladder');
select throws_ok(format($f$insert into public.rank_ladders (org_id, category_id, overflow) values (%L, %L, 'loop')$f$, (select org from fx), (select cat2 from fx)),
  '23514', null, 'overflow is chain or stop');
insert into public.rank_ladders (id, org_id, category_id) values ((select lad2 from fx), (select org from fx), (select cat2 from fx));

insert into public.ranks (id, org_id, ladder_id, code, name, sort_order, is_starting) values
  ((select rk0 from fx), (select org from fx), (select lad1 from fx), 'novice-low', 'Novice Low', 0, true),
  ((select rk1 from fx), (select org from fx), (select lad1 from fx), 'novice-high', 'Novice High', 1, false),
  ((select rk_other from fx), (select org from fx), (select lad2 from fx), 'inter-low', 'Intermediate Low', 0, false);
select throws_ok(format($f$insert into public.ranks (org_id, ladder_id, code, name, sort_order) values (%L, %L, 'dup-order', 'x', 1)$f$, (select org from fx), (select lad1 from fx)),
  '23505', null, 'a rank position is unique within a ladder');
select throws_ok(format($f$insert into public.ranks (org_id, ladder_id, code, name, sort_order) values (%L, %L, 'novice-low', 'x', 5)$f$, (select org from fx), (select lad1 from fx)),
  '23505', null, 'a rank code is unique within a ladder');
select throws_ok(format($f$insert into public.ranks (org_id, ladder_id, code, name, sort_order, is_starting) values (%L, %L, 'second-start', 'x', 6, true)$f$, (select org from fx), (select lad1 from fx)),
  '23505', null, 'a ladder has at most one starting rank');
select lives_ok(format($f$insert into public.ranks (org_id, ladder_id, code, name, sort_order) values (%L, %L, 'novice-low', 'Same code, other ladder', 9)$f$, (select org from fx), (select lad2 from fx)),
  'the same rank code may exist in another ladder');
select throws_ok(format($f$insert into public.ranks (org_id, ladder_id, code, name, sort_order) values (%L, %L, 'neg', 'x', -1)$f$, (select org from fx), (select lad1 from fx)),
  '23514', null, 'a rank position cannot be negative');

-- ---- rank rules
select lives_ok(format($f$insert into public.rank_rules (id, org_id, name, conditions, action, levels, min_rank_id, max_rank_id)
  values (%L, %L, 'Won H bracket: up one', '{"bracket_tier":"H","bracket_result":"won"}', 'up', 1, %L, %L)$f$,
  (select rule1 from fx), (select org from fx), (select rk0 from fx), (select rk1 from fx)), 'a valid rule is accepted');
select throws_ok(format($f$insert into public.rank_rules (org_id, name, conditions, action, levels) values (%L, 'x', '{"colour":"red"}', 'up', 1)$f$, (select org from fx)),
  '23514', null, 'an unknown condition key is rejected');
select throws_ok(format($f$insert into public.rank_rules (org_id, name, conditions, action, levels) values (%L, 'x', '{"bracket_tier":"Z"}', 'up', 1)$f$, (select org from fx)),
  '23514', null, 'a bad bracket tier is rejected');
select throws_ok(format($f$insert into public.rank_rules (org_id, name, conditions, action, levels) values (%L, 'x', '{"placement":"first"}', 'up', 1)$f$, (select org from fx)),
  '23514', null, 'placement must be a number');
select throws_ok(format($f$insert into public.rank_rules (org_id, name, conditions, action, levels) values (%L, 'x', '[1]', 'up', 1)$f$, (select org from fx)),
  '23514', null, 'conditions must be an object');
select lives_ok(format($f$insert into public.rank_rules (org_id, name, conditions, action, levels) values (%L, 'Empty conditions', '{}', 'retain', 0)$f$, (select org from fx)),
  'empty conditions with retain is allowed');
select throws_ok(format($f$insert into public.rank_rules (org_id, name, action, levels) values (%L, 'x', 'retain', 1)$f$, (select org from fx)),
  '23514', null, 'retain moves zero levels');
select throws_ok(format($f$insert into public.rank_rules (org_id, name, action, levels) values (%L, 'x', 'up', 0)$f$, (select org from fx)),
  '23514', null, 'up or down must move at least one level');
select throws_ok(format($f$insert into public.rank_rules (org_id, name, action, levels) values (%L, 'x', 'sideways', 1)$f$, (select org from fx)),
  '23514', null, 'action is up, down or retain');
select throws_ok(format($f$insert into public.rank_rules (org_id, name, action, levels, min_rank_id, max_rank_id) values (%L, 'x', 'up', 1, %L, %L)$f$,
  (select org from fx), (select rk0 from fx), (select rk_other from fx)), '22023', null, 'min and max rank must share a ladder');
select throws_ok(format($f$insert into public.rank_rules (org_id, name, action, levels, min_rank_id, max_rank_id) values (%L, 'x', 'up', 1, %L, %L)$f$,
  (select org from fx), (select rk1 from fx), (select rk0 from fx)), '22023', null, 'min rank cannot be above max rank');

-- ---- members for the rank tables
insert into public.persons (id, org_id, display_name) values
  ((select per1 from fx), (select org from fx), 'Fake Ranked One'), ((select per2 from fx), (select org from fx), 'Fake Ranked Two');
insert into public.members (id, org_id, person_id, member_no) values
  ((select mem1 from fx), (select org from fx), (select per1 from fx), 'CPC-2026-90001'),
  ((select mem2 from fx), (select org from fx), (select per2 from fx), 'CPC-2026-90002');

-- ---- member_ranks
insert into public.member_ranks (org_id, member_id, rank_id) values ((select org from fx), (select mem1 from fx), (select rk0 from fx));
select throws_ok(format($f$insert into public.member_ranks (org_id, member_id, rank_id) values (%L, %L, %L)$f$, (select org from fx), (select mem1 from fx), (select rk1 from fx)),
  '23505', null, 'a member has one current rank');
select throws_ok(format($f$insert into public.member_ranks (org_id, member_id, rank_id) values (%L, %L, %L)$f$, (select org from fx), (select mem2 from fx), core.ulid()),
  '22023', null, 'the rank must exist');
select lives_ok(format($f$update public.member_ranks set rank_id = %L, set_by_rule_id = %L where member_id = %L$f$, (select rk1 from fx), (select rule1 from fx), (select mem1 from fx)),
  'a rank can move');

-- ---- retire-not-delete guards
select set_config('core.rpc', 'on', true);
select throws_ok(format($f$update public.ranks set deleted_at = now(), deleted_by = 'system', delete_reason = 't' where id = %L$f$, (select rk1 from fx)),
  '23503', null, 'a rank held by a member cannot be deleted');
select throws_ok(format($f$update public.rank_ladders set deleted_at = now(), deleted_by = 'system', delete_reason = 't' where id = %L$f$, (select lad1 from fx)),
  '23503', null, 'a ladder with ranks cannot be deleted');
select throws_ok(format($f$update public.categories set deleted_at = now(), deleted_by = 'system', delete_reason = 't' where id = %L$f$, (select cat1 from fx)),
  '23503', null, 'a category with a ladder cannot be deleted');
select lives_ok(format($f$update public.ranks set deleted_at = now(), deleted_by = 'system', delete_reason = 't' where id = %L$f$, (select rk_other from fx)),
  'an unused rank can be soft-deleted');
select set_config('core.rpc', 'off', true);
select throws_ok(format($f$insert into public.member_ranks (org_id, member_id, rank_id) values (%L, %L, %L)$f$, (select org from fx), (select mem2 from fx), (select rk_other from fx)),
  '22023', null, 'a deleted rank cannot be given to a member');
select throws_ok(format($f$delete from public.ranks where id = %L$f$, (select rk0 from fx)), '42501', null, 'ranks cannot be hard-deleted');
select lives_ok(format($f$update public.categories set is_active = false where id = %L$f$, (select cat1 from fx)), 'a category in use can be retired with is_active');

-- ---- rank_history (needs real divisions: 1040 added the foreign keys)
insert into public.events (id, org_id, name, starts_on, ends_on, payload_hash)
  values ('01H0000000000000000000EVN1', (select org from fx), 'T Rank Event', '2026-12-05', '2026-12-05', repeat('a', 64));
insert into public.divisions (id, org_id, event_id, name, category_id, format, format_snapshot, scoring_snapshot, payload_hash) values
  ('01H0000000000000000000DVN1', (select org from fx), '01H0000000000000000000EVN1', 'T Rank Div 1', (select cat1 from fx), 'singles', '[{"stage_type":"round_robin"}]', '{}', repeat('b', 64)),
  ('01H0000000000000000000DVN2', (select org from fx), '01H0000000000000000000EVN1', 'T Rank Div 2', (select cat1 from fx), 'singles', '[{"stage_type":"round_robin"}]', '{}', repeat('c', 64));
insert into public.rank_history (id, org_id, member_id, from_rank_id, to_rank_id, rule_id, division_id, reason)
  values ('01H0000000000000000000RH01', (select org from fx), (select mem1 from fx), (select rk0 from fx), (select rk1 from fx), (select rule1 from fx), '01H0000000000000000000DVN1', 'won H');
select throws_ok(format($f$insert into public.rank_history (org_id, member_id, from_rank_id, to_rank_id, division_id) values (%L, %L, %L, %L, '01H0000000000000000000DVN1')$f$,
  (select org from fx), (select mem1 from fx), (select rk1 from fx), (select rk0 from fx)), '23505', null, 'a division moves a member at most once');
select lives_ok(format($f$insert into public.rank_history (org_id, member_id, from_rank_id, to_rank_id, division_id) values (%L, %L, %L, %L, '01H0000000000000000000DVN2')$f$,
  (select org from fx), (select mem1 from fx), (select rk1 from fx), (select rk0 from fx)), 'another division may move the same member');
select lives_ok(format($f$insert into public.rank_history (org_id, member_id, from_rank_id, to_rank_id, division_id, reverses_id, reason) values (%L, %L, %L, %L, '01H0000000000000000000DVN1', '01H0000000000000000000RH01', 'correction')$f$,
  (select org from fx), (select mem1 from fx), (select rk1 from fx), (select rk0 from fx)), 'a reversing row for the same division and member is allowed');
select throws_ok(format($f$insert into public.rank_history (org_id, member_id, from_rank_id, to_rank_id, reverses_id) values (%L, %L, %L, %L, '01H0000000000000000000RH01')$f$,
  (select org from fx), (select mem1 from fx), (select rk1 from fx), (select rk0 from fx)), '23505', null, 'a row can be reversed only once');
select throws_ok($$update public.rank_history set reason = 'x'$$, '42501', null, 'rank history cannot be edited');
select throws_ok($$delete from public.rank_history$$, '42501', null, 'rank history cannot be deleted');

-- ---- row-level security with real users
create temp table us(role text primary key, u uuid);
grant select on us to public;
insert into us values ('admin', pg_temp.mk((select org from fx), 'admin'));
insert into us values ('manager', pg_temp.mk((select org from fx), 'manager'));
insert into us values ('front_desk', pg_temp.mk((select org from fx), 'front_desk'));
insert into us values ('member1', pg_temp.mk((select org from fx), 'member', (select per1 from fx)));
insert into us values ('member2', pg_temp.mk((select org from fx), 'member', (select per2 from fx)));
update public.members set profile_id = (select p.id from public.profiles p where p.auth_user_id = (select u from us where role = 'member1')) where id = (select mem1 from fx);
update public.members set profile_id = (select p.id from public.profiles p where p.auth_user_id = (select u from us where role = 'member2')) where id = (select mem2 from fx);
insert into public.member_ranks (org_id, member_id, rank_id) values ((select org from fx), (select mem2 from fx), (select rk0 from fx));

select pg_temp.as_user((select u from us where role = 'member1'));
set local role authenticated;
select cmp_ok((select count(*)::int from public.categories), '>=', 2, 'a member reads the categories');
select cmp_ok((select count(*)::int from public.ranks), '>=', 2, 'a member reads the ranks');
select is((select count(*)::int from public.rank_rules), 0, 'a member cannot read the rank rules');
select is((select count(*)::int from public.member_ranks), 1, 'a member sees only their own current rank');
select is((select rank_id from public.member_ranks), (select rk1 from fx), 'and it is the right one');
select is((select count(*)::int from public.rank_history), 3, 'a member sees only their own rank history');
select throws_ok(format($f$insert into public.categories (org_id, code, name) values (%L, 'sneaky', 'Sneaky')$f$, (select org from fx)), '42501', null, 'a member cannot create a category');
select lives_ok($$update public.ranks set name = 'Hacked'$$, 'a member update of a rank runs but matches no visible row');
select throws_ok($$update public.member_ranks set rank_id = rank_id$$, '42501', null, 'a member cannot change a current rank');
select throws_ok($$insert into public.rank_history (org_id, member_id, to_rank_id) values (core.ulid(), core.ulid(), core.ulid())$$, '42501', null, 'a member cannot write rank history');
reset role;
select is((select count(*)::int from public.ranks where name = 'Hacked'), 0, 'and no rank was changed');

select pg_temp.as_user((select u from us where role = 'member2'));
set local role authenticated;
select is((select count(*)::int from public.rank_history), 0, 'another member sees none of that history');
select is((select count(*)::int from public.member_ranks), 1, 'and only their own rank');
reset role;

select pg_temp.as_user((select u from us where role = 'front_desk'));
set local role authenticated;
select is((select count(*)::int from public.member_ranks), 2, 'front desk (members.read) sees every current rank');
select throws_ok(format($f$insert into public.categories (org_id, code, name) values (%L, 'desk', 'Desk')$f$, (select org from fx)), '42501', null, 'front desk cannot create a category');
reset role;

select pg_temp.as_user((select u from us where role = 'manager'));
set local role authenticated;
select lives_ok(format($f$insert into public.categories (org_id, code, name) values (%L, 't1-advanced', 'Advanced')$f$, (select org from fx)), 'a manager creates a category');
select lives_ok(format($f$update public.ranks set name = 'Novice Low (renamed)' where id = %L$f$, (select rk0 from fx)), 'a manager edits a rank');
select cmp_ok((select count(*)::int from public.rank_rules), '>=', 1, 'a manager reads the rank rules');
select lives_ok(format($f$insert into public.rank_rules (org_id, name, action, levels) values (%L, 'Mgr rule', 'retain', 0)$f$, (select org from fx)), 'a manager creates a rank rule');
select throws_ok(format($f$update public.member_ranks set rank_id = %L$f$, (select rk1 from fx)), '42501', null, 'even a manager cannot write member ranks directly');
select throws_ok($$update public.rank_history set reason = 'x'$$, '42501', null, 'nor rank history');
reset role;

-- ---- column privileges
select is(has_any_column_privilege('authenticated', 'public.member_ranks', 'insert') or has_any_column_privilege('authenticated', 'public.member_ranks', 'update'),
  false, 'clients have no write privilege on member_ranks');
select is(has_any_column_privilege('authenticated', 'public.rank_history', 'insert') or has_any_column_privilege('authenticated', 'public.rank_history', 'update'),
  false, 'clients have no write privilege on rank_history');
select is(has_column_privilege('authenticated', 'public.ranks', 'sort_order', 'update'), true, 'managers can reorder ranks (column grant)');
select is(has_column_privilege('authenticated', 'public.ranks', 'ladder_id', 'update'), true, 'ladder_id is editable (a move between ladders is checked by the unique indexes)');

select * from finish();
rollback;
