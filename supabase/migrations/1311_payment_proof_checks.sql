-- 1311_payment_proof_checks (PLAN 5.2): two clearer refusals in submit_payment, checked before anything is written:
-- a reference number that a live payment already uses, and a proof file that an earlier payment already used.
-- Otherwise as 1310.

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

  if v_ref is not null and exists (
    select 1 from public.payment_submissions p
    where p.org_id = v_member.org_id and p.method = p_method and p.reference_no = v_ref and p.status in ('submitted', 'verified')
  ) then
    raise exception 'that reference number was already used for another payment' using errcode = '23505';
  end if;
  if v_proof is not null then
    if split_part(v_proof, '/', 1) <> v_member.org_id or split_part(v_proof, '/', 2) <> core.current_profile_id() then
      raise exception 'the proof must be uploaded to your own folder' using errcode = '42501';
    end if;
    if exists (select 1 from public.files f where f.bucket = 'payment-proofs' and f.storage_path = v_proof and f.deleted_at is null) then
      raise exception 'that proof file was already used for another payment; upload a new one' using errcode = '22023';
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

