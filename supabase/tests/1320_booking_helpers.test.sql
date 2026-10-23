begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org, core.ulid() as court,
  (date_trunc('day', now() at time zone 'Asia/Manila') + interval '2 days 10 hours') at time zone 'Asia/Manila' as t0;
grant select on fx to public;

create function pg_temp.mk(p_no text, p_name text, p_active boolean) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); mid text := core.ulid(); org text := (select id from public.orgs where code = 'cpc');
begin
  insert into auth.users (id, email) values (u, lower(p_no) || '@members.example.test');
  insert into public.persons (id, org_id, display_name) values (per, org, p_name);
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (org, pid, (select id from public.roles where org_id = org and code = 'member'));
  insert into public.members (id, org_id, person_id, profile_id, member_no) values (mid, org, per, pid, p_no);
  update public.members set status = 'invited' where id = mid;
  update public.members set status = 'pending_approval' where id = mid;
  if p_active then update public.members set status = 'active' where id = mid; end if;
  return u;
end $$;
create temp table us(role text primary key, u uuid);
grant select on us to public;
insert into us values ('me', pg_temp.mk('CPC-2026-9501', 'Zzyzx Tester One', true));
insert into us values ('buddy', pg_temp.mk('CPC-2026-9502', 'Zzyzx Tester Two', true));
insert into us values ('waiting', pg_temp.mk('CPC-2026-9503', 'Zzyzx Tester Three', false));

insert into public.courts (id, org_id, code, name) values ((select court from fx), (select org from fx), 't13-court', 'T13 Court');
insert into public.court_hours (org_id, court_id, weekday, opens_at, closes_at, valid_from)
select (select org from fx), (select court from fx), d, '08:00', '21:00', '2000-01-01' from generate_series(0, 6) d;
insert into public.court_rates (org_id, court_id, rate_per_hour, valid_from) values ((select org from fx), (select court from fx), 150, '2000-01-01');
update public.settings set value = '60'::jsonb where key = 'booking.slot_minutes' and unit_id is null and deleted_at is null;
update public.settings set value = '14'::jsonb where key = 'booking.advance_days' and unit_id is null and deleted_at is null;

select is(has_function_privilege('anon', 'public.find_players(text)', 'execute'), false, 'anonymous callers cannot look up players');

select pg_temp.as_user((select u from us where role = 'me'));
set local role authenticated;
select is((select count(*)::int from public.find_players('Zzyzx')), 1, 'a member finds the other active member by name');
select is((select display_name from public.find_players('9502')), 'Zzyzx Tester Two', 'or by member ID');
select is((select count(*)::int from public.find_players('9501')), 0, 'never themselves');
select is((select count(*)::int from public.find_players('9503')), 0, 'and never a member who is not active');
select throws_ok($$select * from public.find_players('z')$$, '22023', null, 'a one-letter search is refused');
select is((select (public.quote_booking((select court from fx), (select t0 from fx), 120) ->> 'price')::numeric), 300::numeric, 'a quote for two hours at 150 is 300');
select is((select public.quote_booking((select court from fx), (select t0 from fx), 120) ->> 'ok'), 'true', 'and nothing is wrong with it');
select is((select public.quote_booking((select court from fx), (select t0 from fx) - interval '9 hours', 60) ->> 'problem'), 'The court is open 08:00 to 21:00.', 'a time before opening is explained');
select is((select public.quote_booking((select court from fx), now() - interval '1 hour', 60) ->> 'problem'), 'Choose a time in the future.', 'a past time is explained');
select is((select public.quote_booking((select court from fx), (select t0 from fx), 45) ->> 'problem'), 'Choose a whole number of slots, up to 4 hours.', 'a bad length is explained');
select public.request_booking(core.ulid(), (select court from fx), (select t0 from fx), 60, '{}');
select is((select public.quote_booking((select court from fx), (select t0 from fx), 60) ->> 'problem'), 'That time was just taken.', 'a taken slot is explained');
reset role;

select * from finish();
rollback;
