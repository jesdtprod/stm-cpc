begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as court, core.ulid() as bk1, core.ulid() as bk2, core.ulid() as bk3,
  core.ulid() as p1, core.ulid() as p2, core.ulid() as p3, core.ulid() as p4, core.ulid() as p5, core.ulid() as p6, core.ulid() as p7,
  core.ulid() as k1, core.ulid() as k2, core.ulid() as k3, core.ulid() as k4, core.ulid() as k5, core.ulid() as k6, core.ulid() as k7,
  core.ulid() as k8, core.ulid() as k9, core.ulid() as k10,
  (date_trunc('day', now() at time zone 'Asia/Manila') + interval '2 days 10 hours') at time zone 'Asia/Manila' as t0;
grant select on fx to public;

create function pg_temp.mk(p_role text, p_no text) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); mid text := core.ulid(); org text := (select id from public.orgs where code = 'cpc');
begin
  insert into auth.users (id, email) values (u, lower(p_no) || '@members.example.test');
  insert into public.persons (id, org_id, display_name) values (per, org, 'Fake ' || p_no);
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (org, pid, (select id from public.roles where org_id = org and code = p_role));
  insert into public.members (id, org_id, person_id, profile_id, member_no) values (mid, org, per, pid, p_no);
  update public.members set status = 'invited' where id = mid;
  update public.members set status = 'pending_approval' where id = mid;
  update public.members set status = 'active' where id = mid;
  return u;
end $$;
create temp table us(role text primary key, u uuid, mid text, pid text);
grant select on us to public;
insert into us select 'member', pg_temp.mk('member', 'CPC-2026-9401'), null, null;
insert into us select 'other', pg_temp.mk('member', 'CPC-2026-9402'), null, null;
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2026-9403'), null, null;
insert into us select 'desk', pg_temp.mk('front_desk', 'CPC-2026-9404'), null, null;
update us set mid = m.id, pid = m.profile_id from public.members m
where m.member_no = case us.role when 'member' then 'CPC-2026-9401' when 'other' then 'CPC-2026-9402' when 'admin' then 'CPC-2026-9403' else 'CPC-2026-9404' end;

insert into public.courts (id, org_id, code, name) values ((select court from fx), (select org from fx), 't12-court', 'T12 Court');
insert into public.court_hours (org_id, court_id, weekday, opens_at, closes_at, valid_from)
select (select org from fx), (select court from fx), d, '00:00', '23:59:59', '2000-01-01' from generate_series(0, 6) d;
insert into public.court_rates (org_id, court_id, rate_per_hour, valid_from) values ((select org from fx), (select court from fx), 300, '2000-01-01');
update public.settings set value = '60'::jsonb where key = 'booking.slot_minutes' and unit_id is null and deleted_at is null;
update public.settings set value = '14'::jsonb where key = 'booking.advance_days' and unit_id is null and deleted_at is null;
update public.settings set value = 'true'::jsonb where key = 'booking.approval_required' and unit_id is null and deleted_at is null;
update public.settings set value = 'false'::jsonb where key = 'payments.required.court_booking' and unit_id is null and deleted_at is null;
update public.settings set value = '["cash", "gcash", "bank_transfer"]'::jsonb where key = 'payments.methods' and unit_id is null and deleted_at is null;
update public.settings set value = 'true'::jsonb where key = 'payments.proof_required_non_cash' and unit_id is null and deleted_at is null;

-- two bookings of 600 and 300
select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
select public.request_booking((select bk1 from fx), (select court from fx), (select t0 from fx), 120, '{}');
select public.request_booking((select bk2 from fx), (select court from fx), (select t0 from fx) + interval '5 hours', 60, '{}');
reset role;

-- the member's proof files, as the storage API would leave them
insert into storage.objects (bucket_id, name, owner_id, metadata) values
  ('payment-proofs', (select org from fx) || '/' || (select pid from us where role = 'member') || '/proof-a.png', (select u from us where role = 'member')::text, '{"mimetype": "image/png", "size": 1234}'),
  ('payment-proofs', (select org from fx) || '/' || (select pid from us where role = 'member') || '/proof-c.png', (select u from us where role = 'member')::text, '{"mimetype": "image/png", "size": 500}'),
  ('payment-proofs', (select org from fx) || '/' || (select pid from us where role = 'member') || '/proof-d.png', (select u from us where role = 'member')::text, '{"mimetype": "application/pdf", "size": 700}'),
  ('payment-proofs', (select org from fx) || '/' || (select pid from us where role = 'other') || '/proof-b.png', (select u from us where role = 'other')::text, '{"mimetype": "image/png", "size": 999}');

-- ---- access
select is(has_function_privilege('anon', 'public.submit_payment(text,text,text,text,numeric,text)', 'execute'), false, 'anonymous callers cannot pay');

-- ---- submit
select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
create temp table s1 as select public.submit_payment((select p1 from fx), (select bk1 from fx), 'cash', null, 200, null) as r;
reset role;
grant select on s1 to public;
select is((select r ->> 'status' from s1), 'submitted', 'a cash payment is submitted');
select ok((select r ->> 'doc_no' from s1) ~ '^PAY-\d{4}-\d{5}$', 'with a payment number');
select is((select count(*)::int from public.ledger_entries where source_type = 'payment' and source_id = (select p1 from fx)), 0, 'nothing is posted until an admin verifies it');
select is((select status from public.bookings where id = (select bk1 from fx)), 'pending_approval', 'and the booking is not confirmed by it');
set local role authenticated;
select is((select public.submit_payment((select p1 from fx), (select bk1 from fx), 'cash', null, 200, null) ->> 'id'), (select p1 from fx), 'sending it again returns the same payment');
select throws_ok(format($f$select public.submit_payment(%L, %L, 'cash', null, 250, null)$f$, (select p1 from fx), (select bk1 from fx)), 'CP422', null, 'another request under the same ID is refused');
select throws_ok(format($f$select public.submit_payment(%L, %L, 'gcash', 'REF1', 100, null)$f$, (select p2 from fx), (select bk1 from fx)), '22023', 'attach the proof of payment', 'a non-cash payment needs its proof');
select throws_ok(format($f$select public.submit_payment(%L, %L, 'cheque', null, 100, null)$f$, (select p2 from fx), (select bk1 from fx)), '22023', 'the club does not accept that payment method', 'a method the club does not accept is refused');
select throws_ok(format($f$select public.submit_payment(%L, %L, 'cash', null, 0, null)$f$, (select p2 from fx), (select bk1 from fx)), '22023', null, 'a zero amount is refused');
select throws_ok(format($f$select public.submit_payment(%L, %L, 'cash', null, 500, null)$f$, (select p2 from fx), (select bk1 from fx)), '22023', null, 'paying more than the booking costs is refused');
select throws_ok(format($f$select public.submit_payment(%L, %L, 'gcash', 'REF1', 100, %L)$f$, (select p2 from fx), (select bk1 from fx), (select org from fx) || '/' || (select pid from us where role = 'other') || '/proof-b.png'), '42501', null, 'a proof from someone else''s folder is refused');
select throws_ok(format($f$select public.submit_payment(%L, %L, 'gcash', 'REF1', 100, %L)$f$, (select p2 from fx), (select bk1 from fx), (select org from fx) || '/' || (select pid from us where role = 'member') || '/missing.png'), '22023', 'the proof file was not found; upload it again', 'a proof file that was never uploaded is refused');
create temp table s2 as select public.submit_payment((select p2 from fx), (select bk1 from fx), 'gcash', 'REF-1', 400, (select org from fx) || '/' || (select pid from us where role = 'member') || '/proof-a.png') as r;
select throws_ok(format($f$select public.submit_payment(%L, %L, 'gcash', 'REF-9', 100, %L)$f$, (select p6 from fx), (select bk2 from fx), (select org from fx) || '/' || (select pid from us where role = 'member') || '/proof-a.png'), '22023', 'that proof file was already used for another payment; upload a new one', 'a proof file cannot be used twice');
select throws_ok(format($f$select public.submit_payment(%L, %L, 'gcash', 'REF-1', 100, %L)$f$, (select p3 from fx), (select bk2 from fx), (select org from fx) || '/' || (select pid from us where role = 'member') || '/proof-c.png'), '23505', 'that reference number was already used for another payment', 'the same reference number cannot be used twice');
reset role;
grant select on s2 to public;
select is((select r ->> 'status' from s2), 'submitted', 'a GCash payment with its proof is submitted');
select is((select size_bytes from public.files where owner_id = (select p2 from fx)), 1234::bigint, 'the proof file is recorded with its size');
select pg_temp.as_user((select u from us where role = 'other'));
set local role authenticated;
select throws_ok(format($f$select public.submit_payment(%L, %L, 'cash', null, 100, null)$f$, (select p4 from fx), (select bk1 from fx)), '42501', null, 'someone else cannot pay for the booking');
reset role;

-- ---- verify
select pg_temp.as_user((select u from us where role = 'desk'));
set local role authenticated;
select throws_ok(format($f$select public.decide_payment(%L, 'verify', null, %L)$f$, (select p1 from fx), (select k1 from fx)), '42501', null, 'front desk cannot verify payments');
reset role;
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select throws_ok(format($f$select public.decide_payment(%L, 'reject', '', %L)$f$, (select p1 from fx), (select k2 from fx)), '22023', 'a reason is required', 'a rejection needs a reason');
create temp table v1 as select public.decide_payment((select p1 from fx), 'verify', null, (select k3 from fx)) as r;
reset role;
grant select on v1 to public;
select is((select status from public.payment_submissions where id = (select p1 from fx)), 'verified', 'the admin verifies the payment');
select is((select amount from public.ledger_entries where source_type = 'payment' and source_id = (select p1 from fx) and client_ref = 'verify'), 200.0000::numeric, 'and the member is credited');
select is((select status from public.bookings where id = (select bk1 from fx)), 'pending_approval', 'verifying does not approve a booking when the club approves by hand');
set local role authenticated;
select is((select public.decide_payment((select p1 from fx), 'verify', null, (select k3 from fx))), (select r from v1), 'the same key replays');
select is((select (public.decide_payment((select p1 from fx), 'verify', null, (select k4 from fx))) ->> 'unchanged'), 'true', 'verifying twice changes nothing');
reset role;
select is((select count(*)::int from public.ledger_entries where source_type = 'payment' and source_id = (select p1 from fx)), 1, 'and the credit is posted once');

-- reject the GCash one
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select is((select public.decide_payment((select p2 from fx), 'reject', 'the reference does not match', (select k5 from fx)) ->> 'status'), 'rejected', 'a payment can be rejected with a reason');
reset role;
select is((select count(*)::int from public.ledger_entries where source_type = 'payment' and source_id = (select p2 from fx)), 0, 'a rejected payment posts nothing');
select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
select is((select public.submit_payment((select p5 from fx), (select bk1 from fx), 'gcash', 'REF-1', 400, (select org from fx) || '/' || (select pid from us where role = 'member') || '/proof-d.png') ->> 'status'), 'submitted', 'a rejected reference can be sent again');
reset role;

-- ---- payment required: approval waits for the full price
update public.settings set value = 'true'::jsonb where key = 'payments.required.court_booking' and unit_id is null and deleted_at is null;
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select throws_ok(format($f$select public.decide_booking(%L, 'approve', null, %L)$f$, (select bk1 from fx), (select k6 from fx)), '22023', 'the payment has not been verified yet', 'with 200 of 600 paid the booking cannot be approved');
select public.decide_payment((select p5 from fx), 'verify', null, (select k7 from fx));
select is((select public.decide_booking((select bk1 from fx), 'approve', null, (select k8 from fx)) ->> 'status'), 'confirmed', 'once the 600 is verified the booking can be approved');
reset role;
select is((select sum(amount) from public.ledger_entries where account_id = core.ledger_account_for((select org from fx), (select mid from us where role = 'member'))), 0.0000::numeric, 'and the member''s balance for it is 600 charged, 600 paid');

-- ---- void (refund)
select pg_temp.as_user((select u from us where role = 'desk'));
set local role authenticated;
select throws_ok(format($f$select public.void_payment(%L, 'refunded in cash', %L)$f$, (select p1 from fx), core.ulid()), '42501', null, 'front desk cannot void');
reset role;
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select throws_ok(format($f$select public.void_payment(%L, '', %L)$f$, (select p1 from fx), core.ulid()), '22023', 'a reason is required', 'a void needs a reason');
create temp table w1 as select public.void_payment((select p1 from fx), 'refunded in cash', (select k9 from fx)) as r;
reset role;
grant select on w1 to public;
select is((select status from public.payment_submissions where id = (select p1 from fx)), 'void', 'a verified payment can be voided');
select is((select amount from public.ledger_entries where source_type = 'payment' and source_id = (select p1 from fx) and client_ref = 'void'), -200.0000::numeric, 'with the exact opposite ledger entry');
set local role authenticated;
select is((select (public.void_payment((select p1 from fx), 'refunded in cash', (select k10 from fx))) ->> 'unchanged'), 'true', 'voiding twice changes nothing');
reset role;
select is((select count(*)::int from public.ledger_entries where source_type = 'payment' and source_id = (select p1 from fx) and client_ref = 'void'), 1, 'and the refund appears once');

select * from finish();
rollback;
