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

create function pg_temp.names() returns text[] language sql as $$
  select coalesce(array_agg(x ->> 'name' order by x ->> 'name'), '{}')
  from jsonb_array_elements(public.public_members() -> 'members') x where x ->> 'name' like '000 Fake %'
$$;
grant execute on function pg_temp.names() to anon;

select is(core.setting_bool((select org from fx), 'public.members_enabled', false), true, 'the page starts published');
set local role anon;
select is(pg_temp.names(), array['000 Fake Active', '000 Fake Imported', '000 Fake Invited'],
  'visitors see active, imported and invited members only');
select is((select count(*)::int from jsonb_array_elements(public.public_members() -> 'members') x
  where x ?| array['member_id', 'email', 'mobile', 'birth_date', 'dupr_id']), 0,
  'no internal member ID or contact data is returned');
select is((select array_agg(k order by k) from (select distinct jsonb_object_keys(x) k
  from jsonb_array_elements(public.public_members() -> 'members') x) t),
  array['category', 'first_name', 'last_name', 'member_no', 'middle_name', 'name', 'photo', 'rank', 'suffix'],
  'only approved name fields, CPC number, photo, category and rank');
reset role;
select is(core.public_member_photo((select 'fake/' || per || '.jpg' from ms where status = 'invited')), true,
  'an invited member''s photo may be signed');
select is(core.public_member_photo((select 'fake/' || per || '.jpg' from ms where status = 'suspended')), false,
  'a suspended member''s photo may not');
select is(core.public_member_photo('fake/not-a-member.jpg'), false, 'nor any other file');
select is(has_function_privilege('anon', 'core.public_member_rows()', 'execute'), false,
  'the row helper itself stays private');
reset role;

-- the club switches the page off
update public.settings set value = 'false' where org_id = (select org from fx) and key = 'public.members_enabled'
  and unit_id is null and deleted_at is null;
set local role anon;
select is(public.public_members(), '{"enabled": false}'::jsonb, 'switched off, no names leave the database');
reset role;
select is(core.public_member_photo((select 'fake/' || per || '.jpg' from ms where status = 'active')), false,
  'and no photo can be signed');
reset role;

select is(core.setting_valid('public.members_enabled', '"yes"'), false, 'the switch takes true or false only');

select * from finish();
rollback;
