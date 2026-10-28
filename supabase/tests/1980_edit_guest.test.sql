begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as ev, core.ulid() as dv_s, core.ulid() as dv_free,
  core.ulid() as p1, core.ulid() as p2, core.ulid() as g1, core.ulid() as g2,
  core.ulid() as r1, core.ulid() as k1, core.ulid() as k2, core.ulid() as k3, core.ulid() as k4, core.ulid() as k5, core.ulid() as k6,
  (select id from public.categories where code = 'novice' and deleted_at is null) as cat_novice,
  (select id from public.format_templates where stages -> 0 ->> 'stage_type' = 'round_robin' and jsonb_array_length(stages) = 1 and deleted_at is null order by id limit 1) as tpl,
  current_date + 90 as day1;
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
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2041-99001'), null;
insert into us select 'outsider', pg_temp.mk('member', 'CPC-2041-99002'), null;
update us set mid = (select m.id from public.members m join public.profiles p on p.id = m.profile_id where p.auth_user_id = us.u);

insert into public.member_cpc_ratings (org_id, unit_id, member_id, discipline)
select m.org_id, m.unit_id, m.id, d.discipline from public.members m cross join (values ('singles'), ('doubles')) d(discipline)
where m.deleted_at is null and m.status = 'active'
  and not exists (select 1 from public.member_cpc_ratings r where r.member_id = m.id and r.discipline = d.discipline and r.deleted_at is null);
update public.settings set value = 'true'::jsonb where key = 'ranks.cpc_points_enabled' and unit_id is null and deleted_at is null;

select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.create_event((select ev from fx), 'Edit Guest Test', (select day1 from fx), (select day1 from fx), 'Hall', 0, null, null);
select public.set_event_guest_policy((select ev from fx), true, core.ulid());
select public.create_division((select dv_s from fx), (select ev from fx), 'Men Novice Singles', (select cat_novice from fx), 'singles', 'male', null, null, null, null, (select tpl from fx), null);
select public.set_event_status((select ev from fx), 'registration_open', null);
select public.create_guest_event_participant((select p1 from fx), (select ev from fx), (select g1 from fx), 'Guest One', '0917 000 0001', 'male', date '1990-05-05', 'DUPR1', 2.600, 2.700);
select public.create_guest_event_participant((select p2 from fx), (select ev from fx), (select g2 from fx), 'Guest Two', null, 'male', null, 'DUPR2', 2.800, null);
select public.register_guest_for_event((select r1 from fx), (select dv_s from fx), (select p1 from fx), null);

-- reading the guest
select is((public.event_guest_profile((select p1 from fx)) ->> 'display_name'), 'Guest One', 'the edit form reads the guest''s name');
select is((public.event_guest_profile((select p1 from fx)) -> 'singles' ->> 'points')::numeric, 2.600::numeric, 'and the Singles rating');
select is((public.event_guest_profile((select p1 from fx)) -> 'doubles' ->> 'points')::numeric, 2.700::numeric, 'and the Doubles rating');
select is((public.event_guest_profile((select p2 from fx)) -> 'doubles' ->> 'points'), null::text, 'an unrated side is NR (null)');

-- correcting the profile
select lives_ok(format('select public.update_event_guest(%L, ''Guest One Corrected'', ''0917 111 2222'', ''male'', date ''1991-06-06'', ''dupr9'', null, null, null, %L)', (select p1 from fx), (select k1 from fx)),
  'the name, mobile, birth date and DUPR ID can be corrected');
select lives_ok(format('select public.update_event_guest(%L, ''Guest One Corrected'', ''0917 111 2222'', ''male'', date ''1991-06-06'', ''dupr9'', null, null, null, %L)', (select p1 from fx), (select k1 from fx)),
  'sending it again is safe');
reset role;
select is((select display_name from public.persons where id = (select g1 from fx)), 'Guest One Corrected', 'the guest person record is updated');
select is((select dupr_id from public.persons where id = (select g1 from fx)), 'DUPR9', 'the DUPR ID is stored upper case');
select is((select (select count(*) from core.audit_log where action = 'event_guest.update' and occurred_at >= now())::int), 1, 'one audit entry for the change (the retry added none)');

select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
-- DUPR uniqueness
select throws_ok(format('select public.update_event_guest(%L, ''Guest Two'', null, ''male'', null, ''DUPR9'', null, null, null, %L)', (select p2 from fx), (select k2 from fx)),
  '23505', null, 'another person''s DUPR ID cannot be used');
-- ratings need a reason; unchanged ratings need none
select throws_ok(format('select public.update_event_guest(%L, ''Guest Two'', null, ''male'', null, ''DUPR2'', 2.900, null, null, %L)', (select p2 from fx), (select k3 from fx)),
  '22023', null, 'changing a rating needs a reason');
select lives_ok(format('select public.update_event_guest(%L, ''Guest Two'', null, ''male'', null, ''DUPR2'', 2.900, 3.100, ''Re-assessed at the courts'', %L)', (select p2 from fx), (select k4 from fx)),
  'an administrator changes Singles and adds a Doubles rating with a reason');
select is((public.event_guest_profile((select p2 from fx)) -> 'singles' ->> 'points')::numeric, 2.900::numeric, 'the Singles rating is updated');
select is((public.event_guest_profile((select p2 from fx)) -> 'doubles' ->> 'points')::numeric, 3.100::numeric, 'and the Doubles rating added');
select lives_ok(format('select public.update_event_guest(%L, ''Guest Two Renamed'', null, ''male'', null, ''DUPR2'', 2.900, null, null, %L)', (select p2 from fx), (select k5 from fx)),
  'a profile change with the ratings unchanged needs no reason');
-- eligibility: the guest is registered in a men''s Novice singles division
select throws_ok(format('select public.update_event_guest(%L, ''Guest One Corrected'', ''0917 111 2222'', ''female'', date ''1991-06-06'', ''DUPR9'', null, null, null, %L)', (select p1 from fx), core.ulid()),
  '22023', null, 'a change of gender is refused if it makes the guest ineligible for a division they are in');
select throws_ok(format('select public.update_event_guest(%L, ''Guest One Corrected'', ''0917 111 2222'', ''male'', date ''1991-06-06'', ''DUPR9'', 3.800, null, ''Trying'', %L)', (select p1 from fx), core.ulid()),
  '22023', null, 'a rating that puts the guest in another category is refused for a division they are in');
select is((public.event_guest_profile((select p1 from fx)) -> 'singles' ->> 'points')::numeric, 2.600::numeric, 'and nothing was saved');
select throws_ok(format('select public.update_event_guest(%L, ''X'', null, ''male'', null, null, 9, null, ''bad'', %L)', (select p2 from fx), core.ulid()),
  '22023', null, 'a rating above 8.000 is refused');
-- a member is not a guest
select throws_ok(format('select public.event_guest_profile(%L)', core.ulid()), '22023', null, 'an unknown participant is refused');
reset role;

-- permissions
select pg_temp.as_user((select u from us where role = 'outsider')); set local role authenticated;
select throws_ok(format('select public.event_guest_profile(%L)', (select p1 from fx)), '42501', null, 'a member without the roster permission cannot read a guest');
select throws_ok(format('select public.update_event_guest(%L, ''Hacked'', null, null, null, null, null, null, null, %L)', (select p1 from fx), core.ulid()), '42501', null, 'or edit one');
reset role;
select is(has_function_privilege('anon', 'public.update_event_guest(text,text,text,text,date,text,numeric,numeric,text,text)', 'execute'), false, 'the public cannot call it');

select * from finish();
rollback;
