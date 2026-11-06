begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as ev, core.ulid() as d16, core.ulid() as d5,
  (select id from public.format_templates where lower(name) like 'split single elimination%' and deleted_at is null) as tpl,
  (select id from public.categories where code = 'novice' and deleted_at is null) as cat_novice,
  (select r.id from public.ranks r join public.rank_ladders l on l.id = r.ladder_id join public.categories c on c.id = l.category_id
    where c.code = 'novice' and r.deleted_at is null order by r.sort_order desc limit 1) as novice_top,
  current_date + 40 as day1;
grant select on fx to public;
create function pg_temp.mk(p_role text, p_no text) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); mid text := core.ulid(); org text := (select org from fx);
begin
  insert into auth.users (id, email) values (u, lower(p_no) || '@members.example.test');
  insert into public.persons (id, org_id, display_name, gender, date_of_birth) values (per, org, 'Fake ' || p_no, 'male', '1990-01-01');
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (org, pid, (select id from public.roles where org_id = org and code = p_role));
  insert into public.members (id, org_id, person_id, profile_id, member_no) values (mid, org, per, pid, p_no);
  update public.members set status = 'invited' where id = mid;
  update public.members set status = 'pending_approval' where id = mid;
  update public.members set status = 'active' where id = mid;
  insert into public.member_ranks (org_id, member_id, rank_id) values (org, mid, (select novice_top from fx));
  return u;
end $$;
create temp table us(role text primary key, u uuid);
grant select on us to public;
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2530-90001');
insert into us select 'ref', pg_temp.mk('referee', 'CPC-2530-90002');
insert into us select 'p' || i, pg_temp.mk('member', 'CPC-2530-9' || lpad((10 + i)::text, 4, '0')) from generate_series(1, 16) i;

select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.create_event((select ev from fx), 'Split Advance', (select day1 from fx), (select day1 from fx), 'Hall', 0, null, null);
select public.create_division((select d16 from fx), (select ev from fx), 'Sixteen', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.create_division((select d5 from fx), (select ev from fx), 'Five', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.set_event_status((select ev from fx), 'registration_open', null);
reset role;
update public.settings set value = 'false'::jsonb where key = 'events.registration_approval_required' and unit_id is null and deleted_at is null;
create function pg_temp.join_div(p_role text, p_div text) returns void language plpgsql as $$
begin
  perform pg_temp.as_user((select u from us where role = p_role));
  set local role authenticated;
  perform public.register_for_event(core.ulid(), p_div);
  reset role;
end $$;
grant execute on function pg_temp.join_div(text, text) to public;
select pg_temp.join_div('p' || i, (select d16 from fx)) from generate_series(1, 16) i;
select pg_temp.join_div('p' || i, (select d5 from fx)) from generate_series(1, 5) i;
create temp table stg as select
  (select id from public.division_stages where division_id = (select d16 from fx)) as s16,
  (select id from public.division_stages where division_id = (select d5 from fx)) as s5;
grant select on stg to public;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.set_event_status((select ev from fx), 'registration_closed', null);
select public.run_draw((select s16 from stg));
select public.run_draw((select s5 from stg));
reset role;

create function pg_temp.play(p_stage text, p_no integer, p_a_wins boolean) returns void language plpgsql as $$
declare mid text := (select id from public.matches where division_stage_id = p_stage and group_label is null and round_no = 1 and match_no = p_no);
begin
  perform pg_temp.as_user((select u from us where role = 'ref'));
  set local role authenticated;
  perform public.enter_score(mid, case when p_a_wins then '[{"a":11,"b":4}]'::jsonb else '[{"a":4,"b":11}]'::jsonb end);
  perform public.finalize_match(mid);
  reset role;
end $$;
grant execute on function pg_temp.play(text, integer, boolean) to public;

-- the player who is in Match 1 (side A) and the one in Match 2 (side B)
create temp table who as select
  (select u.role from us u join public.members m on m.id = (select em.member_id from public.entry_members em where em.entry_id = (select entry_a_id from public.matches where division_stage_id = (select s16 from stg) and group_label is null and match_no = 1))
    join public.profiles p on p.id = m.profile_id and p.auth_user_id = u.u limit 1) as a_role,
  (select u.role from us u join public.members m on m.id = (select em.member_id from public.entry_members em where em.entry_id = (select entry_b_id from public.matches where division_stage_id = (select s16 from stg) and group_label is null and match_no = 1))
    join public.profiles p on p.id = m.profile_id and p.auth_user_id = u.u limit 1) as b_role;
grant select on who to public;

select pg_temp.as_user((select u from us where role = (select a_role from who))); set local role authenticated;
select is((select count(*)::int from public.my_games() where division_name = 'Sixteen' and stage_label = 'Round 1'), 1, 'before play: the member sees their scheduled Round 1 match');
select is((select status from public.my_games() where division_name = 'Sixteen' limit 1), 'scheduled', 'as scheduled');
reset role;

select pg_temp.play((select s16 from stg), 1, true);

select pg_temp.as_user((select u from us where role = (select a_role from who))); set local role authenticated;
select is((select result from public.my_games() where division_name = 'Sixteen' and stage_label = 'Round 1'), 'win', 'side A won the match');
select is((select (games -> 0 ->> 'me')::int || '-' || (games -> 0 ->> 'opp')::int from public.my_games() where division_name = 'Sixteen' and stage_label = 'Round 1'), '11-4', 'the games are shown from the member''s side');
select ok((select opp_team is not null and my_players is not null and opp_players is not null from public.my_games() where division_name = 'Sixteen' and stage_label = 'Round 1'), 'with team names and players');
select is((select count(*)::int from public.my_games() where division_name = 'Sixteen' and stage_label like 'H Bracket%'), 0, 'the H bracket match has no opponent yet, so it is not listed');
reset role;

select pg_temp.as_user((select u from us where role = (select b_role from who))); set local role authenticated;
select is((select result from public.my_games() where division_name = 'Sixteen' and stage_label = 'Round 1'), 'loss', 'side B lost the match');
reset role;

select pg_temp.as_user((select u from us where role = 'ref')); set local role authenticated;
select is((select count(*)::int from public.my_games()), 0, 'someone who played nothing sees no games');
reset role;

select * from finish();
rollback;
