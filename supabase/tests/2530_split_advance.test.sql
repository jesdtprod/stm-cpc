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

-- the draw builds Round 1 and the empty brackets, with slots named after the match they come from
select is((select count(*)::int from public.matches where division_stage_id = (select s16 from stg) and group_label is null), 8, '16 teams: 8 Round 1 matches');
select is((select count(*)::int from public.matches where division_stage_id = (select s16 from stg) and group_label = 'H'), 7, 'and an H bracket of 7 matches');
select is((select count(*)::int from public.matches where division_stage_id = (select s16 from stg) and group_label = 'L'), 7, 'and an L bracket of 7 matches');
select is((select meta ->> 'a_label' from public.matches where division_stage_id = (select s16 from stg) and group_label = 'H' and round_no = 2 and match_no = 1), 'Winner of Match 1', 'the first H match waits for the winner of Match 1');
select is((select meta ->> 'b_label' from public.matches where division_stage_id = (select s16 from stg) and group_label = 'H' and round_no = 2 and match_no = 1), 'Winner of Match 2', 'against the winner of Match 2');
select is((select meta ->> 'a_label' from public.matches where division_stage_id = (select s16 from stg) and group_label = 'L' and round_no = 2 and match_no = 101), 'Loser of Match 1', 'the first L match waits for the loser of Match 1');
select is((select count(*)::int from public.matches where division_stage_id = (select s16 from stg) and group_label in ('H', 'L') and (entry_a_id is not null or entry_b_id is not null)), 0, 'nobody is in a bracket before a result');

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

-- Match 1 is final: its winner is in the H bracket and its loser in the L bracket, while the rest of Round 1 is still open
select pg_temp.play((select s16 from stg), 1, true);
select is((select entry_a_id from public.matches where division_stage_id = (select s16 from stg) and group_label = 'H' and round_no = 2 and match_no = 1),
  (select winner_entry_id from public.matches where division_stage_id = (select s16 from stg) and group_label is null and match_no = 1), 'the winner of Match 1 goes straight to the H bracket');
select is((select entry_a_id from public.matches where division_stage_id = (select s16 from stg) and group_label = 'L' and round_no = 2 and match_no = 101),
  (select entry_b_id from public.matches where division_stage_id = (select s16 from stg) and group_label is null and match_no = 1), 'the loser of Match 1 goes straight to the L bracket');
select is((select entry_b_id from public.matches where division_stage_id = (select s16 from stg) and group_label = 'H' and round_no = 2 and match_no = 1), null, 'the other H slot still waits for Match 2');

select pg_temp.play((select s16 from stg), 2, false);
select is((select entry_b_id from public.matches where division_stage_id = (select s16 from stg) and group_label = 'H' and round_no = 2 and match_no = 1),
  (select winner_entry_id from public.matches where division_stage_id = (select s16 from stg) and group_label is null and match_no = 2), 'the winner of Match 2 meets the winner of Match 1');
select is((select entry_b_id from public.matches where division_stage_id = (select s16 from stg) and group_label = 'L' and round_no = 2 and match_no = 101),
  (select entry_a_id from public.matches where division_stage_id = (select s16 from stg) and group_label is null and match_no = 2), 'and the two losers meet in the L bracket');
select is((select status from public.division_stages where id = (select s16 from stg)), 'in_progress', 'the stage is still running');


-- Correcting Match 1 so the other side wins swaps the two entries in the brackets (nothing there has started)
create temp table before as select
  (select winner_entry_id from public.matches where division_stage_id = (select s16 from stg) and group_label is null and match_no = 1 and status = 'completed') as w,
  (select entry_b_id from public.matches where division_stage_id = (select s16 from stg) and group_label is null and match_no = 1 and status = 'completed') as l;
grant select on before to public;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select lives_ok(format('select public.correct_match(%L, %L, %L)',
  (select id from public.matches where division_stage_id = (select s16 from stg) and group_label is null and match_no = 1 and status = 'completed'),
  'Wrong input', '[{"a":4,"b":11}]'), 'a correction that changes the winner is accepted');
reset role;
select is((select entry_a_id from public.matches where division_stage_id = (select s16 from stg) and group_label = 'H' and round_no = 2 and match_no = 1),
  (select l from before), 'the new winner takes the old winner''s place in the H bracket');
select is((select entry_a_id from public.matches where division_stage_id = (select s16 from stg) and group_label = 'L' and round_no = 2 and match_no = 101),
  (select w from before), 'and the new loser takes the old loser''s place in the L bracket');

-- once the H match has started, the winner of Match 1 can no longer be swapped
select pg_temp.as_user((select u from us where role = 'ref')); set local role authenticated;
select public.enter_score((select id from public.matches where division_stage_id = (select s16 from stg) and group_label = 'H' and round_no = 2 and match_no = 1), '[{"a":11,"b":3}]');
reset role;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select throws_ok(format('select public.correct_match(%L, %L, %L)',
  (select id from public.matches where division_stage_id = (select s16 from stg) and group_label is null and match_no = 1 and status = 'completed'),
  'Wrong again', '[{"a":11,"b":2}]'), '22023', null, 'but not after the next match has started');
reset role;

-- an odd entry: 5 teams, 2 Round 1 matches, the odd one starts in the H bracket
select is((select count(*)::int from public.matches where division_stage_id = (select s5 from stg) and group_label = 'H'), 2, '5 teams: the H bracket has 3 entries (2 matches)');
select is((select count(*)::int from public.matches where division_stage_id = (select s5 from stg) and group_label = 'L'), 1, 'and the L bracket 2 entries (1 match)');
select is((select count(*)::int from public.matches where division_stage_id = (select s5 from stg) and group_label = 'H' and (entry_a_id is not null or entry_b_id is not null)), 1, 'the odd entry is already in the H bracket');

select * from finish();
rollback;
