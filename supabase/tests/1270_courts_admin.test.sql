begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as c1, core.ulid() as c2, core.ulid() as mem, core.ulid() as bk, core.ulid() as h1, core.ulid() as rt, core.ulid() as bo,
  core.ulid() as k1, core.ulid() as k2, core.ulid() as k3, core.ulid() as k4, core.ulid() as k5, core.ulid() as k6;
grant select on fx to public;

create function pg_temp.mk(p_org text, p_role text) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); rid text;
begin
  select id into rid from public.roles where org_id = p_org and code = p_role;
  insert into auth.users (id, email) values (u, p_role || '-' || u || '@example.test');
  insert into public.persons (id, org_id, display_name) values (per, p_org, 'Fake ' || p_role);
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, p_org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (p_org, pid, rid);
  if p_role = 'member' then
    insert into public.members (id, org_id, person_id, profile_id, member_no) values ((select mem from fx), p_org, per, pid, 'CPC-2026-9800');
    update public.members set status = 'invited' where id = (select mem from fx);
    update public.members set status = 'pending_approval' where id = (select mem from fx);
    update public.members set status = 'active' where id = (select mem from fx);
  end if;
  return u;
end $$;
create temp table us(role text primary key, u uuid);
grant select on us to public;
insert into us values ('manager', pg_temp.mk((select org from fx), 'manager'));
insert into us values ('member', pg_temp.mk((select org from fx), 'member'));

insert into public.courts (id, org_id, code, name) values
  ((select c1 from fx), (select org from fx), 't9-free', 'T9 Free'),
  ((select c2 from fx), (select org from fx), 't9-busy', 'T9 Busy');
insert into public.bookings (id, org_id, doc_no, court_id, requested_by_member_id, during, rate_snapshot, price_snapshot, court_name_snapshot, payload_hash)
values ((select bk from fx), (select org from fx), 'T9-BK-1', (select c2 from fx), (select mem from fx),
  tstzrange(now() + interval '3 days', now() + interval '3 days 1 hour', '[)'), 0, 0, 'T9 Busy', repeat('b', 64));
update public.bookings set status = 'confirmed', approved_at = now(), approved_by = 'test' where id = (select bk from fx);

-- ---- the delete targets
select is((select count(*)::int from core.soft_delete_targets where table_name in ('courts', 'court_hours', 'court_rates', 'court_blackouts') and permission = 'courts.manage'), 4, 'the four court tables can be deleted through soft_delete');

-- ---- a court with an upcoming booking cannot be deleted
select pg_temp.as_user((select u from us where role = 'manager'));
set local role authenticated;
select throws_ok(format($f$select public.soft_delete('courts', %L, 'closing down', %L)$f$, (select c2 from fx), (select k1 from fx)), '23503', null, 'a court with an upcoming booking cannot be deleted');
select is((select public.soft_delete('courts', (select c1 from fx), 'closing down', (select k2 from fx)) ->> 'ok'), 'true', 'a court without bookings can');
select is((select public.restore_row('courts', (select c1 from fx), (select k3 from fx)) ->> 'ok'), 'true', 'and comes back');
reset role;

-- once the booking is cancelled the court can go
update public.bookings set status = 'cancelled', cancelled_at = now(), cancel_reason = 'test' where id = (select bk from fx);
select pg_temp.as_user((select u from us where role = 'manager'));
set local role authenticated;
select is((select public.soft_delete('courts', (select c2 from fx), 'closing down', (select k4 from fx)) ->> 'ok'), 'true', 'after the booking is cancelled the court can be deleted');
reset role;

-- a booking that already ended does not block
update public.courts set deleted_at = null, deleted_by = null, delete_reason = null where id = (select c2 from fx) and false;
select is((select count(*)::int from public.courts where id = (select c2 from fx) and deleted_at is not null), 1, 'the court is marked deleted');

-- ---- hours, rates and blackouts
select pg_temp.as_user((select u from us where role = 'manager'));
set local role authenticated;
insert into public.court_hours (id, org_id, court_id, weekday, opens_at, closes_at, valid_from)
values ((select h1 from fx), (select org from fx), (select c1 from fx), 1, '08:00', '21:00', '2030-01-01');
select throws_ok(format($f$insert into public.court_hours (org_id, court_id, weekday, opens_at, closes_at, valid_from) values (%L, %L, 1, '09:00', '20:00', '2030-06-01')$f$, (select org from fx), (select c1 from fx)), '23P01', null, 'overlapping hours for the same court and weekday are refused');
select throws_ok(format($f$insert into public.court_hours (org_id, court_id, weekday, opens_at, closes_at, valid_from) values (%L, %L, 2, '20:00', '08:00', '2030-01-01')$f$, (select org from fx), (select c1 from fx)), '23514', null, 'closing before opening is refused');
insert into public.court_rates (id, org_id, court_id, rate_per_hour, valid_from) values ((select rt from fx), (select org from fx), (select c1 from fx), 250, '2030-01-01');
select throws_ok(format($f$insert into public.court_rates (org_id, court_id, rate_per_hour, valid_from) values (%L, %L, -5, '2030-01-01')$f$, (select org from fx), (select c1 from fx)), '23514', null, 'a negative rate is refused');
insert into public.court_blackouts (id, org_id, court_id, during, reason) values ((select bo from fx), (select org from fx), (select c1 from fx), tstzrange('2030-02-01 09:00+08', '2030-02-01 12:00+08', '[)'), 'resurfacing');
select throws_ok(format($f$insert into public.court_blackouts (org_id, court_id, during, reason) values (%L, %L, tstzrange('2030-02-01 12:00+08', '2030-02-01 09:00+08', '[)'), 'bad')$f$, (select org from fx), (select c1 from fx)), null, null, 'a backwards range is refused');
select is((select public.soft_delete('court_blackouts', (select bo from fx), 'no longer needed', (select k5 from fx)) ->> 'ok'), 'true', 'a blackout can be deleted with a reason');
reset role;

-- members cannot manage courts
select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
select throws_ok(format($f$select public.soft_delete('court_rates', %L, 'no longer needed', %L)$f$, (select rt from fx), (select k6 from fx)), '42501', null, 'a member cannot delete a rate');
select throws_ok(format($f$insert into public.court_rates (org_id, rate_per_hour, valid_from) values (%L, 100, '2030-01-01')$f$, (select org from fx)), '42501', null, 'nor add one');
reset role;

select * from finish();
rollback;
