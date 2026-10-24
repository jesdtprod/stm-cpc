begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

create temp table fx as
  select (select id from public.orgs where code = 'cpc') as org,
    (public.club_home_stats() ->> 'active_members')::int as active_before;
grant select on fx to public;

do $$
declare
  org_id text := (select org from fx);
  person_id text;
  v_member_no text;
begin
  for member_index in 1..16 loop
    person_id := core.ulid();
    v_member_no := 'CPC-2026-' || lpad((99400 + member_index)::text, 5, '0');
    insert into public.persons (id, org_id, first_name, last_name, display_name)
    values (person_id, org_id, 'Active' || member_index, 'Member', 'Active ' || member_index || ' Member');
    insert into public.members (id, org_id, person_id, member_no)
    values (core.ulid(), org_id, person_id, v_member_no);
    update public.members m set status = 'invited' where m.member_no = v_member_no;
    update public.members m set status = 'pending_approval' where m.member_no = v_member_no;
    update public.members m set status = 'active' where m.member_no = v_member_no;
  end loop;
end $$;

insert into public.persons (id, org_id, first_name, last_name, display_name)
values (core.ulid(), (select org from fx), 'Pending', 'Member', 'Pending Member');
insert into public.members (id, org_id, person_id, member_no)
select core.ulid(), org, id, 'CPC-2026-99450'
from fx cross join lateral (
  select id from public.persons where org_id = fx.org and display_name = 'Pending Member'
  order by created_at desc limit 1
) as person;
update public.members set status = 'invited' where member_no = 'CPC-2026-99450';
update public.members set status = 'pending_approval' where member_no = 'CPC-2026-99450';

set local role anon;
select is((public.club_home_stats() ->> 'active_members')::int,
  (select active_before + 16 from fx), 'the count excludes pending members');
select is(jsonb_array_length(public.club_home_stats() -> 'member_badges'), 15,
  'the public badge list contains no more than 15 approved members');
select ok(not exists (
  select 1 from jsonb_array_elements(public.club_home_stats() -> 'member_badges') badge
  where badge ->> 'initials' = 'PM'
), 'pending members are absent from the public badge list');
reset role;

select * from finish();
rollback;
