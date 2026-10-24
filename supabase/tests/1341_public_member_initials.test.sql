begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

create temp table fx as select (select id from public.orgs where code = 'cpc') as org;
grant select on fx to public;

insert into public.persons (id, org_id, first_name, last_name, display_name)
values (core.ulid(), (select org from fx), 'Dana', 'Cruz', 'Dana Cruz');
insert into public.members (id, org_id, person_id, member_no)
select core.ulid(), org, id, 'CPC-2026-99340'
from fx cross join lateral (
  select id from public.persons where org_id = fx.org and display_name = 'Dana Cruz'
  order by created_at desc limit 1
) as person;
update public.members set status = 'invited' where member_no = 'CPC-2026-99340';
update public.members set status = 'pending_approval' where member_no = 'CPC-2026-99340';
update public.members set status = 'active' where member_no = 'CPC-2026-99340';

set local role anon;
select is(public.club_home_stats() ->> 'member_initials', 'DC',
  'the public badge uses the representative member first and last initials');
select ok(not (public.club_home_stats() ? 'member_name'), 'the public response does not expose a member name');
reset role;

select * from finish();
rollback;
