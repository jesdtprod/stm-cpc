begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();
create temp table fx as select id as org from public.orgs where code='cpc' and deleted_at is null;
grant select on fx to public;
update public.settings set value='true' where org_id=(select org from fx) and key='public.members_enabled' and unit_id is null and deleted_at is null;
create temp table before_count as select count(*)::integer as n from core.public_member_rows();
grant select on before_count to public;
create temp table fake_members as select n,core.ulid() as per,core.ulid() as mid from generate_series(1,1005) n;
insert into public.persons(id,org_id,display_name)
select per,(select org from fx),'Zz Fake Directory Member '||lpad(n::text,4,'0') from fake_members;
insert into public.members(id,org_id,person_id,member_no,status)
select mid,(select org from fx),per,'CPC-2098-'||lpad(n::text,5,'0'),'imported' from fake_members;
set local role anon;
select is(jsonb_array_length(public.public_members()->'members'),(select n+1005 from before_count),'public directory returns the complete eligible total beyond 1000');
select is((select count(*)::integer from jsonb_array_elements(public.public_members()->'members') m where m->>'name' like 'Zz Fake Directory Member %'),1005,'every fake member is included without truncation');
select ok(exists(select 1 from jsonb_array_elements(public.public_members()->'members') m where m->>'member_no'='CPC-2098-01005'),'the last fake member can be found beyond the previous cap');
select ok(not exists(select 1 from jsonb_array_elements(public.public_members()->'members') m where m ?| array['member_id','person_id','profile_id','email','mobile','birth_date','dupr_id']),'full directory still excludes internal IDs and private contact data');
reset role;
update public.settings set value='false' where org_id=(select org from fx) and key='public.members_enabled' and unit_id is null and deleted_at is null;
set local role anon;
select is(public.public_members(),'{"enabled":false}'::jsonb,'unpublished directory still reveals no member data');
reset role;
select * from finish();
rollback;
