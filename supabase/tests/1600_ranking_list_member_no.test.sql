-- Self-contained member-number tests using the ranking fixture pattern.
begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create temp table hid as select core.ulid() as h1, core.ulid() as h2, core.ulid() as h3;
grant select on hid to public;
create temp table chain as select * from core.rank_chain((select id from public.orgs where code = 'cpc'));
grant select on chain to public;

create function pg_temp.mk(p_role text, p_no text, p_name text, p_idx int, p_active boolean) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); mid text := core.ulid(); org text := (select id from public.orgs where code = 'cpc');
begin
  insert into auth.users (id, email) values (u, lower(p_no) || '@members.example.test');
  insert into public.persons (id, org_id, display_name, gender, date_of_birth) values (per, org, p_name, 'male', '1990-01-01');
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (org, pid, (select id from public.roles where org_id = org and code = p_role));
  insert into public.members (id, org_id, person_id, profile_id, member_no) values (mid, org, per, pid, p_no);
  update public.members set status = 'invited' where id = mid;
  update public.members set status = 'pending_approval' where id = mid;
  update public.members set status = 'active' where id = mid;
  if p_idx is not null then
    insert into public.member_ranks (org_id, member_id, rank_id) values (org, mid, (select rank_id from chain where idx = p_idx));
  end if;
  if not p_active then
    update public.members set status = 'suspended', status_reason = 'test' where id = mid;
  end if;
  return u;
end $$;
create temp table us(role text primary key, u uuid, mid text);
grant select on us to public;
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2026-97601', 'Zzyzx Admin', null, true), null;
insert into us select 'low', pg_temp.mk('member', 'CPC-2026-97602', 'Zzyzx Low', 1, true), null;
insert into us select 'mid', pg_temp.mk('member', 'CPC-2026-97603', 'Zzyzx Mid', 4, true), null;
insert into us select 'high', pg_temp.mk('member', 'CPC-2026-97604', 'Zzyzx High', 7, true), null;
insert into us select 'twin', pg_temp.mk('member', 'CPC-2026-97605', 'Zzyzx Another Mid', 4, true), null;
insert into us select 'gone', pg_temp.mk('member', 'CPC-2026-97606', 'Zzyzx Suspended', 8, false), null;
insert into us select 'norank', pg_temp.mk('member', 'CPC-2026-97607', 'Zzyzx NoRank', null, true), null;
update us set mid = (select m.id from public.members m join public.profiles p on p.id = m.profile_id where p.auth_user_id = us.u);

select pg_temp.as_user((select u from us where role = 'low')); set local role authenticated;
create temp table rl_1600 as select * from public.ranking_list();
reset role;
grant select on rl_1600 to public;

select ok((select count(*) from rl_1600 where display_name like 'Zzyzx%') = 4, 'four active, ranked members listed');
select is((select member_no from rl_1600 where display_name = 'Zzyzx High'), 'CPC-2026-97604', 'members see the member ID in the ranking list');
select is((select member_no from rl_1600 where display_name = 'Zzyzx Low'), 'CPC-2026-97602', 'every ranked member includes their member ID');

select * from finish();
rollback;

