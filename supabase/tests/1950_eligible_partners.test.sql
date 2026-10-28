begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as ev, core.ulid() as dv_d, core.ulid() as dv_s, core.ulid() as reg1, core.ulid() as reg2,
  (select id from public.categories where code = 'novice' and deleted_at is null) as cat_novice,
  (select id from public.format_templates where stages -> 0 ->> 'stage_type' = 'round_robin' and jsonb_array_length(stages) = 1 and deleted_at is null order by id limit 1) as tpl,
  current_date + 60 as day1;
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
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2038-99001'), null;
insert into us select r, pg_temp.mk('member', 'CPC-2038-9901' || n), null
from (values ('me', 1), ('p1', 2), ('p2', 3), ('p3', 4), ('p4', 5), ('p5', 6)) v(r, n);
update us set mid = (select m.id from public.members m join public.profiles p on p.id = m.profile_id where p.auth_user_id = us.u);

-- ratings (Doubles): me 2.600, p1 2.650 (Novice, eligible), p2 3.800 (Intermediate, not eligible), p3 has Singles only,
-- p4 2.750 and p5 2.700 (both Novice; they register together)
create function pg_temp.assess(p_role text, p_disc text, p_points numeric) returns void language plpgsql as $$
begin
  perform public.set_member_cpc_rating((select mid from us where role = p_role), p_disc, p_points, 0, core.ulid(), 'Fake assessment');
end $$;
grant execute on function pg_temp.assess(text, text, numeric) to public;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select pg_temp.assess('me', 'doubles', 2.600); select pg_temp.assess('p1', 'doubles', 2.650); select pg_temp.assess('p2', 'doubles', 3.800);
select pg_temp.assess('p3', 'singles', 2.600); select pg_temp.assess('p4', 'doubles', 2.750); select pg_temp.assess('p5', 'doubles', 2.700);
select public.create_event((select ev from fx), 'Partner Test', (select day1 from fx), (select day1 from fx), 'Hall', 0, null, null);
select public.create_division((select dv_d from fx), (select ev from fx), 'Novice Doubles', (select cat_novice from fx), 'doubles', null, null, null, null, null, (select tpl from fx), null);
select public.create_division((select dv_s from fx), (select ev from fx), 'Novice Singles', (select cat_novice from fx), 'singles', null, null, null, null, null, (select tpl from fx), null);
select public.set_event_status((select ev from fx), 'registration_open', null);
reset role;
insert into public.member_cpc_ratings (org_id, unit_id, member_id, discipline)
select m.org_id, m.unit_id, m.id, d.discipline from public.members m cross join (values ('singles'), ('doubles')) d(discipline)
where m.deleted_at is null and m.status = 'active'
  and not exists (select 1 from public.member_cpc_ratings r where r.member_id = m.id and r.discipline = d.discipline and r.deleted_at is null);
update public.settings set value = 'true'::jsonb where key = 'ranks.cpc_points_enabled' and unit_id is null and deleted_at is null;
update public.settings set value = 'false'::jsonb where key = 'events.registration_approval_required' and unit_id is null and deleted_at is null;

-- p5 registers with p4 as the partner
select pg_temp.as_user((select u from us where role = 'p5')); set local role authenticated;
select lives_ok(format('select public.register_for_event(%L, %L, %L)', (select reg1 from fx), (select dv_d from fx), (select mid from us where role = 'p4')),
  'p5 registers with p4 as the partner');
reset role;

-- the search as "me"
select pg_temp.as_user((select u from us where role = 'me')); set local role authenticated;
create temp table found as select * from public.eligible_partners((select dv_d from fx), 'zyx');
reset role;
grant select on found to public;
select is((select count(*)::int from found where member_id = (select mid from us where role = 'p1')), 1, 'p1 (Doubles 2.650, Novice) is offered as a partner');
select is((select count(*)::int from found where member_id = (select mid from us where role = 'p2')), 0, 'p2 (Doubles 3.800, Intermediate) is not offered: wrong category for this division');
select is((select count(*)::int from found where member_id = (select mid from us where role = 'p3')), 0, 'p3 (no Doubles rating) is not offered');
select is((select count(*)::int from found where member_id in (select mid from us where role in ('p4', 'p5'))), 0, 'members already registered in the division are not offered');
select is((select count(*)::int from found where member_id = (select mid from us where role = 'me')), 0, 'you are not offered as your own partner');
select is((select count(*)::int from found), 1, 'only the one eligible member is listed');

select pg_temp.as_user((select u from us where role = 'me')); set local role authenticated;
select is((select count(*)::int from public.eligible_partners((select dv_d from fx), 'z')), 0, 'a search needs at least two characters');
select is((select count(*)::int from public.eligible_partners((select dv_d from fx), '99012')), 1, 'a member ID search works too');
select throws_ok(format('select * from public.eligible_partners(%L, ''zyx'')', (select dv_s from fx)), '22023', null, 'a singles division has no partner search');
-- registering still refuses an ineligible partner
select throws_ok(format('select public.register_for_event(%L, %L, %L)', (select reg2 from fx), (select dv_d from fx), (select mid from us where role = 'p2')),
  '22023', null, 'registering with an ineligible partner is still refused by the database');
select throws_ok(format('select public.register_for_event(%L, %L)', core.ulid(), (select dv_d from fx)), '22023', 'choose your doubles partner', 'a doubles registration needs a partner');
reset role;
select set_config('request.jwt.claims', '', true);
select throws_ok($$select * from core.eligible_partners('x', 'zyx')$$, '42501', null, 'signed-out callers get nothing');
select is(has_function_privilege('anon', 'public.eligible_partners(text, text)', 'execute'), false, 'the public cannot call it');

select * from finish();
rollback;
