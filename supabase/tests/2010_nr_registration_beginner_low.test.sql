begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as ev, core.ulid() as dv_b, core.ulid() as dv_n, core.ulid() as dv_nl, core.ulid() as dv_i, core.ulid() as dv_bd, core.ulid() as dv_bm, core.ulid() as dv_bh,
  (select id from public.categories where code = 'beginner' and deleted_at is null) as cat_b,
  (select id from public.categories where code = 'novice' and deleted_at is null) as cat_n,
  (select id from public.categories where code = 'intermediate' and deleted_at is null) as cat_i,
  (select id from public.ranks where code = 'novice-low' and deleted_at is null) as rank_nl,
  (select id from public.ranks where code = 'beginner-high' and deleted_at is null) as rank_bh,
  (select id from public.format_templates where stages -> 0 ->> 'stage_type' = 'round_robin' and jsonb_array_length(stages) = 1 and deleted_at is null order by id limit 1) as tpl,
  current_date + 110 as day1;
grant select on fx to public;
create function pg_temp.mk(p_role text, p_no text) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); mid text := core.ulid(); org text := (select org from fx);
begin
  insert into auth.users (id, email) values (u, lower(p_no) || '@members.example.test');
  insert into public.persons (id, org_id, display_name) values (per, org, 'Zyx ' || p_no);
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
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2043-99001'), null;
insert into us select 'me', pg_temp.mk('member', 'CPC-2043-99002'), null;
insert into us select 'nr', pg_temp.mk('member', 'CPC-2043-99003'), null;
update us set mid = (select m.id from public.members m join public.profiles p on p.id = m.profile_id where p.auth_user_id = us.u);

select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.set_member_cpc_rating((select mid from us where role = 'me'), 'doubles', 2.300, 0, core.ulid(), 'Fake assessment');
select public.create_event((select ev from fx), 'NR Registration Test', (select day1 from fx), (select day1 from fx), 'Hall', 0, null, null);
select public.create_division((select dv_b from fx), (select ev from fx), 'Beginner Singles', (select cat_b from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.create_division((select dv_n from fx), (select ev from fx), 'Novice Singles', (select cat_n from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.create_division((select dv_nl from fx), (select ev from fx), 'Novice Low Singles', (select cat_n from fx), 'singles', null, null, null, (select rank_nl from fx), null, (select tpl from fx), null);
select public.create_division((select dv_i from fx), (select ev from fx), 'Intermediate Singles', (select cat_i from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.create_division((select dv_bd from fx), (select ev from fx), 'Beginner Doubles', (select cat_b from fx), 'doubles', null, null, null, null, null, (select tpl from fx), null);
select public.create_division((select dv_bm from fx), (select ev from fx), 'Beginner Men Singles', (select cat_b from fx), 'singles', 'male', null, null, null, null, (select tpl from fx), null);
select public.create_division((select dv_bh from fx), (select ev from fx), 'Beginner High Up Singles', (select cat_b from fx), 'singles', null, null, (select rank_bh from fx), null, null, (select tpl from fx), null);
select public.set_event_status((select ev from fx), 'registration_open', null);
reset role;
insert into public.member_cpc_ratings (org_id, unit_id, member_id, discipline)
select m.org_id, m.unit_id, m.id, d.discipline from public.members m cross join (values ('singles'), ('doubles')) d(discipline)
where m.deleted_at is null and m.status = 'active'
  and not exists (select 1 from public.member_cpc_ratings r where r.member_id = m.id and r.discipline = d.discipline and r.deleted_at is null);
update public.settings set value = 'true'::jsonb where key = 'ranks.cpc_points_enabled' and unit_id is null and deleted_at is null;

-- an NR member (no rating) registering
select is(core.registration_problem((select mid from us where role = 'nr'), (select dv_b from fx), true), null::text,
  'an NR player can join a Beginner division open from Beginner Low');
select ok(core.registration_problem((select mid from us where role = 'nr'), (select dv_bh from fx), true) like 'You have no singles rating yet. Unrated players can join Beginner divisions that start at Beginner Low%',
  'but not a Beginner division whose minimum is Beginner High');
select ok(core.registration_problem((select mid from us where role = 'nr'), (select dv_nl from fx), true) like 'You have no singles rating yet. Unrated%',
  'nor a Novice division, even one limited to Novice Low');
select ok(core.registration_problem((select mid from us where role = 'nr'), (select dv_n from fx), true) like 'You have no singles rating yet. Unrated%',
  'nor an unrestricted Novice division');
select ok(core.registration_problem((select mid from us where role = 'nr'), (select dv_i from fx), true) like 'You have no singles rating yet%',
  'nor an Intermediate division');
select is(core.registration_problem((select mid from us where role = 'nr'), (select dv_bm from fx), true), 'Add your gender to your profile to join this division.',
  'the other rules still apply: a men''s division still needs their gender');
-- a rated member is checked as before
select is(core.registration_problem((select mid from us where role = 'me'), (select dv_bd from fx), true), null::text,
  'a Beginner-rated member (Doubles 2.300) still joins a Beginner doubles division');
select ok(core.registration_problem((select mid from us where role = 'me'), (select dv_i from fx), true) like '%rating yet%',
  'a member with no Singles rating cannot join an Intermediate singles division');

-- the doubles partner search offers the NR member for a Beginner doubles division, and not for a Novice one
select pg_temp.as_user((select u from us where role = 'me')); set local role authenticated;
select is((select count(*)::int from public.eligible_partners((select dv_bd from fx), 'zyx') where member_id = (select mid from us where role = 'nr')), 1,
  'an NR player is offered as a partner in a Beginner doubles division');
reset role;

select * from finish();
rollback;
