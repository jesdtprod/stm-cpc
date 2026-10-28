begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as per, core.ulid() as mid, core.ulid() as pid, gen_random_uuid() as uid;
grant select on fx to public;
insert into auth.users (id, email) select uid, 'public-ratings@example.test' from fx;
insert into public.persons(id, org_id, display_name) select per, org, '000 Fake Public Ratings' from fx;
insert into public.profiles(id, org_id, auth_user_id, person_id) select pid, org, uid, per from fx;
insert into public.members(id, org_id, person_id, member_no, status)
  select mid, org, per, 'CPC-2039-99301', 'imported' from fx;
insert into public.member_cpc_ratings(org_id, member_id, discipline, points, source, reason, assessed_at, assessed_by)
  select org, mid, 'singles', 3.125, 'admin_assessment', 'Fake test assessment', now(), pid from fx;
insert into public.member_cpc_ratings(org_id, member_id, discipline, points, source, reason, assessed_at, assessed_by)
  select org, mid, 'doubles', 2.000, 'admin_assessment', 'Fake test assessment', now(), pid from fx;
update public.settings set value = 'true' where org_id = (select org from fx)
  and key = 'public.members_enabled' and unit_id is null and deleted_at is null;

set local role anon;
select is((select (m->>'singles_points')::numeric from jsonb_array_elements(public.public_members()->'members') m
  where m->>'member_no' = 'CPC-2039-99301'), 3.125::numeric, 'publishes current Singles rating');
select is((select (m->>'doubles_points')::numeric from jsonb_array_elements(public.public_members()->'members') m
  where m->>'member_no' = 'CPC-2039-99301'), 2.000::numeric, 'publishes current Doubles rating');
select ok(not exists(select 1 from jsonb_array_elements(public.public_members()->'members') m
  where m ?| array['reason','assessed_by','assessed_at','profile_id','member_id','email','mobile','history']),
  'does not publish private assessment details or contacts');
reset role;
update public.member_cpc_ratings set deleted_at = now(), delete_reason = 'Fake test removal'
  where member_id = (select mid from fx) and discipline = 'doubles';
set local role anon;
select is((select m->'doubles_points' from jsonb_array_elements(public.public_members()->'members') m
  where m->>'member_no' = 'CPC-2039-99301'), 'null'::jsonb, 'absent ratings are null, not zero');
reset role;
update public.settings set value = 'false' where org_id = (select org from fx)
  and key = 'public.members_enabled' and unit_id is null and deleted_at is null;
set local role anon;
select is(public.public_members(), '{"enabled":false}'::jsonb, 'publication switch hides ratings too');
reset role;
select * from finish();
rollback;
