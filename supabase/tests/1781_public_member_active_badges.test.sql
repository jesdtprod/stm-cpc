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

set local role anon;
select is((select (m->>'is_active')::boolean from jsonb_array_elements(public.public_members()->'members') m where m->>'name'='000 Fake Active'),true,'active member receives an active badge');
select is((select (m->>'is_active')::boolean from jsonb_array_elements(public.public_members()->'members') m where m->>'name'='000 Fake Imported'),false,'imported member is not presented as active');
select is((select (m->>'is_active')::boolean from jsonb_array_elements(public.public_members()->'members') m where m->>'name'='000 Fake Invited'),false,'invited member is not presented as active');
select ok(not exists(select 1 from jsonb_array_elements(public.public_members()->'members') m where m->>'name' in ('000 Fake Pending','000 Fake Suspended')),'inactive statuses excluded by publication rules stay hidden');
select ok(not exists(select 1 from jsonb_array_elements(public.public_members()->'members') m where m ?| array['status','status_reason','member_id','person_id','profile_id','email','mobile','birth_date']),'badges do not publish detailed status, reasons, internal IDs or contacts');
select ok(not exists(select 1 from jsonb_array_elements(public.public_members()->'members') m where jsonb_typeof(m->'is_active') is distinct from 'boolean'),'active flag is always a boolean');
reset role;
update public.settings set value='false' where org_id=(select org from fx) and key='public.members_enabled' and unit_id is null and deleted_at is null;
set local role anon;
select is(public.public_members(),'{"enabled":false}'::jsonb,'turning off publication also hides active flags');
reset role;
select * from finish();
rollback;
