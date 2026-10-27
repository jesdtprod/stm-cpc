
begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();
create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  (public.club_home_stats() ->> 'active_members')::integer as before_count;
grant select on fx to public;
create temp table people(n integer, person_id text, member_id text, path text);
grant select on people to public;
select set_config('core.rpc', 'on', true);
do $$
declare i integer; pid text; mid text; org text := (select org from fx); p text;
begin
  for i in 1..25 loop
    pid := core.ulid(); mid := core.ulid(); p := org || '/' || pid || '/fake-landing.jpg';
    insert into public.persons(id, org_id, first_name, last_name, display_name, avatar_path)
      values(pid, org, 'Fake', 'Member', 'Fake Landing Member ' || i, p);
    insert into public.members(id, org_id, person_id, member_no)
      values(mid, org, pid, 'CPC-2026-' || (99600 + i)::text);
    update public.members set status = 'invited' where id = mid;
    update public.members set status = 'pending_approval' where id = mid;
    if i <> 22 then update public.members set status = 'active' where id = mid; end if;
    if i = 23 then update public.members set status = 'suspended', status_reason = 'Fake test' where id = mid; end if;
    if i = 24 then update public.persons set deleted_at = now(), deleted_by = 'system', delete_reason = 'Fake test' where id = pid; end if;
    if i = 25 then
      update public.members set status = 'archived', status_reason = 'Fake test' where id = mid;
      update public.members set deleted_at = now(), deleted_by = 'system', delete_reason = 'Fake test' where id = mid; end if;
    insert into storage.objects(bucket_id, name) values('avatars', p);
    insert into people values(i, pid, mid, p);
  end loop;
end $$;
select set_config('core.rpc', 'off', true);
create temp table shown as select b ->> 'avatar_path' as path
  from jsonb_array_elements(public.club_home_stats() -> 'member_badges') b;
grant select on shown to public;
create temp table spare as select (select org from fx) || '/' || core.ulid() || '/fake-unused.jpg' as path;
grant select on spare to public;
insert into storage.objects(bucket_id, name) select 'avatars', path from spare;
create temp table other_club as select core.ulid() as org, core.ulid() as per, core.ulid() as mem;
grant select on other_club to public;
insert into public.orgs(id, org_id, code, name) select org, org, 'fake_landing_org', 'Fake Landing Club' from other_club;
insert into public.persons(id, org_id, display_name, avatar_path) select per, org, 'Fake Other Club Member', org || '/' || per || '/fake.jpg' from other_club;
insert into public.members(id, org_id, person_id, member_no) select mem, org, per, 'CPC-2026-99700' from other_club;
update public.members set status = 'invited' where id = (select mem from other_club);
update public.members set status = 'pending_approval' where id = (select mem from other_club);
update public.members set status = 'active' where id = (select mem from other_club);
insert into storage.objects(bucket_id, name) select 'avatars', org || '/' || per || '/fake.jpg' from other_club;
select is((select public from storage.buckets where id = 'avatars'), false, 'avatar bucket remains private');
set local role anon;
select is((public.club_home_stats() ->> 'active_members')::integer, (select before_count + 21 from fx), 'only active nondeleted club members are counted');
select is(jsonb_array_length(public.club_home_stats() -> 'member_badges'), 15, 'the public strip stays limited to 15 members');
select ok(not exists(select 1 from jsonb_array_elements(public.club_home_stats() -> 'member_badges') b, jsonb_object_keys(b) k where k not in ('initials','avatar_path')), 'badges reveal only initials and selected photo paths');
select is((select count(*)::integer from storage.objects where bucket_id = 'avatars' and name in (select path from shown)), 15, 'anonymous visitors can read the selected photos');
select is((select count(*)::integer from storage.objects where bucket_id = 'avatars' and name in (select path from people where n <= 21 and path not in (select path from shown))), 0, 'active member photos outside the public strip stay private');
select is((select count(*)::integer from storage.objects where bucket_id = 'avatars' and name in (select path from people where n >= 22)), 0, 'pending, suspended and deleted member photos stay private');
select is((select count(*)::integer from storage.objects where name = (select path from spare)), 0, 'unreferenced uploads stay private');
select is((select count(*)::integer from storage.objects where name = (select org || '/' || per || '/fake.jpg' from other_club)), 0, 'another club photos stay private');
select throws_ok(format($f$insert into storage.objects(bucket_id,name) values('avatars',%L)$f$, (select org from fx) || '/fake/no-upload.jpg'), '42501', null, 'anonymous visitors cannot upload');
reset role;
create temp table removed as select p.* from people p join shown s on s.path = p.path order by p.n limit 1;
grant select on removed to public;
update public.members set status = 'suspended', status_reason = 'Fake revoked public photo' where id = (select member_id from removed);
set local role anon;
select is((select count(*)::integer from storage.objects where name = (select path from removed)), 0, 'suspension removes new public read access');
reset role;
create temp table cleared as select p.* from people p join shown s on s.path = p.path where p.member_id <> (select member_id from removed) order by p.n limit 1;
grant select on cleared to public;
update public.persons set avatar_path = null where id = (select person_id from cleared);
set local role anon;
select is((select count(*)::integer from storage.objects where name = (select path from cleared)), 0, 'clearing the profile photo removes public access to its old file');
select ok(exists(select 1 from jsonb_array_elements(public.club_home_stats() -> 'member_badges') b where b -> 'avatar_path' = 'null'::jsonb and b ->> 'initials' = 'FM'), 'members without photos still have initials');
reset role;
select * from finish();
rollback;
