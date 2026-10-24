begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

create temp table fx as
  select (select id from public.orgs where code = 'cpc') as org,
    (public.club_home_stats() ->> 'active_members')::int as active_before;
grant select on fx to public;

insert into public.persons (id, org_id, display_name)
values (core.ulid(), (select org from fx), 'Public count active test member');
insert into public.members (id, org_id, person_id, member_no)
select core.ulid(), org, id, 'CPC-2026-99330'
from fx cross join lateral (
  select id from public.persons
  where org_id = fx.org and display_name = 'Public count active test member'
  order by created_at desc limit 1
) as person;
update public.members set status = 'invited' where member_no = 'CPC-2026-99330';
update public.members set status = 'pending_approval' where member_no = 'CPC-2026-99330';
update public.members set status = 'active' where member_no = 'CPC-2026-99330';

select is(has_function_privilege('anon', 'public.club_home_stats()', 'execute'), true,
  'anonymous visitors can read the public member total');
set local role anon;
select is((public.club_home_stats() ->> 'active_members')::int,
  (select active_before + 1 from fx), 'the public total counts active members');
select ok(not (public.club_home_stats() ? 'member_name'), 'the public response contains no full member name');
reset role;

select * from finish();
rollback;
