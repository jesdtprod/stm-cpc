
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

create temp table draws(n integer, stats jsonb);
select setseed(0.13);
insert into draws values(1,public.club_home_stats());
select setseed(0.89);
insert into draws values(2,public.club_home_stats());
grant select on draws to public;
select is((select provolatile::text from pg_proc where oid='public.club_home_stats()'::regprocedure),'v','each stats request can draw a fresh random sample');
set local role anon;
select is((public.club_home_stats()->>'active_members')::integer,(select before_count+21 from fx),'only active nondeleted members count');
select is((select jsonb_array_length(stats->'member_badges') from draws where n=1),15,'first draw is capped at 15');
select is((select jsonb_array_length(stats->'member_badges') from draws where n=2),15,'second draw is capped at 15');
select ok((select stats->'member_badges' from draws where n=1) is distinct from (select stats->'member_badges' from draws where n=2),'different random draws change the selection or order');
select ok(not exists(select 1 from draws d,jsonb_array_elements(d.stats->'member_badges') b where b->>'avatar_path' in(select path from people where n>=22)),'pending suspended and deleted people never appear');
select ok(not exists(select 1 from draws d,jsonb_array_elements(d.stats->'member_badges') b,jsonb_object_keys(b) k where k not in('initials','avatar_path')),'draws expose only initials and current avatar paths');
select ok(not exists(select 1 from draws d,jsonb_array_elements(d.stats->'member_badges') b where nullif(b->>'initials','') is null),'every sampled member has initials');
select throws_ok($$select core.landing_active_member_photo('fake/private.jpg')$$,'42501',null,'anonymous callers cannot access the private core schema directly');
select ok(not exists(select 1 from draws d,jsonb_array_elements(d.stats->'member_badges') b join people p on p.path=b->>'avatar_path' group by d.n,p.member_id having count(*)>1),'a fake member cannot occur twice within a draw');
select is((select count(*)::integer from storage.objects where name in(select path from people where n<=21)),21,'all active candidates can load photos without rerunning random selection for authorization');
select is((select count(*)::integer from storage.objects where name in(select path from people where n>=22)),0,'inactive and deleted photo files stay private');
reset role;
select is((select public from storage.buckets where id='avatars'),false,'bucket remains private');
select ok(not exists(select 1 from draws d,jsonb_array_elements(d.stats->'member_badges') b where b->>'avatar_path' is not null and not core.landing_active_member_photo(b->>'avatar_path')),'all selected photo paths remain eligible when signed in a separate request');
select * from finish();
rollback;
