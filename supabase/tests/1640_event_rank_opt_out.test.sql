begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create temp table chain as select * from core.rank_chain((select id from public.orgs where code = 'cpc'));
grant select on chain to public;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as ev, core.ulid() as dv,
  core.ulid() as k1, core.ulid() as k2, core.ulid() as k3, core.ulid() as k4,
  (select id from public.format_templates where lower(name) like 'split single elimination%' and deleted_at is null) as tpl,
  (select id from public.categories where code = 'novice' and deleted_at is null) as cat_novice,
  (select r.id from public.ranks r join public.rank_ladders l on l.id = r.ladder_id join public.categories c on c.id = l.category_id
    where c.code = 'novice' and r.deleted_at is null order by r.sort_order desc limit 1) as novice_top,
  current_date + 30 as day1;
grant select on fx to public;
create temp table rk as select
  (select novice_top from fx) as top,
  core.rank_move((select novice_top from fx), 1) as up1,
  core.rank_move((select novice_top from fx), -1) as down1,
  core.rank_move((select novice_top from fx), 2) as up2;
grant select on rk to public;

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
    insert into public.member_ranks (org_id, member_id, rank_id) values (org, mid, (select novice_top from fx));
  end if;
  return u;
end $$;
create temp table us(role text primary key, u uuid, mid text, strength int);
grant select on us to public;
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2026-97501', true), null, null;
insert into us select 'ref', pg_temp.mk('referee', 'CPC-2026-97502', false), null, null;
insert into us select 'outsider', pg_temp.mk('member', 'CPC-2026-97503', false), null, null;
insert into us select 'p' || i, pg_temp.mk('member', 'CPC-2026-9751' || i, true), null, i from generate_series(1, 8) i;
update us set mid = (select m.id from public.members m join public.profiles p on p.id = m.profile_id where p.auth_user_id = us.u);

select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.create_event((select ev from fx), 'Correction Test', (select day1 from fx), (select day1 from fx), 'Hall', 0, null, null);
select public.create_division((select dv from fx), (select ev from fx), 'Split Eight', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.update_event((select ev from fx), 'Correction Test', (select day1 from fx), (select day1 from fx), 'Hall', 0, null, null, false, (select tpl from fx), false);
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
select pg_temp.join_div('p' || i, (select dv from fx)) from generate_series(1, 8) i;
create temp table stg as select (select id from public.division_stages where division_id = (select dv from fx)) as s;
grant select on stg to public;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.set_event_status((select ev from fx), 'registration_closed', null);
select public.run_draw((select s from stg));
reset role;
create temp table ent as
  select u.role, u.strength, e.id as entry from us u
  join public.entry_members em on em.member_id = u.mid join public.entries e on e.id = em.entry_id where u.strength is not null;
grant select on ent to public;
create function pg_temp.play_stage(p_stage text) returns void language plpgsql as $$
begin
  perform pg_temp.as_user((select u from us where role = 'ref'));
  set local role authenticated;
  perform public.enter_score(m.id, case when (select strength from ent where entry = m.entry_a_id) < (select strength from ent where entry = m.entry_b_id)
      then '[{"a":11,"b":4}]'::jsonb else '[{"a":4,"b":11}]'::jsonb end)
    from public.matches m where m.division_stage_id = p_stage and m.status = 'scheduled' and m.entry_a_id is not null and m.entry_b_id is not null;
  perform public.finalize_match(m.id) from public.matches m where m.division_stage_id = p_stage and m.status = 'in_progress';
  reset role;
end $$;
grant execute on function pg_temp.play_stage(text) to public;
create function pg_temp.final_of(g text) returns text language sql as $$
  select id from public.matches where division_stage_id = (select s from stg) and group_label = g and status <> 'void'
    and round_no = (select max(round_no) from public.matches where division_stage_id = (select s from stg) and group_label = g and status <> 'void')
$$;
grant execute on function pg_temp.final_of(text) to public;
-- games in which the weaker side wins the given match
create function pg_temp.upset(p_match text) returns jsonb language sql as $$
  select case when (select strength from ent where entry = m.entry_a_id) > (select strength from ent where entry = m.entry_b_id)
    then '[{"a":11,"b":5}]'::jsonb else '[{"a":5,"b":11}]'::jsonb end from public.matches m where m.id = p_match
$$;
grant execute on function pg_temp.upset(text) to public;

-- the same winner with a different score
create function pg_temp.same_winner(p_match text) returns jsonb language sql as $$
  select case when m.winner_entry_id = m.entry_a_id then '[{"a":11,"b":8}]'::jsonb else '[{"a":8,"b":11}]'::jsonb end from public.matches m where m.id = p_match
$$;
grant execute on function pg_temp.same_winner(text) to public;
select pg_temp.play_stage((select s from stg));
select pg_temp.play_stage((select s from stg));
select pg_temp.play_stage((select s from stg));
select is((select status from public.division_stages where id = (select s from stg)), 'completed', 'eight players: round 1, then H and L finish');
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.finalize_division((select dv from fx));
reset role;

select is((select status from public.divisions where id = (select dv from fx)), 'finalized', 'opt-out divisions still finalize');
select is((select count(*)::integer from public.division_results where division_id = (select dv from fx) and superseded_at is null), 8, 'all final results are recorded');
select is((select count(*)::integer from public.rank_history where division_id = (select dv from fx)), 0, 'opt-out creates no rank movement history');
select is((select count(*)::integer from public.member_ranks where member_id in (select mid from us) and rank_id <> (select novice_top from fx)), 0, 'all member ranks are unchanged');
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select lives_ok($$select public.correct_match(pg_temp.final_of('H'), 'Fake corrected outcome', pg_temp.upset(pg_temp.final_of('H')))$$, 'opt-out event still accepts score corrections');
reset role;
select is((select count(*)::integer from public.rank_history where division_id = (select dv from fx)), 0, 'score corrections do not move CPC ranks in an opt-out event');
select is((select count(*)::integer from public.member_ranks where member_id in (select mid from us) and rank_id <> (select novice_top from fx)), 0, 'CPC ranks remain unchanged after correction');
select is((select count(*)::integer from public.division_results where division_id = (select dv from fx) and superseded_at is null), 8, 'corrected results are still recorded');
select * from finish();
rollback;
