begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

create temp table fx as select (select id from public.orgs where code = 'cpc') as org;
grant select on fx to public;

-- a fake member in the given status, with a photo path
create function pg_temp.mk(p_status text, p_name text) returns text language plpgsql as $$
declare per text := core.ulid(); mid text := core.ulid(); org text := (select org from fx);
begin
  insert into public.persons (id, org_id, display_name, avatar_path) values (per, org, p_name, 'fake/' || per || '.jpg');
  insert into public.members (id, org_id, person_id, member_no, status)
  values (mid, org, per, 'CPC-2031-' || lpad((floor(random() * 90000) + 10000)::text, 5, '0'), 'imported');
  if p_status = 'invited' then
    update public.members set status = 'invited' where id = mid;
  elsif p_status in ('pending_approval', 'active', 'suspended') then
    update public.members set status = 'invited' where id = mid;
    update public.members set status = 'pending_approval' where id = mid;
    if p_status in ('active', 'suspended') then
      update public.members set status = 'active' where id = mid;
    end if;
    if p_status = 'suspended' then
      update public.members set status = 'suspended', status_reason = 'fake' where id = mid;
    end if;
  end if;
  return per;
end $$;
create temp table ms(status text primary key, per text);
grant select on ms to public;
insert into ms values ('active', pg_temp.mk('active', '000 Fake Active'));
insert into ms values ('imported', pg_temp.mk('imported', '000 Fake Imported'));
insert into ms values ('invited', pg_temp.mk('invited', '000 Fake Invited'));
insert into ms values ('pending_approval', pg_temp.mk('pending_approval', '000 Fake Pending'));
insert into ms values ('suspended', pg_temp.mk('suspended', '000 Fake Suspended'));

update public.persons set first_name='SAMPLE', last_name='PLAYER', middle_name='(BEATRICE)', suffix='Jr.'
where id=(select per from ms where status='active');
create temp table expected as select m.member_no from public.members m join ms on ms.per=m.person_id where ms.status='active';
grant select on expected to public;
set local role anon;
select is((select x->>'member_no' from jsonb_array_elements(public.public_members()->'members') x where x->>'name'='000 Fake Active'),(select member_no from expected),'publishes the actual CPC number, never a generated internal ID');
select is((select x->>'first_name' from jsonb_array_elements(public.public_members()->'members') x where x->>'name'='000 Fake Active'),'SAMPLE','saved first name supports the shared formatter');
select is((select x->>'last_name' from jsonb_array_elements(public.public_members()->'members') x where x->>'name'='000 Fake Active'),'PLAYER','saved last name supports surname-first display');
select is((select x->>'middle_name' from jsonb_array_elements(public.public_members()->'members') x where x->>'name'='000 Fake Active'),'B','only the middle initial is published, including leading punctuation');
select is((select x->>'suffix' from jsonb_array_elements(public.public_members()->'members') x where x->>'name'='000 Fake Active'),'Jr.','saved extension supports shared proper-case display');
select is((select x->>'first_name' from jsonb_array_elements(public.public_members()->'members') x where x->>'name'='000 Fake Imported'),null::text,'display-only imports do not invent name parts');
select ok(not exists(select 1 from jsonb_array_elements(public.public_members()->'members') x where x ?| array['id','member_id','person_id','profile_id','email','mobile','birth_date','dupr_id']),'internal identifiers and private profile data remain excluded');
select ok(not exists(select 1 from jsonb_array_elements(public.public_members()->'members') x where x->>'name' in ('000 Fake Suspended','000 Fake Pending')),'ineligible members remain excluded');
reset role;
update public.settings set value='false' where org_id=(select org from fx) and key='public.members_enabled' and unit_id is null and deleted_at is null;
set local role anon;
select is(public.public_members(),'{"enabled":false}'::jsonb,'unpublished directory returns no names or CPC numbers');
reset role;
select * from finish();
rollback;
