begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as ev, core.ulid() as dv_d, core.ulid() as dv_s,
  core.ulid() as g1, core.ulid() as g2, core.ulid() as g3, core.ulid() as g4,
  core.ulid() as p1, core.ulid() as p2, core.ulid() as p3, core.ulid() as p4,
  core.ulid() as r1, core.ulid() as r2, core.ulid() as r3, core.ulid() as r4,
  core.ulid() as nr_person, core.ulid() as nr_participant,
  (select id from public.categories where code = 'novice' and deleted_at is null) as cat_novice,
  (select id from public.format_templates where stages -> 0 ->> 'stage_type' = 'round_robin' and jsonb_array_length(stages) = 1 and deleted_at is null order by id limit 1) as tpl,
  current_date + 80 as day1;
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
create temp table us(role text primary key, u uuid);
grant select on us to public;
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2040-99001');
insert into us select 'outsider', pg_temp.mk('member', 'CPC-2040-99002');

select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.create_event((select ev from fx), 'Guest Assessment Test', (select day1 from fx), (select day1 from fx), 'Hall', 0, null, null);
select public.set_event_guest_policy((select ev from fx), true, core.ulid());
select public.create_division((select dv_d from fx), (select ev from fx), 'Novice Doubles', (select cat_novice from fx), 'doubles', null, null, null, null, null, (select tpl from fx), null);
select public.create_division((select dv_s from fx), (select ev from fx), 'Novice Singles', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.set_event_status((select ev from fx), 'registration_open', null);
reset role;
insert into public.member_cpc_ratings (org_id, unit_id, member_id, discipline)
select m.org_id, m.unit_id, m.id, d.discipline from public.members m cross join (values ('singles'), ('doubles')) d(discipline)
where m.deleted_at is null and m.status = 'active'
  and not exists (select 1 from public.member_cpc_ratings r where r.member_id = m.id and r.discipline = d.discipline and r.deleted_at is null);
update public.settings set value = 'true'::jsonb where key = 'ranks.cpc_points_enabled' and unit_id is null and deleted_at is null;
select is(core.cpc_points_enabled((select org from fx)), true, 'ratings are on for this test');

select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
-- Add Guest takes the assessment
select lives_ok(format('select public.create_guest_event_participant(%L, %L, %L, ''No Rating Guest'', null, null, null, null, null, null)', (select nr_participant from fx), (select ev from fx), (select nr_person from fx)),
  'with ratings on, an unrated guest can be added');
select lives_ok(format('select public.create_guest_event_participant(%L, %L, %L, ''No Rating Guest'', null, null, null, null, null, null)', (select nr_participant from fx), (select ev from fx), (select nr_person from fx)),
  'unrated guest creation is safe to retry');
select is((select count(*)::int from public.event_participant_cpc_ratings where participant_id = (select nr_participant from fx)),0,
  'unrated creation does not invent a numerical rating');
select throws_ok(format('select public.register_guest_for_event(%L, %L, %L, null)',core.ulid(),(select dv_s from fx),(select nr_participant from fx)),
  '22023',null,'creating NR guest does not bypass higher-division eligibility');
select throws_ok(format('select public.create_guest_event_participant(%L, %L, %L, ''Bad Rating Guest'', null, null, null, null, 9, null)', (select p1 from fx), (select ev from fx), (select g1 from fx)),
  '22023', null, 'a rating above 8.000 is refused');
select lives_ok(format('select public.create_guest_event_participant(%L, %L, %L, ''Guest Doubles'', null, null, null, null, 2.600, 2.700)', (select p1 from fx), (select ev from fx), (select g1 from fx)),
  'a guest is added with a Singles and a Doubles rating');
select lives_ok(format('select public.create_guest_event_participant(%L, %L, %L, ''Guest Doubles'', null, null, null, null, 2.600, 2.700)', (select p1 from fx), (select ev from fx), (select g1 from fx)),
  'sending it again is safe');
select lives_ok(format('select public.create_guest_event_participant(%L, %L, %L, ''Guest Singles Only'', null, null, null, null, 2.800, null)', (select p2 from fx), (select ev from fx), (select g2 from fx)),
  'a guest may be assessed in one format only');
select lives_ok(format('select public.create_guest_event_participant(%L, %L, %L, ''Guest Strong'', null, null, null, null, 3.800, 3.900)', (select p3 from fx), (select ev from fx), (select g3 from fx)),
  'a stronger guest (Intermediate) is added');
select lives_ok(format('select public.create_guest_event_participant(%L, %L, %L, ''Guest Partner'', null, null, null, null, null, 2.500)', (select p4 from fx), (select ev from fx), (select g4 from fx)),
  'a guest partner with a Doubles rating only');
select is((select count(*)::int from public.event_participant_cpc_ratings where participant_id = (select p1 from fx) and deleted_at is null), 2, 'both ratings are stored once (no duplicate after the retry)');
select is((select points from public.event_participant_cpc_ratings where participant_id = (select p1 from fx) and discipline = 'doubles'), 2.700::numeric, 'the Doubles rating is stored as typed');
select is((select count(*)::int from public.guest_participant_ratings((select ev from fx))), 6, 'the registration form can read the guests'' ratings');

-- registering a guest takes the rank from the rating for the division's format; no assessed rank is sent
select lives_ok(format('select public.register_guest_for_event(%L, %L, %L, null, %L, null)', (select r1 from fx), (select dv_d from fx), (select p1 from fx), (select p4 from fx)),
  'a doubles team registers: the rank comes from each guest''s Doubles rating, nothing else is asked');
select is((select guest_rank_id from public.registrations where id = (select r1 from fx)), (select id from public.ranks where code = 'novice-low' and deleted_at is null),
  'the guest is Novice Low (Doubles 2.700 is Novice Low)');
select is((select guest_partner_rank_id from public.registrations where id = (select r1 from fx)), (select id from public.ranks where code = 'novice-low' and deleted_at is null),
  'and the guest partner is Novice Low (Doubles 2.500)');
select lives_ok(format('select public.register_guest_for_event(%L, %L, %L, null)', (select r2 from fx), (select dv_s from fx), (select p2 from fx)),
  'a singles registration uses the Singles rating');
select throws_ok(format('select public.register_guest_for_event(%L, %L, %L, null, %L, null)', (select r3 from fx), (select dv_d from fx), (select p3 from fx), (select p2 from fx)),
  '22023', null, 'a stronger guest (Intermediate) is refused in the Novice division');
-- a guest with no rating for the division's format cannot be registered
select throws_ok(format('select public.register_guest_for_event(%L, %L, %L, null, %L, null)', (select r4 from fx), (select dv_d from fx), (select p2 from fx), (select p4 from fx)),
  '22023', null, 'a guest with no Doubles rating cannot join a doubles division');
reset role;

-- permissions
select pg_temp.as_user((select u from us where role = 'outsider')); set local role authenticated;
select throws_ok(format('select * from public.guest_participant_ratings(%L)', (select ev from fx)), '42501', null, 'a member without the roster permission cannot read guest ratings');
reset role;
select is(has_function_privilege('anon', 'public.guest_participant_ratings(text)', 'execute'), false, 'the public cannot read guest ratings');

select * from finish();
rollback;
