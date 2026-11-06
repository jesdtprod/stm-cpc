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
  (select id from public.format_templates where stages -> 0 ->> 'stage_type' = 'round_robin' and jsonb_array_length(stages) = 1 and deleted_at is null order by id limit 1) as tpl,
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

select pg_temp.as_user((select u from us where role='admin'));
set local role authenticated;
select throws_ok(format($f$select public.enter_score(%L, '[{"a":10,"b":8}]')$f$, (select f1 from st)), '22023', null, 'Reject below target before saving');
select throws_ok(format($f$select public.enter_score(%L, '[{"a":11,"b":10}]')$f$, (select f1 from st)), '22023', null, 'Reject win-by rule before saving');
select throws_ok(format($f$select public.enter_score(%L, '[{"a":-1,"b":11}]')$f$, (select f1 from st)), '22023', null, 'Reject negative score before saving');
select throws_ok(format($f$select public.enter_score(%L, '[{"a":11.5,"b":8}]')$f$, (select f1 from st)), '22023', null, 'Reject decimal score before saving');
select throws_ok(format($f$select public.enter_score(%L, '[{"a":"11","b":8}]')$f$, (select f1 from st)), '22023', null, 'Reject numeric string before saving');
select throws_ok(format($f$select public.enter_score(%L, '[{"a":"x","b":8}]')$f$, (select f1 from st)), '22023', null, 'Reject non-numeric score before saving');
select throws_ok(format($f$select public.enter_score(%L, '[]')$f$, (select f1 from st)), '22023', null, 'Reject empty games before saving');
select throws_ok(format($f$select public.enter_score(%L, '[{"a":100,"b":8}]')$f$, (select f1 from st)), '22023', null, 'Reject above storage limit before saving');
reset role;
select is((select count(*)::int from public.match_games where match_id=(select f1 from st)),0,'Invalid scores write no game rows');
select is((select status from public.matches where id=(select f1 from st)),'scheduled','Invalid scores preserve match state');
select pg_temp.as_user((select u from us where role='admin'));
set local role authenticated;
select lives_ok(format($f$select public.enter_score(%L, '[{"a":11,"b":8}]')$f$, (select f1 from st)),'Accept 11-8');
select lives_ok(format($f$select public.enter_score(%L, '[{"a":12,"b":10}]')$f$, (select f1 from st)),'Accept legal deuce');
reset role;
select is((select score_a::int from public.match_games where match_id=(select f1 from st) and game_no=1),12,'Save legal deuce score');
select * from finish();
rollback;
