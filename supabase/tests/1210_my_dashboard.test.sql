begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as cat, core.ulid() as lad, core.ulid() as rk, core.ulid() as court, core.ulid() as bk, core.ulid() as mem;
grant select on fx to public;

-- one role-holder per role; the member also gets a person, a member row, a rank and a booking
create function pg_temp.mk(p_org text, p_role text, p_with_member boolean) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); rid text;
begin
  select id into rid from public.roles where org_id = p_org and code = p_role;
  insert into auth.users (id, email) values (u, p_role || '-' || u || '@example.test');
  insert into public.persons (id, org_id, display_name) values (per, p_org, 'Fake ' || p_role);
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, p_org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (p_org, pid, rid);
  if p_with_member then
    insert into public.members (id, org_id, person_id, profile_id, member_no)
    values ((select mem from fx), p_org, per, pid, 'CPC-2026-9700');
  end if;
  return u;
end $$;
create temp table us(role text primary key, u uuid);
grant select on us to public;
insert into us values ('admin', pg_temp.mk((select org from fx), 'admin', false));
insert into us values ('front_desk', pg_temp.mk((select org from fx), 'front_desk', false));
insert into us values ('member', pg_temp.mk((select org from fx), 'member', true));

insert into public.categories (id, org_id, code, name) values ((select cat from fx), (select org from fx), 't6-cat', 'T6 Cat');
insert into public.rank_ladders (id, org_id, category_id) values ((select lad from fx), (select org from fx), (select cat from fx));
insert into public.ranks (id, org_id, ladder_id, code, name, sort_order, is_starting) values ((select rk from fx), (select org from fx), (select lad from fx), 't6-low', 'T6 Low', 0, true);
insert into public.courts (id, org_id, code, name) values ((select court from fx), (select org from fx), 't6-court', 'T6 Court');
update public.members set status = 'invited' where id = (select mem from fx);
update public.members set status = 'pending_approval' where id = (select mem from fx);
update public.members set status = 'active' where id = (select mem from fx);
insert into public.member_ranks (org_id, member_id, rank_id) values ((select org from fx), (select mem from fx), (select rk from fx));
insert into public.bookings (id, org_id, doc_no, court_id, requested_by_member_id, during, rate_snapshot, price_snapshot, court_name_snapshot, payload_hash)
values ((select bk from fx), (select org from fx), 'T6-BK-1', (select court from fx), (select mem from fx),
  tstzrange(now() + interval '2 days', now() + interval '2 days 1 hour', '[)'), 0, 0, 'T6 Court', repeat('a', 64));

-- ---- access
select is(has_function_privilege('anon', 'public.my_dashboard()', 'execute'), false, 'anonymous callers cannot call it');
select is(has_function_privilege('authenticated', 'public.my_dashboard()', 'execute'), true, 'signed-in users can');

-- ---- a member sees their own figures and no staff figures
select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
create temp table m_view as select public.my_dashboard() as d;
reset role;
grant select on m_view to public;
select is((select d ->> 'role_code' from m_view), 'member', 'the role is reported');
select is((select d -> 'member' -> 'rank' ->> 'name' from m_view), 'T6 Low', 'the current rank is shown');
select is((select d -> 'member' -> 'rank' ->> 'category' from m_view), 'T6 Cat', 'with its category');
select is((select (d -> 'member' ->> 'upcoming_bookings')::int from m_view), 1, 'the upcoming booking is counted');
select is((select d -> 'member' -> 'next_booking' ->> 'court' from m_view), 'T6 Court', 'and named');
select is((select (d -> 'member' ->> 'open_registrations')::int from m_view), 0, 'no registrations yet');
select is((select (d -> 'member' ->> 'unread_notices')::int from m_view), 0, 'no unread notices yet');
select ok(not ((select d from m_view) ? 'pending_members'), 'a member does not get the approval count');
select ok(not ((select d from m_view) ? 'pending_proofs'), 'nor the payment proof count');
select ok(not ((select d from m_view) ? 'todays_bookings'), 'nor the day''s bookings');

-- ---- front desk: today's bookings, no approvals
select pg_temp.as_user((select u from us where role = 'front_desk'));
set local role authenticated;
create temp table f_view as select public.my_dashboard() as d;
reset role;
grant select on f_view to public;
select ok((select d from f_view) ? 'todays_bookings', 'front desk sees today''s bookings');
select ok(not ((select d from f_view) ? 'pending_members'), 'but not the approval queue');
select ok(not ((select d from f_view) ? 'member'), 'and has no member card without a member record');

-- ---- admin: every staff figure
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
create temp table a_view as select public.my_dashboard() as d;
reset role;
grant select on a_view to public;
select ok((select d from a_view) ?& array['pending_members', 'pending_proofs', 'pending_bookings', 'todays_bookings', 'active_events'], 'an admin sees every staff figure');
select is((select (d ->> 'pending_bookings')::int from a_view) >= 1, true, 'the pending booking is in the approval count');
select is((select (d ->> 'pending_members')::int from a_view), (select count(*)::int from public.members where status = 'pending_approval' and deleted_at is null), 'the member queue matches the table');

-- ---- signed out
select set_config('request.jwt.claims', '', true);
set local role authenticated;
select throws_ok($$select public.my_dashboard()$$, '42501', null, 'no profile, no figures');
reset role;

select * from finish();
rollback;
