begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as ev, core.ulid() as dv_d, core.ulid() as dv_s, core.ulid() as dv_b, core.ulid() as reg1,
  core.ulid() as gp4, core.ulid() as gx4,
  core.ulid() as gp1, core.ulid() as gp2, core.ulid() as gp3, core.ulid() as gx1, core.ulid() as gx2, core.ulid() as gx3,
  (select id from public.categories where code = 'novice' and deleted_at is null) as cat_novice,
  (select r.id from public.ranks r join public.rank_ladders l on l.id = r.ladder_id join public.categories c on c.id = l.category_id
    where c.code = 'novice' and r.deleted_at is null order by r.sort_order limit 1) as rank_id,
  (select id from public.format_templates where stages -> 0 ->> 'stage_type' = 'round_robin' and jsonb_array_length(stages) = 1 and deleted_at is null order by id limit 1) as tpl,
  current_date + 70 as day1;
grant select on fx to public;
create function pg_temp.mk(p_role text, p_no text) returns uuid language plpgsql as $$
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
  return u;
end $$;
create temp table us(role text primary key, u uuid, mid text);
grant select on us to public;
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2039-99001'), null;
insert into us select 'outsider', pg_temp.mk('member', 'CPC-2039-99002'), null;
insert into us select r, pg_temp.mk('member', 'CPC-2039-9901' || n), null from (values ('m1', 1), ('m2', 2)) v(r, n);
update us set mid = (select m.id from public.members m join public.profiles p on p.id = m.profile_id where p.auth_user_id = us.u);

create function pg_temp.assess(p_role text, p_disc text, p_points numeric) returns void language plpgsql as $$
begin
  perform public.set_member_cpc_rating((select mid from us where role = p_role), p_disc, p_points, 0, core.ulid(), 'Fake assessment');
end $$;
grant execute on function pg_temp.assess(text, text, numeric) to public;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select pg_temp.assess('m1', 'doubles', 2.600);   -- Novice: eligible
select pg_temp.assess('m2', 'doubles', 3.800);   -- Intermediate: not eligible
select public.create_event((select ev from fx), 'Guest Partner Test', (select day1 from fx), (select day1 from fx), 'Hall', 0, null, null);
select public.set_event_guest_policy((select ev from fx), true, core.ulid());
select public.create_division((select dv_d from fx), (select ev from fx), 'Novice Doubles', (select cat_novice from fx), 'doubles', null, null, null, null, null, (select tpl from fx), null);
select public.create_division((select dv_s from fx), (select ev from fx), 'Novice Singles', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.create_division((select dv_b from fx), (select ev from fx), 'Beginner Doubles',
  (select id from public.categories where code = 'beginner' and deleted_at is null), 'doubles', null, null, null, null, null, (select tpl from fx), null);
select public.set_event_status((select ev from fx), 'registration_open', null);
select public.create_guest_event_participant((select gp1 from fx), (select ev from fx), (select gx1 from fx), 'Fake Guest One', null, null, null, null, null, 2.600);
select public.create_guest_event_participant((select gp2 from fx), (select ev from fx), (select gx2 from fx), 'Fake Guest Two', null, null, null, null, null, 2.650);
select public.create_guest_event_participant((select gp3 from fx), (select ev from fx), (select gx3 from fx), 'Fake Guest Three', null, null, null, null, null, 2.700);
select public.create_guest_event_participant((select gp4 from fx), (select ev from fx), (select gx4 from fx), 'Fake Singles Only Guest', null, null, null, null, 2.600, null);
-- Keep eligible m1 outside the event roster to test club-wide partner search.
-- Only the ineligible member starts as an event participant.
select public.create_event_participant(core.ulid(), (select ev from fx), (select mid from us where role = 'm2'));
reset role;
insert into public.member_cpc_ratings (org_id, unit_id, member_id, discipline)
select m.org_id, m.unit_id, m.id, d.discipline from public.members m cross join (values ('singles'), ('doubles')) d(discipline)
where m.deleted_at is null and m.status = 'active'
  and not exists (select 1 from public.member_cpc_ratings r where r.member_id = m.id and r.discipline = d.discipline and r.deleted_at is null);
update public.settings set value = 'true'::jsonb where key = 'ranks.cpc_points_enabled' and unit_id is null and deleted_at is null;

-- guest three registers with guest two as the partner (assessed at a Novice rank)
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select lives_ok(format('select public.register_guest_for_event(%L, %L, %L, %L, %L, %L)', (select reg1 from fx), (select dv_d from fx), (select gp3 from fx),
  (select rank_id from fx), (select gp2 from fx), (select rank_id from fx)), 'guest three registers with guest two as partner');
-- now registering guest one: who can be the partner?
create temp table found as select * from public.eligible_event_partners((select dv_d from fx), (select gp1 from fx));
reset role;
grant select on found to public;
select is((select count(*)::int from found where id = (select gp1 from fx)), 0, 'the guest being registered is not offered as their own partner');
select is((select count(*)::int from found where member_id = (select mid from us where role = 'm1')), 1, 'an eligible member (Doubles 2.600, Novice) is offered');
select is((select count(*)::int from found where member_id = (select mid from us where role = 'm2')), 0, 'a member of the wrong category (Doubles 3.800) is not offered');
select is((select count(*)::int from found where id in (select gp2 from fx union select gp3 from fx)), 0, 'guests who already have an entry in the division are not offered');
select is((select count(*)::int from found where member_id in (select mid from us)
  or id in (select gp1 from fx union select gp2 from fx union select gp3 from fx union select gp4 from fx)),
  1, 'only the eligible member from the test fixture is left');

-- Eligible club members remain searchable without an event participant identity.
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select is((select count(*)::int from public.eligible_event_partners((select dv_d from fx),(select gp1 from fx))
  where member_id = (select mid from us where role = 'm1') and id is null),1,
  'eligible club member is searchable before being added to the event');
select lives_ok(format('select public.ensure_event_member_participant(%L,%L,%L)',core.ulid(),(select ev from fx),(select mid from us where role = 'm1')),
  'admin can prepare the selected member for guest partnership');
select is((public.ensure_event_member_participant(core.ulid(),(select ev from fx),(select mid from us where role = 'm1'))->>'replayed')::boolean,true,
  'repeated preparation reuses the same event identity');
reset role;
select is((select count(*)::int from public.event_participants where event_id = (select ev from fx)
  and member_id = (select mid from us where role = 'm1') and deleted_at is null),1,'one live participant identity per member');

-- another guest being registered: guest one is then a possible partner
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select is((select count(*)::int from public.eligible_event_partners((select dv_d from fx), (select gx1 from fx))), 0, 'an unknown lead guest cannot receive partner choices');
create temp table found2 as select * from public.eligible_event_partners((select dv_d from fx), null);
select is((select count(*)::int from found2 where id = (select gp1 from fx)), 1, 'without a selected guest, an unregistered guest is a possible partner');
select is((select is_guest from found2 where id = (select gp1 from fx)), true, 'and is marked as a guest with an eligible stored Doubles rating');
-- singles take no partner
select is((select count(*)::int from public.eligible_event_partners((select dv_s from fx), (select gp1 from fx))), 0, 'a singles division has no partner list');
reset role;

-- A guest candidate is checked just like a member, using Doubles, even if a caller supplies a different rank.
update public.event_participant_cpc_ratings set points = 3.800
  where participant_id = (select gp1 from fx) and discipline = 'doubles';
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select is((select count(*)::int from public.eligible_event_partners((select dv_d from fx), null)
  where id = (select gp1 from fx)), 0, 'wrong-category guest partner is excluded');
select is((select count(*)::int from public.eligible_event_partners((select dv_d from fx), (select gp1 from fx))), 0,
  'an ineligible lead guest receives no partner choices');
select is((public.guest_division_eligibility((select dv_d from fx),(select gp1 from fx))->>'eligible')::boolean,false,
  'eligibility feedback identifies the blocked guest');
select ok(strpos(public.guest_division_eligibility((select dv_d from fx),(select gp1 from fx))->>'reason',
  'Choose a division that fits this rating.') > 0,'feedback explains the rating mismatch instead of an empty search');
select throws_ok(format('select public.register_guest_for_event(%L,%L,%L,%L,%L,null)', core.ulid(),
  (select dv_d from fx), (select gp1 from fx), (select rank_id from fx),
  (select ep.id from public.event_participants ep where ep.event_id = (select ev from fx) and ep.member_id = (select mid from us where role = 'm1'))),
  '22023', 'Assess the guest at a rank in this division category.', 'supplied rank cannot bypass the stored rating at save');
reset role;
update public.event_participant_cpc_ratings set points = null, source = null, reason = null, assessed_at = null, assessed_by = null
  where participant_id = (select gp1 from fx) and discipline = 'doubles';
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select is((select count(*)::int from public.eligible_event_partners((select dv_d from fx), null)
  where id = (select gp1 from fx)), 0, 'guest partner without a Doubles rating is excluded');
select is((select count(*)::int from public.eligible_event_partners((select dv_b from fx), (select gp1 from fx))
  where id = (select gp4 from fx)), 1, 'unrated lead guest can find an unrated Doubles partner in Beginner Low');
select is((public.guest_division_eligibility((select dv_b from fx),(select gp1 from fx))->>'eligible')::boolean,true,
  'feedback allows an unrated guest in Beginner Low');
select is((select count(*)::int from public.eligible_event_partners((select dv_d from fx), null)
  where id = (select gp4 from fx)), 0, 'Singles rating cannot qualify a guest for Novice Doubles');
reset role;
update public.divisions set min_rank_id = (select id from public.ranks where code = 'beginner-high' and deleted_at is null)
  where id = (select dv_b from fx);
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select is((select count(*)::int from public.eligible_event_partners((select dv_b from fx), (select gp1 from fx))), 0,
  'Beginner High minimum excludes an unrated lead guest');
reset role;
update public.divisions set min_rank_id = null, gender = 'male' where id = (select dv_b from fx);
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select is((select count(*)::int from public.eligible_event_partners((select dv_b from fx), (select gp1 from fx))), 0,
  'NR allowance still enforces gender requirements');
reset role;
update public.divisions set gender = null, age_group = '40+' where id = (select dv_b from fx);
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select is((select count(*)::int from public.eligible_event_partners((select dv_b from fx), (select gp1 from fx))), 0,
  'NR allowance still enforces birth date requirements');
reset role;
update public.divisions set age_group = null where id = (select dv_b from fx);
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select lives_ok(format('select public.register_guest_for_event(%L,%L,%L,null,%L,null)', core.ulid(),
  (select dv_b from fx), (select gp1 from fx), (select gp4 from fx)), 'two unrated guests can save a Beginner Low doubles entry');
reset role;
select ok(not exists(select 1 from public.event_participant_cpc_ratings where participant_id in (select gp1 from fx union select gp4 from fx)
  and discipline = 'doubles' and points is not null), 'NR registration does not assign either guest a rating');
update public.event_participant_cpc_ratings set points = 2.600, source = 'admin_assessment', reason = 'Fake reassessment', assessed_at = now(),
  assessed_by = (select p.id from public.profiles p where p.auth_user_id = (select u from us where role = 'admin'))
  where participant_id = (select gp1 from fx) and discipline = 'doubles';
update public.divisions set min_rank_id = (select id from public.ranks where code = 'novice-high' and deleted_at is null),
  max_rank_id = (select id from public.ranks where code = 'novice-high' and deleted_at is null) where id = (select dv_d from fx);
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select is((select count(*)::int from public.eligible_event_partners((select dv_d from fx), null)
  where id = (select gp1 from fx)), 0, 'same-category guest below the division rank range is excluded');
reset role;

-- permissions
select pg_temp.as_user((select u from us where role = 'outsider')); set local role authenticated;
select throws_ok(format('select * from public.eligible_event_partners(%L, null)', (select dv_d from fx)), '42501', null, 'a member without the roster permission gets nothing');
select throws_ok(format('select public.ensure_event_member_participant(%L,%L,%L)',core.ulid(),(select ev from fx),(select mid from us where role = 'm1')),
  '42501',null,'preparing a member participant remains admin-only');
select throws_ok(format('select public.guest_division_eligibility(%L,%L)',(select dv_d from fx),(select gp1 from fx)),
  '42501',null,'eligibility feedback remains admin-only');
reset role;
select is(has_function_privilege('anon', 'public.eligible_event_partners(text, text)', 'execute'), false, 'the public cannot call it');

select * from finish();
rollback;
