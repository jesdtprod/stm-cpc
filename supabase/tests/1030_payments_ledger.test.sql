begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create function pg_temp.mk(p_org text, p_role text, p_person text default null) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := coalesce(p_person, core.ulid()); rid text;
begin
  select id into rid from public.roles where org_id = p_org and code = p_role;
  insert into auth.users (id, email) values (u, p_role || '-' || u || '@example.test');
  if p_person is null then
    insert into public.persons (id, org_id, display_name) values (per, p_org, 'Fake ' || p_role);
  end if;
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, p_org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (p_org, pid, rid);
  return u;
end $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as court1, core.ulid() as per1, core.ulid() as per2, core.ulid() as per3,
  core.ulid() as mem1, core.ulid() as mem2, core.ulid() as mem_pending,
  core.ulid() as bk1, core.ulid() as pay1, core.ulid() as pay2, core.ulid() as acct1, core.ulid() as acct2,
  core.ulid() as le1, core.ulid() as le2, core.ulid() as le3;
grant select on fx to public;

insert into public.persons (id, org_id, display_name) values
  ((select per1 from fx), (select org from fx), 'Fake Payer One'), ((select per2 from fx), (select org from fx), 'Fake Payer Two'),
  ((select per3 from fx), (select org from fx), 'Fake Pending');
insert into public.members (id, org_id, person_id, member_no, status) values
  ((select mem1 from fx), (select org from fx), (select per1 from fx), 'CPC-2026-92001', 'pending_approval'),
  ((select mem2 from fx), (select org from fx), (select per2 from fx), 'CPC-2026-92002', 'pending_approval'),
  ((select mem_pending from fx), (select org from fx), (select per3 from fx), 'CPC-2026-92003', 'pending_approval');
update public.members set status = 'active' where id in ((select mem1 from fx), (select mem2 from fx));
insert into public.courts (id, org_id, code, name) values ((select court1 from fx), (select org from fx), 'court-pay', 'Court Pay');
insert into public.bookings (id, org_id, court_id, requested_by_member_id, during, payload_hash, rate_snapshot, price_snapshot, court_name_snapshot)
  values ((select bk1 from fx), (select org from fx), (select court1 from fx), (select mem1 from fx),
    tstzrange('2026-11-02 09:00+08', '2026-11-02 10:00+08'), repeat('a', 64), 150, 150, 'Court Pay');

-- ---- structure
select is((select count(*)::int from pg_class where relnamespace = 'public'::regnamespace and relrowsecurity
  and relname in ('payment_submissions', 'ledger_accounts', 'ledger_entries')), 3, 'RLS is on for all three tables');
select is((select count(*)::int from pg_class c where c.relnamespace = 'public'::regnamespace
  and c.relname in ('payment_submissions', 'ledger_accounts', 'ledger_entries') and obj_description(c.oid, 'pg_class') like 'class: %'), 3, 'every table has a class comment');

-- ---- payment submissions: insert rules
insert into public.payment_submissions (id, org_id, payer_member_id, source_type, source_id, method, reference_no, amount, payload_hash)
  values ((select pay1 from fx), (select org from fx), (select mem1 from fx), 'booking', (select bk1 from fx), 'gcash', 'REF-0001', 150, repeat('a', 64));
select matches((select doc_no from public.payment_submissions where id = (select pay1 from fx)), '^PAY-20[0-9]{2}-[0-9]{5}$', 'the payment number is assigned by the database');
select is((select status from public.payment_submissions where id = (select pay1 from fx)), 'submitted', 'a payment starts as submitted');
select throws_ok(format($f$insert into public.payment_submissions (org_id, payer_member_id, source_type, source_id, method, reference_no, amount, payload_hash)
  values (%L, %L, 'booking', %L, 'gcash', 'REF-0001', 150, repeat('b', 64))$f$, (select org from fx), (select mem2 from fx), (select bk1 from fx)),
  '23505', null, 'the same method and reference cannot be used on two live payments');
select lives_ok(format($f$insert into public.payment_submissions (org_id, payer_member_id, source_type, source_id, method, reference_no, amount, payload_hash)
  values (%L, %L, 'booking', %L, 'maya', 'REF-0001', 150, repeat('b', 64))$f$, (select org from fx), (select mem2 from fx), (select bk1 from fx)),
  'the same reference on another method is fine');
select lives_ok(format($f$insert into public.payment_submissions (org_id, payer_member_id, source_type, source_id, method, amount, payload_hash)
  values (%L, %L, 'booking', %L, 'cash', 50, repeat('c', 64))$f$, (select org from fx), (select mem1 from fx), (select bk1 from fx)),
  'a cash payment needs no reference');
select throws_ok(format($f$insert into public.payment_submissions (org_id, payer_member_id, source_type, source_id, method, amount, payload_hash)
  values (%L, %L, 'booking', %L, 'cash', 0, repeat('c', 64))$f$, (select org from fx), (select mem1 from fx), (select bk1 from fx)),
  '23514', null, 'an amount must be above zero');
select throws_ok(format($f$insert into public.payment_submissions (org_id, payer_member_id, source_type, source_id, method, amount, payload_hash)
  values (%L, %L, 'booking', %L, 'bitcoin', 10, repeat('c', 64))$f$, (select org from fx), (select mem1 from fx), (select bk1 from fx)),
  '23514', null, 'the method is checked');
select throws_ok(format($f$insert into public.payment_submissions (org_id, payer_member_id, source_type, source_id, method, amount, payload_hash)
  values (%L, %L, 'booking', %L, 'cash', 10, repeat('c', 64))$f$, (select org from fx), (select mem_pending from fx), (select bk1 from fx)),
  '22023', null, 'only an active member can pay');
select throws_ok(format($f$insert into public.payment_submissions (org_id, payer_member_id, source_type, source_id, method, amount, payload_hash)
  values (%L, %L, 'booking', %L, 'cash', 10, repeat('c', 64))$f$, (select org from fx), (select mem1 from fx), core.ulid()),
  '22023', null, 'the booking being paid must exist');
select throws_ok(format($f$insert into public.payment_submissions (org_id, payer_member_id, source_type, source_id, method, amount, payload_hash, status)
  values (%L, %L, 'booking', %L, 'cash', 10, repeat('c', 64), 'verified')$f$, (select org from fx), (select mem1 from fx), (select bk1 from fx)),
  '22023', null, 'a new payment cannot start verified');
select throws_ok(format($f$insert into public.payment_submissions (org_id, payer_member_id, source_type, source_id, method, amount, payload_hash)
  values (%L, %L, 'booking', %L, 'cash', 10, 'nope')$f$, (select org from fx), (select mem1 from fx), (select bk1 from fx)),
  '23514', null, 'the payload hash must be a sha-256 hex string');

-- ---- state machine
select throws_ok(format($f$update public.payment_submissions set status = 'verified' where id = %L$f$, (select pay1 from fx)), '23514', null, 'verified needs who and when');
select throws_ok(format($f$update public.payment_submissions set status = 'rejected' where id = %L$f$, (select pay1 from fx)), '23514', null, 'rejected needs a reason');
select throws_ok(format($f$update public.payment_submissions set status = 'void', void_at = now(), void_reason = 'x' where id = %L$f$, (select pay1 from fx)), '22023', null, 'submitted cannot be voided; it is rejected');
select throws_ok(format($f$update public.payment_submissions set amount = 1 where id = %L$f$, (select pay1 from fx)), '42501', null, 'the amount cannot be changed');
select throws_ok(format($f$update public.payment_submissions set reference_no = 'EDITED' where id = %L$f$, (select pay1 from fx)), '42501', null, 'the reference cannot be changed');
select lives_ok(format($f$update public.payment_submissions set status = 'verified', verified_at = now(), verified_by = 'system' where id = %L$f$, (select pay1 from fx)), 'submitted -> verified');
select throws_ok(format($f$update public.payment_submissions set status = 'rejected', reject_reason = 'x' where id = %L$f$, (select pay1 from fx)), '22023', null, 'verified cannot be rejected');
select lives_ok(format($f$update public.payment_submissions set status = 'void', void_at = now(), void_by = 'system', void_reason = 'wrong booking' where id = %L$f$, (select pay1 from fx)), 'verified -> void');
select throws_ok(format($f$update public.payment_submissions set status = 'verified', verified_at = now(), verified_by = 'system' where id = %L$f$, (select pay1 from fx)), '22023', null, 'void is final');
select lives_ok(format($f$insert into public.payment_submissions (org_id, payer_member_id, source_type, source_id, method, reference_no, amount, payload_hash)
  values (%L, %L, 'booking', %L, 'gcash', 'REF-0001', 150, repeat('d', 64))$f$, (select org from fx), (select mem1 from fx), (select bk1 from fx)),
  'a void payment frees its reference for a corrected submission');
select throws_ok(format($f$delete from public.payment_submissions where id = %L$f$, (select pay1 from fx)), '42501', null, 'a payment cannot be hard-deleted');

-- ---- totals derived from payments
insert into public.payment_submissions (id, org_id, payer_member_id, source_type, source_id, method, reference_no, amount, payload_hash)
  values ((select pay2 from fx), (select org from fx), (select mem2 from fx), 'booking', (select bk1 from fx), 'bank_transfer', 'BT-77', 70, repeat('e', 64));
update public.payment_submissions set status = 'verified', verified_at = now(), verified_by = 'system' where id = (select pay2 from fx);
select is((select verified_total from public.source_payment_totals where source_id = (select bk1 from fx)), 70.00::numeric, 'verified total counts only verified payments');
select is((select pending_total from public.source_payment_totals where source_id = (select bk1 from fx)), 350.00::numeric, 'pending total counts the submitted ones (150 maya + 50 cash + 150 gcash)');

-- ---- ledger accounts and entries
insert into public.ledger_accounts (id, org_id, owner_id) values ((select acct1 from fx), (select org from fx), (select mem1 from fx));
insert into public.ledger_accounts (id, org_id, owner_id) values ((select acct2 from fx), (select org from fx), (select mem2 from fx));
select throws_ok(format($f$insert into public.ledger_accounts (org_id, owner_id) values (%L, %L)$f$, (select org from fx), (select mem1 from fx)), '23505', null, 'a member has one active account');
select throws_ok(format($f$insert into public.ledger_accounts (org_id, owner_id) values (%L, %L)$f$, (select org from fx), core.ulid()), '22023', null, 'the owner must be a member');
select throws_ok(format($f$insert into public.ledger_accounts (org_id, owner_id, currency) values (%L, %L, 'USD')$f$, (select org from fx), (select mem_pending from fx)), '23514', null, 'the currency is PHP');

insert into public.ledger_entries (id, org_id, account_id, amount, source_type, source_id, client_ref)
  values ((select le1 from fx), (select org from fx), (select acct1 from fx), -150.0000, 'booking', (select bk1 from fx), 'charge');
insert into public.ledger_entries (id, org_id, account_id, amount, source_type, source_id, client_ref)
  values ((select le2 from fx), (select org from fx), (select acct1 from fx), 150.0000, 'payment', (select pay1 from fx), 'credit');
select is((select balance from public.ledger_balances where account_id = (select acct1 from fx)), 0.0000::numeric, 'a charge and the matching payment net to zero');
select throws_ok(format($f$insert into public.ledger_entries (org_id, account_id, amount, source_type, source_id, client_ref) values (%L, %L, -150, 'booking', %L, 'charge')$f$,
  (select org from fx), (select acct1 from fx), (select bk1 from fx)), '23505', null, 'retrying the same business event records it once');
select throws_ok(format($f$insert into public.ledger_entries (org_id, account_id, amount, source_type, source_id, client_ref) values (%L, %L, 0, 'adjustment', %L, 'zero')$f$,
  (select org from fx), (select acct1 from fx), core.ulid()), '23514', null, 'an entry cannot be zero');
select throws_ok(format($f$insert into public.ledger_entries (org_id, account_id, amount, source_type, source_id, client_ref) values (%L, %L, 5, 'adjustment', %L, 'x')$f$,
  (select org from fx), core.ulid(), core.ulid()), '22023', null, 'the account must exist');
select throws_ok(format($f$insert into public.ledger_entries (org_id, account_id, amount, source_type, source_id, client_ref) values (%L, %L, 5, 'gift', %L, 'x')$f$,
  (select org from fx), (select acct1 from fx), core.ulid()), '23514', null, 'the source type is checked');
select throws_ok($$update public.ledger_entries set amount = 1$$, '42501', null, 'ledger entries cannot be edited');
select throws_ok($$delete from public.ledger_entries$$, '42501', null, 'ledger entries cannot be deleted');
select throws_ok($$truncate public.ledger_entries$$, '42501', null, 'the ledger cannot be truncated');

-- reversals
select throws_ok(format($f$insert into public.ledger_entries (org_id, account_id, amount, source_type, source_id, client_ref, reverses_entry_id) values (%L, %L, 100, 'adjustment', %L, 'rev', %L)$f$,
  (select org from fx), (select acct1 from fx), core.ulid(), (select le2 from fx)), '22023', null, 'a reversal must be the exact opposite amount');
select throws_ok(format($f$insert into public.ledger_entries (org_id, account_id, amount, source_type, source_id, client_ref, reverses_entry_id) values (%L, %L, -150, 'adjustment', %L, 'rev', %L)$f$,
  (select org from fx), (select acct2 from fx), core.ulid(), (select le2 from fx)), '22023', null, 'a reversal must be in the same account');
select lives_ok(format($f$insert into public.ledger_entries (id, org_id, account_id, amount, source_type, source_id, client_ref, reverses_entry_id, note) values (%L, %L, %L, -150, 'payment', %L, 'void', %L, 'payment voided')$f$,
  (select le3 from fx), (select org from fx), (select acct1 from fx), (select pay1 from fx), (select le2 from fx)), 'an exact reversal is accepted');
select is((select balance from public.ledger_balances where account_id = (select acct1 from fx)), -150.0000::numeric, 'and the balance moves back');
select throws_ok(format($f$insert into public.ledger_entries (org_id, account_id, amount, source_type, source_id, client_ref, reverses_entry_id) values (%L, %L, -150, 'adjustment', %L, 'again', %L)$f$,
  (select org from fx), (select acct1 from fx), core.ulid(), (select le2 from fx)), '23505', null, 'an entry can be reversed only once');
select throws_ok(format($f$insert into public.ledger_entries (org_id, account_id, amount, source_type, source_id, client_ref, reverses_entry_id) values (%L, %L, 150, 'adjustment', %L, 'back', %L)$f$,
  (select org from fx), (select acct1 from fx), core.ulid(), (select le3 from fx)), '22023', null, 'a reversal cannot be reversed');

-- ---- row-level security
create temp table us(role text primary key, u uuid);
grant select on us to public;
insert into us values ('admin', pg_temp.mk((select org from fx), 'admin'));
insert into us values ('manager', pg_temp.mk((select org from fx), 'manager'));
insert into us values ('front_desk', pg_temp.mk((select org from fx), 'front_desk'));
insert into us values ('m1', pg_temp.mk((select org from fx), 'member', (select per1 from fx)));
insert into us values ('m2', pg_temp.mk((select org from fx), 'member', (select per2 from fx)));
update public.members set profile_id = (select p.id from public.profiles p where p.auth_user_id = (select u from us where role = 'm1')) where id = (select mem1 from fx);
update public.members set profile_id = (select p.id from public.profiles p where p.auth_user_id = (select u from us where role = 'm2')) where id = (select mem2 from fx);

select pg_temp.as_user((select u from us where role = 'm1'));
set local role authenticated;
select is((select count(*)::int from public.payment_submissions where payer_member_id <> (select mem1 from fx)), 0, 'a member sees no one else''s payments');
select cmp_ok((select count(*)::int from public.payment_submissions), '>=', 3, 'but sees their own');
select is((select count(*)::int from public.ledger_accounts), 1, 'a member sees only their own ledger account');
select is((select count(*)::int from public.ledger_entries), 3, 'and its entries');
select is((select balance from public.ledger_balances), -150.0000::numeric, 'and the balance from them');
select is((select count(*)::int from public.source_payment_totals), 1, 'a member sees totals for the booking, built only from their own payments');
select is((select verified_total from public.source_payment_totals), 0.00::numeric, 'which cannot include the other member''s verified payment');
select throws_ok(format($f$insert into public.ledger_entries (org_id, account_id, amount, source_type, source_id, client_ref) values (%L, %L, 1000, 'adjustment', %L, 'free money')$f$,
  (select org from fx), (select acct1 from fx), core.ulid()), '42501', null, 'a member cannot credit their own account');
select throws_ok($$update public.payment_submissions set status = 'verified'$$, '42501', null, 'a member cannot verify their own payment');
select throws_ok(format($f$insert into public.payment_submissions (org_id, payer_member_id, source_type, source_id, method, amount, payload_hash) values (%L, %L, 'booking', %L, 'cash', 1, repeat('f', 64))$f$,
  (select org from fx), (select mem1 from fx), (select bk1 from fx)), '42501', null, 'a member cannot insert a payment directly');
reset role;

select pg_temp.as_user((select u from us where role = 'm2'));
set local role authenticated;
select is((select count(*)::int from public.ledger_entries), 0, 'another member has no entries in their account yet');
select is((select count(*)::int from public.ledger_accounts), 1, 'and sees only their own account');
reset role;

select pg_temp.as_user((select u from us where role = 'front_desk'));
set local role authenticated;
select is((select count(*)::int from public.ledger_entries), 0, 'front desk without payments.verify sees no ledger entries');
select is((select count(*)::int from public.payment_submissions), 0, 'and no payments');
reset role;

select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select cmp_ok((select count(*)::int from public.payment_submissions), '>=', 4, 'an admin (payments.verify) sees all payments');
select is((select count(*)::int from public.ledger_entries), 3, 'and all ledger entries');
select throws_ok($$update public.payment_submissions set status = 'verified'$$, '42501', null, 'but writes only through RPCs');
reset role;

select is(has_any_column_privilege('authenticated', 'public.ledger_entries', 'insert') or has_any_column_privilege('authenticated', 'public.ledger_entries', 'update'), false, 'clients have no write privilege on the ledger');
select is(has_any_column_privilege('authenticated', 'public.payment_submissions', 'insert') or has_any_column_privilege('authenticated', 'public.payment_submissions', 'update'), false, 'or on payments');
select is(has_table_privilege('anon', 'public.ledger_balances', 'select'), false, 'anon cannot read the balance view');

select * from finish();
rollback;
