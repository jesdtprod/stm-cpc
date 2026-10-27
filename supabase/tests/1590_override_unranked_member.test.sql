begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  (select rank_id from core.rank_chain((select id from public.orgs where code = 'cpc')) limit 1) as rk1,
  (select rank_id from core.rank_chain((select id from public.orgs where code = 'cpc')) offset 1 limit 1) as rk2;
grant select on fx to public;

create function pg_temp.mk(p_role text, p_no text) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); mid text := core.ulid(); org text := (select org from fx);
begin
  insert into auth.users (id, email) values (u, lower(p_no) || '@members.example.test');
  insert into public.persons (id, org_id, display_name, gender, date_of_birth) values (per, org, 'Fake ' || p_no, 'female', '1991-02-03');
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
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2026-98901'), null;
insert into us select 'plain', pg_temp.mk('member', 'CPC-2026-98902'), null;
update us set mid = (select m.id from public.members m join public.profiles p on p.id = m.profile_id where p.auth_user_id = us.u);

create function pg_temp.rank_of(p_member text) returns text language sql as $$
  select rank_id from public.member_ranks where member_id = p_member and deleted_at is null
$$;
grant execute on function pg_temp.rank_of(text) to public;

select is(pg_temp.rank_of((select mid from us where role = 'plain')), null, 'the member starts with no rank');

select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select is((select public.override_member_rank((select mid from us where role = 'plain'), (select rk1 from fx), 'Assessed by the coach', core.ulid()) ->> 'rank_id'),
  (select rk1 from fx), 'an administrator sets a rank on an unranked member');
select is((select count(*)::int from public.member_ranks where member_id = (select mid from us where role = 'plain') and deleted_at is null), 1,
  'the staff screen can read the new current rank');
reset role;

select is(pg_temp.rank_of((select mid from us where role = 'plain')), (select rk1 from fx), 'a current rank row is created');
select is((select from_rank_id from public.rank_history where member_id = (select mid from us where role = 'plain')), null, 'the history starts from no rank');

select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select public.override_member_rank((select mid from us where role = 'plain'), (select rk2 from fx), 'Moved after review', core.ulid());
reset role;
select is(pg_temp.rank_of((select mid from us where role = 'plain')), (select rk2 from fx), 'a second override updates the same row');
select is((select count(*)::int from public.member_ranks where member_id = (select mid from us where role = 'plain')), 1, 'still one current rank row');
select is((select count(*)::int from public.rank_history where member_id = (select mid from us where role = 'plain')), 2, 'two history rows');

select * from finish();
rollback;
