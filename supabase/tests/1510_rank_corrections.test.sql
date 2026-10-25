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
create temp table champ as select
  (select winner_entry_id from public.matches where id = pg_temp.final_of('H')) as h_champ,
  (select case when winner_entry_id = entry_a_id then entry_b_id else entry_a_id end from public.matches where id = pg_temp.final_of('H')) as h_second,
  (select winner_entry_id from public.matches where id = pg_temp.final_of('L')) as l_champ,
  (select case when winner_entry_id = entry_a_id then entry_b_id else entry_a_id end from public.matches where id = pg_temp.final_of('L')) as l_second;
grant select on champ to public;
create function pg_temp.rank_of(p_entry text) returns text language sql as $$
  select mr.rank_id from public.member_ranks mr join public.entry_members em on em.member_id = mr.member_id where em.entry_id = p_entry and mr.deleted_at is null
$$;
grant execute on function pg_temp.rank_of(text) to public;

select is(pg_temp.rank_of((select h_champ from champ)), (select up1 from rk), 'before any correction: the H champion moved up');
select is(pg_temp.rank_of((select h_second from champ)), (select top from rk), 'the H runner-up kept their rank');
select is(pg_temp.rank_of((select l_champ from champ)), (select top from rk), 'the L champion kept their rank');
select is(pg_temp.rank_of((select l_second from champ)), (select down1 from rk), 'the L runner-up moved down');
select is((select count(*)::int from public.rank_history where division_id = (select dv from fx)), 8, 'eight history rows');

-- ---- a correction that changes nothing for placements
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select is((select public.correct_match(pg_temp.final_of('H'), 'Score typed wrongly', pg_temp.same_winner(pg_temp.final_of('H'))) -> 'ranks' ->> 'changed'), 'false', 'a corrected score with the same winner moves nobody');
reset role;
select is((select count(*)::int from public.rank_history where division_id = (select dv from fx)), 8, 'and writes no new history');
select is((select count(*)::int from public.division_results where division_id = (select dv from fx)), 8, 'or new results');

-- ---- a correction that changes the H champion
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
create temp table c1 as select public.correct_match(pg_temp.final_of('H'), 'The final was won by the other player', pg_temp.upset(pg_temp.final_of('H'))) as r;
reset role;
grant select on c1 to public;
select is((select r -> 'ranks' ->> 'changed' from c1), 'true', 'a different champion re-evaluates the division');
select is((select (r -> 'ranks' ->> 'revision')::int from c1), 2, 'as revision 2');
select is((select (r -> 'ranks' ->> 'reversed')::int from c1), 8, 'every earlier move was reversed');
select is((select count(*)::int from public.rank_history where division_id = (select dv from fx)), 24, '8 original + 8 reversing + 8 corrected rows');
select is((select count(*)::int from public.rank_history where division_id = (select dv from fx) and reverses_id is not null), 8, 'eight of them are reversals');
select is(pg_temp.rank_of((select h_champ from champ)), (select top from rk), 'the old champion is back where they were (now runner-up)');
select is(pg_temp.rank_of((select h_second from champ)), (select up1 from rk), 'the new champion moved up');
select is(pg_temp.rank_of((select l_champ from champ)), (select top from rk), 'the L bracket is unchanged: champion');
select is(pg_temp.rank_of((select l_second from champ)), (select down1 from rk), 'and runner-up');
select is((select count(*)::int from public.division_results where division_id = (select dv from fx) and superseded_at is not null), 8, 'the first results are kept as superseded');
select is((select count(*)::int from public.division_results where division_id = (select dv from fx) and superseded_at is null), 8, 'and 8 are live');
select is((select placement from public.division_results where division_id = (select dv from fx) and superseded_at is null and entry_id = (select h_second from champ)), 1, 'the new champion is placed 1st');
select is((select placement from public.division_results where division_id = (select dv from fx) and superseded_at is null and entry_id = (select h_champ from champ)), 2, 'the old one 2nd');
select throws_ok(format($f$update public.division_results set placement = 1 where division_id = %L and superseded_at is null$f$, (select dv from fx)), '42501', null, 'live results still cannot be edited');
select is((select count(*)::int from public.division_results_view((select dv from fx))), 8, 'the results screen shows only the live ones');

-- ---- an administrator override, and a later correction that keeps it
select pg_temp.as_user((select u from us where role = 'outsider')); set local role authenticated;
select throws_ok(format($f$select public.override_member_rank(%L, %L, 'Because', %L)$f$, (select mid from us where role = 'p1'), (select up2 from rk), core.ulid()), '42501', null, 'a member cannot override a rank');
reset role;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select throws_ok(format($f$select public.override_member_rank(%L, %L, 'Mine', %L)$f$, (select mid from us where role = 'admin'), (select up2 from rk), core.ulid()), '42501', 'you cannot change your own rank', 'nobody can override their own rank');
select throws_ok(format($f$select public.override_member_rank(%L, %L, 'no', %L)$f$, (select mid from us where role = 'p1'), (select up2 from rk), core.ulid()), '22023', null, 'a reason is required');
select throws_ok(format($f$select public.override_member_rank(%L, %L, 'Same rank', %L)$f$, (select mid from us where role = 'p1'), (select top from rk), core.ulid()), '22023', 'the member is already at that rank', 'the same rank is refused');
select throws_ok(format($f$select public.override_member_rank(%L, 'not-a-rank', 'Bad rank', %L)$f$, (select mid from us where role = 'p1'), core.ulid()), '22023', null, 'an unknown rank is refused');
-- the L runner-up (who went down) is moved by hand to two levels up
create temp table ov as select
  (select em.member_id from public.entry_members em where em.entry_id = (select l_second from champ)) as member_id, core.ulid() as k;
grant select on ov to public;
select is((select public.override_member_rank((select member_id from ov), (select up2 from rk), 'Coach moved them up', (select k from ov)) ->> 'rank_id'), (select up2 from rk), 'an administrator sets a rank with a reason');
select is((select public.override_member_rank((select member_id from ov), (select up2 from rk), 'Coach moved them up', (select k from ov)) ->> 'rank_id'), (select up2 from rk), 'sending it again is safe');
reset role;
select is((select count(*)::int from public.rank_history where member_id = (select member_id from ov) and division_id is null), 1, 'one history row, with no division');
select is((select reason from public.rank_history where member_id = (select member_id from ov) and division_id is null), 'Override: Coach moved them up', 'with the reason');
select is((select from_rank_id from public.rank_history where member_id = (select member_id from ov) and division_id is null), (select down1 from rk), 'from where they were');
select ok(exists (select 1 from core.audit_log where action = 'rank.override' and record_id = (select member_id from ov)), 'the override is audited');
-- now the L final changes hands: the override must survive the reversal and the reapplication
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.correct_match(pg_temp.final_of('L'), 'The L final was won by the other player', pg_temp.upset(pg_temp.final_of('L')));
reset role;
select is(pg_temp.rank_of((select l_champ from champ)), (select down1 from rk), 'the old L champion now lost the bracket: down');
select is(pg_temp.rank_of((select l_second from champ)), core.rank_move((select up2 from rk), 1), 'the administrator''s rank is kept: only the difference between the old and the corrected rule result is applied to it (no longer moved down: one level back up)');

select * from finish();
rollback;
