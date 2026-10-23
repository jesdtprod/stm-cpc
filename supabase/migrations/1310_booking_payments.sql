-- 1310_booking_payments (PLAN 5.2): payment proof for a booking, verified by an admin.
--   submit_payment(id, booking, method, reference, amount, proof path)   the member who requested the booking
--   decide_payment(payment, action, reason, key)                         verify / reject (payments.verify)
--   void_payment(payment, reason, key)                                   undo a verified payment, i.e. a refund (payments.void)
-- Rules: only the booking's requester can pay for it, while it is pending or confirmed; the method must be one the club
-- accepts (setting payments.methods); a non-cash payment needs its proof when the setting payments.proof_required_non_cash
-- is on; the proof is a file already uploaded to the private bucket under the member's own folder; the live payments for a
-- booking never add up to more than its price; the same method and reference number cannot be used twice.
-- An unverified payment never confirms a booking. Verifying posts a credit in the ledger and, when the club does not
-- approve bookings by hand and the payment now covers the price, confirms the booking. Voiding posts the exact opposite
-- entry. The payment ID is chosen by the browser: the same request again returns the same payment (CP422 if it differs).

create or replace function core.submit_payment(p_id text, p_booking_id text, p_method text, p_reference_no text,
  p_amount numeric, p_proof_path text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_member public.members;
  v_booking public.bookings;
  v_ref text := nullif(btrim(coalesce(p_reference_no, '')), '');
  v_proof text := nullif(btrim(coalesce(p_proof_path, '')), '');
  v_hash text;
  v_existing public.payment_submissions;
  v_methods jsonb;
  v_live numeric;
  v_file_id text;
  v_object record;
  v_payment public.payment_submissions;
begin
  select * into v_member from public.members m where m.profile_id = core.current_profile_id() and m.deleted_at is null;
  if not found or v_member.status <> 'active' then
    raise exception 'only an active member can submit a payment' using errcode = '42501';
  end if;
  if not core.has_permission(v_member.org_id, null, 'payments.submit') then
    raise exception 'you do not have permission to submit a payment' using errcode = '42501';
  end if;
  if p_id is null or not core.is_ulid(p_id) then
    raise exception 'the payment needs an ID made when the form opened' using errcode = '22023';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) or p_amount > 1000000 then
    raise exception 'enter an amount above zero with at most two decimals' using errcode = '22023';
  end if;
  if v_ref is not null and char_length(v_ref) > 64 then
    raise exception 'the reference number is too long' using errcode = '22023';
  end if;

  v_hash := encode(extensions.digest(convert_to(jsonb_build_object('booking', p_booking_id, 'method', p_method, 'ref', v_ref,
    'amount', p_amount, 'proof', v_proof, 'member', v_member.id)::text, 'utf8'), 'sha256'), 'hex');
  select * into v_existing from public.payment_submissions p where p.id = p_id;
  if found then
    if v_existing.payload_hash = v_hash and v_existing.payer_member_id = v_member.id then
      return jsonb_build_object('id', v_existing.id, 'doc_no', v_existing.doc_no, 'status', v_existing.status, 'replayed', true);
    end if;
    raise exception 'this payment ID was already used for a different request' using errcode = 'CP422';
  end if;

  select * into v_booking from public.bookings b where b.id = p_booking_id for update;
  if not found or v_booking.requested_by_member_id <> v_member.id then
    raise exception 'you can only pay for your own booking' using errcode = '42501';
  end if;
  if v_booking.status not in ('pending_approval', 'confirmed') then
    raise exception 'a booking that is % cannot be paid', replace(v_booking.status, '_', ' ') using errcode = '22023';
  end if;
  v_methods := coalesce(core.setting_value(v_member.org_id, 'payments.methods'), '["cash"]'::jsonb);
  if p_method is null or not (v_methods ? p_method) then
    raise exception 'the club does not accept that payment method' using errcode = '22023';
  end if;
  if p_method <> 'cash' and v_proof is null and core.setting_bool(v_member.org_id, 'payments.proof_required_non_cash', true) then
    raise exception 'attach the proof of payment' using errcode = '22023';
  end if;
  select coalesce(sum(p.amount), 0) into v_live from public.payment_submissions p
  where p.source_type = 'booking' and p.source_id = p_booking_id and p.status in ('submitted', 'verified');
  if v_live + p_amount > v_booking.price_snapshot then
    raise exception 'that is more than the booking costs (%.2f still to pay)', greatest(v_booking.price_snapshot - v_live, 0) using errcode = '22023';
  end if;

  if v_proof is not null then
    if split_part(v_proof, '/', 1) <> v_member.org_id or split_part(v_proof, '/', 2) <> core.current_profile_id() then
      raise exception 'the proof must be uploaded to your own folder' using errcode = '42501';
    end if;
    select o.name, o.metadata into v_object from storage.objects o where o.bucket_id = 'payment-proofs' and o.name = v_proof;
    if not found then
      raise exception 'the proof file was not found; upload it again' using errcode = '22023';
    end if;
    insert into public.files (org_id, owner_table, owner_id, kind, bucket, storage_path, content_type, size_bytes)
    values (v_member.org_id, 'payment_submissions', p_id, 'payment_proof', 'payment-proofs', v_proof,
      v_object.metadata ->> 'mimetype', coalesce((v_object.metadata ->> 'size')::bigint, 0))
    returning id into v_file_id;
  end if;

  begin
    insert into public.payment_submissions (id, org_id, payer_member_id, source_type, source_id, method, reference_no, amount, file_id, payload_hash)
    values (p_id, v_member.org_id, v_member.id, 'booking', p_booking_id, p_method, v_ref, p_amount, v_file_id, v_hash)
    returning * into v_payment;
  exception when unique_violation then
    raise exception 'that reference number was already used for another payment' using errcode = '23505';
  end;
  perform core.write_audit(v_member.org_id, 'payment.submit', 'public.payment_submissions', p_id, null,
    jsonb_build_object('booking', v_booking.doc_no, 'method', p_method, 'amount', p_amount));
  return jsonb_build_object('id', v_payment.id, 'doc_no', v_payment.doc_no, 'status', v_payment.status);
end $$;

create or replace function core.decide_payment(p_payment_id text, p_action text, p_reason text, p_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_pay public.payment_submissions;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_replay jsonb;
  v_response jsonb;
  v_target text;
begin
  if p_action not in ('verify', 'reject') then
    raise exception 'unknown action' using errcode = '22023';
  end if;
  select * into v_pay from public.payment_submissions p where p.id = p_payment_id for update;
  if not found then
    raise exception 'payment not found' using errcode = '22023';
  end if;
  if not core.has_permission(v_pay.org_id, null, 'payments.verify') then
    raise exception 'you do not have permission to % payments', p_action using errcode = '42501';
  end if;
  if p_action = 'reject' and (v_reason is null or char_length(v_reason) < 3) then
    raise exception 'a reason is required' using errcode = '22023';
  end if;
  if v_reason is not null and char_length(v_reason) > 500 then
    raise exception 'the reason is too long' using errcode = '22023';
  end if;

  v_replay := core.idem_begin(p_key, v_pay.org_id, 'payment.' || p_action, jsonb_build_object('payment_id', p_payment_id, 'reason', v_reason));
  if v_replay is not null then
    return v_replay;
  end if;
  v_target := case p_action when 'verify' then 'verified' else 'rejected' end;
  if v_pay.status = v_target then
    v_response := jsonb_build_object('ok', true, 'payment_id', v_pay.id, 'status', v_pay.status, 'unchanged', true);
    perform core.idem_complete(p_key, v_response);
    return v_response;
  end if;
  if v_pay.status <> 'submitted' then
    raise exception 'a payment that is % cannot be %', v_pay.status, v_target using errcode = '22023';
  end if;

  if p_action = 'verify' then
    update public.payment_submissions set status = 'verified', verified_at = now(), verified_by = coalesce(core.current_profile_id(), 'system')
    where id = v_pay.id;
    perform core.post_ledger(v_pay.org_id, v_pay.payer_member_id, v_pay.amount, 'payment', v_pay.id, 'verify', 'Payment ' || v_pay.doc_no);
    if v_pay.source_type = 'booking' then
      perform core.try_confirm_booking(v_pay.source_id);
    end if;
  else
    update public.payment_submissions set status = 'rejected', reject_reason = v_reason where id = v_pay.id;
  end if;
  perform core.write_audit(v_pay.org_id, 'payment.' || p_action, 'public.payment_submissions', v_pay.id,
    jsonb_build_object('status', v_pay.status), jsonb_build_object('status', v_target, 'reason', v_reason, 'amount', v_pay.amount));
  v_response := jsonb_build_object('ok', true, 'payment_id', v_pay.id, 'status', v_target);
  perform core.idem_complete(p_key, v_response);
  return v_response;
end $$;

create or replace function core.void_payment(p_payment_id text, p_reason text, p_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_pay public.payment_submissions;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_credit text;
  v_replay jsonb;
  v_response jsonb;
begin
  select * into v_pay from public.payment_submissions p where p.id = p_payment_id for update;
  if not found then
    raise exception 'payment not found' using errcode = '22023';
  end if;
  if not core.has_permission(v_pay.org_id, null, 'payments.void') then
    raise exception 'you do not have permission to void payments' using errcode = '42501';
  end if;
  if v_reason is null or char_length(v_reason) < 3 then
    raise exception 'a reason is required' using errcode = '22023';
  end if;
  if char_length(v_reason) > 500 then
    raise exception 'the reason is too long' using errcode = '22023';
  end if;

  v_replay := core.idem_begin(p_key, v_pay.org_id, 'payment.void', jsonb_build_object('payment_id', p_payment_id, 'reason', v_reason));
  if v_replay is not null then
    return v_replay;
  end if;
  if v_pay.status = 'void' then
    v_response := jsonb_build_object('ok', true, 'payment_id', v_pay.id, 'status', 'void', 'unchanged', true);
    perform core.idem_complete(p_key, v_response);
    return v_response;
  end if;
  if v_pay.status <> 'verified' then
    raise exception 'only a verified payment can be voided (this one is %)', v_pay.status using errcode = '22023';
  end if;

  update public.payment_submissions set status = 'void', void_at = now(), void_by = coalesce(core.current_profile_id(), 'system'), void_reason = v_reason
  where id = v_pay.id;
  select e.id into v_credit from public.ledger_entries e
  where e.org_id = v_pay.org_id and e.source_type = 'payment' and e.source_id = v_pay.id and e.client_ref = 'verify';
  if v_credit is not null then
    perform core.post_ledger(v_pay.org_id, v_pay.payer_member_id, -v_pay.amount, 'payment', v_pay.id, 'void', 'Voided ' || v_pay.doc_no, v_credit);
  end if;
  perform core.write_audit(v_pay.org_id, 'payment.void', 'public.payment_submissions', v_pay.id,
    jsonb_build_object('status', 'verified'), jsonb_build_object('status', 'void', 'reason', v_reason, 'amount', v_pay.amount));
  v_response := jsonb_build_object('ok', true, 'payment_id', v_pay.id, 'status', 'void');
  perform core.idem_complete(p_key, v_response);
  return v_response;
end $$;

create or replace function public.submit_payment(p_id text, p_booking_id text, p_method text, p_reference_no text,
  p_amount numeric, p_proof_path text default null) returns jsonb
language sql security invoker set search_path = '' as $$ select core.submit_payment(p_id, p_booking_id, p_method, p_reference_no, p_amount, p_proof_path) $$;
create or replace function public.decide_payment(p_payment_id text, p_action text, p_reason text, p_key text) returns jsonb
language sql security invoker set search_path = '' as $$ select core.decide_payment(p_payment_id, p_action, p_reason, p_key) $$;
create or replace function public.void_payment(p_payment_id text, p_reason text, p_key text) returns jsonb
language sql security invoker set search_path = '' as $$ select core.void_payment(p_payment_id, p_reason, p_key) $$;

revoke all on function core.submit_payment(text, text, text, text, numeric, text), core.decide_payment(text, text, text, text),
  core.void_payment(text, text, text), public.submit_payment(text, text, text, text, numeric, text),
  public.decide_payment(text, text, text, text), public.void_payment(text, text, text) from public, anon, authenticated;
-- Each function checks who the caller is and what they may do.
grant execute on function core.submit_payment(text, text, text, text, numeric, text), core.decide_payment(text, text, text, text),
  core.void_payment(text, text, text), public.submit_payment(text, text, text, text, numeric, text),
  public.decide_payment(text, text, text, text), public.void_payment(text, text, text) to authenticated, service_role;
