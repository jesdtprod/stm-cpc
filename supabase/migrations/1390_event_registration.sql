-- 1390_event_registration (PLAN 6.2): registering for an event division, who may, what it costs, and approval.
--   * registration_problem: the eligibility rules, checked on the server (FEATURES 6, 9.1): active member, registration
--     window, open division, the division's category and rank band (from the member's current rank), gender and age group.
--   * register_for_event: a member registers themself; staff may register a member and, with a written reason, allow a
--     member outside the category, rank band, gender or age rule (open decision "playing in another category").
--     Doubles take a partner, who must be eligible too. A full division waitlists (when enabled) or refuses.
--   * decide_registration: approve or reject (events.approve_registration). Approving waits for the verified fee when the
--     club requires payment. With approval switched off, a registration confirms as soon as any required payment is verified.
--   * Confirming posts the fee to the member's ledger once and creates the division entry (and its members).
--   * submit_event_payment: the registrant sends a payment for a registration; verifying it (decide_payment, unchanged)
--     triggers the confirmation check through the trigger below.
--   * my_event_options: events open for registration with each division's spots, and what the caller may do.
--   Age groups are read as "N+" or "A-B" (age on the first day of the event); any other label is not enforced.
--   Withdrawals, waitlist promotion and refunds are step 6.3.

-- ---------------------------------------------------------------------------
-- eligibility
-- ---------------------------------------------------------------------------
-- Returns null when the member may register, otherwise a sentence saying why not. p_soft = false skips the
-- category, rank, gender and age rules (a staff override); the member, event window and division state always apply.
create or replace function core.registration_problem(p_member_id text, p_division_id text, p_soft boolean default true)
returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  m public.members;
  per public.persons;
  dv public.divisions;
  ev public.events;
  v_rank record;
  v_lo integer;
  v_hi integer;
  v_age integer;
  v_group text;
  v_a integer;
  v_b integer;
begin
  select * into m from public.members x where x.id = p_member_id and x.deleted_at is null;
  if not found or m.status <> 'active' then
    return 'Only an active member can register.';
  end if;
  select * into dv from public.divisions x where x.id = p_division_id;
  if not found or dv.org_id <> m.org_id then
    return 'That division does not exist.';
  end if;
  select * into ev from public.events x where x.id = dv.event_id;
  if ev.status <> 'registration_open' then
    return 'Registration for this event is not open.';
  end if;
  if (ev.registration_opens_at is not null and now() < ev.registration_opens_at)
     or (ev.registration_closes_at is not null and now() >= ev.registration_closes_at) then
    return 'Registration for this event is outside its registration window.';
  end if;
  if dv.status <> 'open' then
    return 'This division is not open for registration.';
  end if;
  if not p_soft then
    return null;
  end if;

  select r.id, r.sort_order, l.category_id into v_rank
  from public.member_ranks mr
  join public.ranks r on r.id = mr.rank_id
  join public.rank_ladders l on l.id = r.ladder_id
  where mr.member_id = m.id and mr.deleted_at is null;
  if not found then
    return 'You have no rank yet, so you cannot join a ranked division.';
  end if;
  if v_rank.category_id <> dv.category_id then
    return 'This division is for a different category than your current rank.';
  end if;
  if dv.min_rank_id is not null then
    select sort_order into v_lo from public.ranks where id = dv.min_rank_id;
    if v_rank.sort_order < v_lo then return 'Your rank is below this division''s lowest allowed rank.'; end if;
  end if;
  if dv.max_rank_id is not null then
    select sort_order into v_hi from public.ranks where id = dv.max_rank_id;
    if v_rank.sort_order > v_hi then return 'Your rank is above this division''s highest allowed rank.'; end if;
  end if;

  select * into per from public.persons p where p.id = m.person_id;
  if dv.gender in ('male', 'female') then
    if per.gender is null then
      return 'Add your gender to your profile to join this division.';
    elsif per.gender <> dv.gender then
      return case dv.gender when 'male' then 'This division is for men.' else 'This division is for women.' end;
    end if;
  end if;

  v_group := btrim(coalesce(dv.age_group, ''));
  if v_group ~ '^\d{1,2}\+$' or v_group ~ '^\d{1,2}\s*-\s*\d{1,2}$' then
    if per.date_of_birth is null then
      return 'Your birth date is needed to check this division''s age group.';
    end if;
    v_age := extract(year from age(ev.starts_on, per.date_of_birth))::integer;
    if v_group ~ '\+$' then
      v_a := substring(v_group from '^\d+')::integer;
      if v_age < v_a then return format('This division is for ages %s and over.', v_a); end if;
    else
      v_a := substring(v_group from '^\d+')::integer;
      v_b := substring(v_group from '(\d+)$')::integer;
      if v_age < v_a or v_age > v_b then return format('This division is for ages %s to %s.', v_a, v_b); end if;
    end if;
  end if;
  return null;
end $$;
revoke all on function core.registration_problem(text, text, boolean) from public, anon, authenticated;
grant execute on function core.registration_problem(text, text, boolean) to service_role;

-- Verified payments for a registration.
create or replace function core.registration_paid(p_registration text) returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce(sum(p.amount), 0) from public.payment_submissions p
  where p.source_type = 'event_registration' and p.source_id = p_registration and p.status = 'verified'
$$;
revoke all on function core.registration_paid(text) from public, anon, authenticated;
grant execute on function core.registration_paid(text) to service_role;

-- True when the club needs a verified payment before this registration can confirm.
create or replace function core.registration_payment_pending(p_registration text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  r public.registrations;
begin
  select * into r from public.registrations where id = p_registration;
  return core.setting_bool(r.org_id, 'payments.required.event_registration', false) and r.fee_snapshot > 0
    and core.registration_paid(r.id) < r.fee_snapshot;
end $$;
revoke all on function core.registration_payment_pending(text) from public, anon, authenticated;
grant execute on function core.registration_payment_pending(text) to service_role;

-- ---------------------------------------------------------------------------
-- confirming: ledger charge once, plus the division entry
-- ---------------------------------------------------------------------------
create or replace function core.confirm_registration_row(p_registration_id text, p_actor text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  r public.registrations;
  v_entry text;
  v_partner text;
begin
  select * into r from public.registrations where id = p_registration_id for update;
  if r.status not in ('requested', 'waitlisted') then
    return;
  end if;
  update public.registrations set status = 'confirmed', status_reason = null where id = r.id;
  if r.fee_snapshot > 0 then
    perform core.post_ledger(r.org_id, r.member_id, -r.fee_snapshot, 'event_registration', r.id, 'charge',
      'Event registration fee');
  end if;
  insert into public.entries (org_id, division_id, registration_id) values (r.org_id, r.division_id, r.id)
  returning id into v_entry;
  insert into public.entry_members (org_id, entry_id, member_id) values (r.org_id, v_entry, r.member_id);
  v_partner := r.meta ->> 'partner_member_id';
  if v_partner is not null then
    insert into public.entry_members (org_id, entry_id, member_id) values (r.org_id, v_entry, v_partner);
  end if;
end $$;
revoke all on function core.confirm_registration_row(text, text) from public, anon, authenticated;
grant execute on function core.confirm_registration_row(text, text) to service_role;

-- Confirms a requested registration when the club does not approve by hand and any required payment is verified.
create or replace function core.try_confirm_registration(p_registration_id text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  r public.registrations;
begin
  select * into r from public.registrations where id = p_registration_id;
  if r.status <> 'requested' or core.setting_bool(r.org_id, 'events.registration_approval_required', true) then
    return;
  end if;
  if core.registration_payment_pending(r.id) then
    return;
  end if;
  perform core.confirm_registration_row(r.id, 'system');
end $$;
revoke all on function core.try_confirm_registration(text) from public, anon, authenticated;
grant execute on function core.try_confirm_registration(text) to service_role;

-- A verified payment may be the last thing a registration was waiting for.
create or replace function core.tg_registration_payment_verified() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.source_type = 'event_registration' and new.status = 'verified' and old.status is distinct from 'verified' then
    perform core.try_confirm_registration(new.source_id);
  end if;
  return null;
end $$;
revoke all on function core.tg_registration_payment_verified() from public, anon, authenticated;
create trigger z_payments_confirm_registration after update on public.payment_submissions
  for each row execute function core.tg_registration_payment_verified();

-- ---------------------------------------------------------------------------
-- registering
-- ---------------------------------------------------------------------------
create or replace function core.register_for_event(p_id text, p_division_id text, p_partner_member_id text default null,
  p_member_id text default null, p_override_reason text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_self public.members;
  v_member public.members;
  v_org text;
  dv public.divisions;
  ev public.events;
  v_staff boolean := p_member_id is not null;
  v_override text := nullif(btrim(coalesce(p_override_reason, '')), '');
  v_partner text := nullif(btrim(coalesce(p_partner_member_id, '')), '');
  v_problem text;
  v_hash text;
  v_existing public.registrations;
  v_taken integer;
  v_reg public.registrations;
  v_status text;
begin
  select * into v_self from public.members m where m.profile_id = core.current_profile_id() and m.deleted_at is null;
  if v_staff then
    select * into dv from public.divisions x where x.id = p_division_id;
    if not found then
      raise exception 'division not found' using errcode = '22023';
    end if;
    if not core.has_permission(dv.org_id, null, 'registrations.manage') then
      raise exception 'you do not have permission to register members' using errcode = '42501';
    end if;
    select * into v_member from public.members m where m.id = p_member_id and m.org_id = dv.org_id and m.deleted_at is null;
    if not found then
      raise exception 'member not found' using errcode = '22023';
    end if;
  else
    if v_self.id is null or v_self.status <> 'active' then
      raise exception 'only an active member can register for an event' using errcode = '42501';
    end if;
    if not core.has_permission(v_self.org_id, null, 'events.register') then
      raise exception 'you do not have permission to register for events' using errcode = '42501';
    end if;
    v_member := v_self;
    if v_override is not null then
      raise exception 'only staff can allow an exception' using errcode = '42501';
    end if;
  end if;
  v_org := v_member.org_id;
  if p_id is null or not core.is_ulid(p_id) then
    raise exception 'the registration needs an ID made when the form opened' using errcode = '22023';
  end if;
  if v_override is not null and (char_length(v_override) < 3 or char_length(v_override) > 500) then
    raise exception 'the reason for the exception must be 3 to 500 characters' using errcode = '22023';
  end if;

  v_hash := core.hash_of(jsonb_build_object('division', p_division_id, 'member', v_member.id, 'partner', v_partner,
    'override', v_override));
  select * into v_existing from public.registrations r where r.id = p_id;
  if found then
    if v_existing.payload_hash = v_hash then
      return jsonb_build_object('id', v_existing.id, 'status', v_existing.status, 'fee', v_existing.fee_snapshot, 'replayed', true);
    end if;
    raise exception 'this registration ID was already used for a different request' using errcode = 'CP422';
  end if;

  select * into dv from public.divisions x where x.id = p_division_id for update;
  if not found or dv.org_id <> v_org then
    raise exception 'division not found' using errcode = '22023';
  end if;
  select * into ev from public.events x where x.id = dv.event_id;

  v_problem := core.registration_problem(v_member.id, dv.id, v_override is null);
  if v_problem is not null then
    raise exception '%', v_problem using errcode = '22023';
  end if;

  if dv.format = 'doubles' then
    if v_partner is null then
      raise exception 'choose your doubles partner' using errcode = '22023';
    end if;
    if v_partner = v_member.id then
      raise exception 'your partner must be another member' using errcode = '22023';
    end if;
    v_problem := core.registration_problem(v_partner, dv.id, v_override is null);
    if v_problem is not null then
      raise exception 'your partner cannot join: %', v_problem using errcode = '22023';
    end if;
  elsif v_partner is not null then
    raise exception 'singles take no partner' using errcode = '22023';
  end if;

  -- A member is in a division once, as a registrant or as a partner.
  if exists (
    select 1 from public.registrations r
    where r.division_id = dv.id and r.status in ('requested', 'confirmed', 'waitlisted')
      and (r.member_id in (v_member.id, v_partner) or (r.meta ->> 'partner_member_id') in (v_member.id, v_partner))
  ) then
    raise exception 'you or your partner are already registered in this division' using errcode = '23505';
  end if;

  select count(*)::integer into v_taken from public.registrations r
  where r.division_id = dv.id and r.status in ('requested', 'confirmed');
  v_status := 'requested';
  if dv.max_entries is not null and v_taken >= dv.max_entries then
    if not core.setting_bool(v_org, 'events.waitlist_enabled', true) then
      raise exception 'this division is full' using errcode = '22023';
    end if;
    v_status := 'waitlisted';
  end if;

  insert into public.registrations (id, org_id, event_id, division_id, member_id, fee_snapshot, payload_hash, meta)
  values (p_id, v_org, ev.id, dv.id, v_member.id, ev.fee, v_hash,
    case when v_partner is null then '{}'::jsonb else jsonb_build_object('partner_member_id', v_partner) end
      || case when v_override is null then '{}'::jsonb else jsonb_build_object('override_reason', v_override) end)
  returning * into v_reg;
  if v_status = 'waitlisted' then
    update public.registrations set status = 'waitlisted', status_reason = 'Division full' where id = v_reg.id;
  else
    perform core.try_confirm_registration(v_reg.id);
  end if;
  perform core.write_audit(v_org, 'registration.create', 'public.registrations', v_reg.id, null,
    jsonb_build_object('event', ev.name, 'division', dv.name, 'member', v_member.member_no, 'fee', ev.fee,
      'by_staff', v_staff, 'override', v_override));
  select * into v_reg from public.registrations where id = v_reg.id;
  return jsonb_build_object('id', v_reg.id, 'status', v_reg.status, 'fee', v_reg.fee_snapshot);
end $$;

-- p_action: approve | reject. Approving a registration the club wants paid first waits for the verified fee.
create or replace function core.decide_registration(p_registration_id text, p_action text, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  r public.registrations;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_target text;
begin
  if p_action not in ('approve', 'reject') then
    raise exception 'unknown action' using errcode = '22023';
  end if;
  select * into r from public.registrations x where x.id = p_registration_id for update;
  if not found then
    raise exception 'registration not found' using errcode = '22023';
  end if;
  if not (core.has_permission(r.org_id, null, 'events.approve_registration')
          or core.has_permission(r.org_id, null, 'registrations.manage')) then
    raise exception 'you do not have permission to % registrations', p_action using errcode = '42501';
  end if;
  v_target := case p_action when 'approve' then 'confirmed' else 'rejected' end;
  if r.status = v_target then
    return jsonb_build_object('id', r.id, 'status', r.status, 'unchanged', true);
  end if;
  if r.status <> 'requested' then
    raise exception 'a registration that is % cannot be %', r.status, v_target using errcode = '22023';
  end if;
  if v_reason is not null and char_length(v_reason) > 500 then
    raise exception 'the reason is too long' using errcode = '22023';
  end if;
  if p_action = 'reject' then
    if v_reason is null or char_length(v_reason) < 3 then
      raise exception 'a reason is required' using errcode = '22023';
    end if;
    update public.registrations set status = 'rejected', status_reason = v_reason where id = r.id;
  else
    if core.registration_payment_pending(r.id) then
      raise exception 'the fee has not been paid and verified yet' using errcode = '22023';
    end if;
    perform core.confirm_registration_row(r.id, coalesce(core.current_profile_id(), 'system'));
  end if;
  perform core.write_audit(r.org_id, 'registration.' || p_action, 'public.registrations', r.id,
    jsonb_build_object('status', r.status), jsonb_build_object('status', v_target, 'reason', v_reason));
  return jsonb_build_object('id', r.id, 'status', v_target);
end $$;

-- ---------------------------------------------------------------------------
-- paying for a registration (same checks as a booking payment, against the fee copied into the registration)
-- ---------------------------------------------------------------------------
create or replace function core.submit_event_payment(p_id text, p_registration_id text, p_method text, p_reference_no text,
  p_amount numeric, p_proof_path text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_member public.members;
  v_reg public.registrations;
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

  v_hash := core.hash_of(jsonb_build_object('registration', p_registration_id, 'method', p_method, 'ref', v_ref,
    'amount', p_amount, 'proof', v_proof, 'member', v_member.id));
  select * into v_existing from public.payment_submissions p where p.id = p_id;
  if found then
    if v_existing.payload_hash = v_hash and v_existing.payer_member_id = v_member.id then
      return jsonb_build_object('id', v_existing.id, 'doc_no', v_existing.doc_no, 'status', v_existing.status, 'replayed', true);
    end if;
    raise exception 'this payment ID was already used for a different request' using errcode = 'CP422';
  end if;

  select * into v_reg from public.registrations r where r.id = p_registration_id for update;
  if not found or v_reg.member_id <> v_member.id then
    raise exception 'you can only pay for your own registration' using errcode = '42501';
  end if;
  if v_reg.status not in ('requested', 'confirmed', 'waitlisted') then
    raise exception 'a registration that is % cannot be paid', v_reg.status using errcode = '22023';
  end if;
  v_methods := coalesce(core.setting_value(v_member.org_id, 'payments.methods'), '["cash"]'::jsonb);
  if p_method is null or not (v_methods ? p_method) then
    raise exception 'the club does not accept that payment method' using errcode = '22023';
  end if;
  if p_method <> 'cash' and v_proof is null and core.setting_bool(v_member.org_id, 'payments.proof_required_non_cash', true) then
    raise exception 'attach the proof of payment' using errcode = '22023';
  end if;
  select coalesce(sum(p.amount), 0) into v_live from public.payment_submissions p
  where p.source_type = 'event_registration' and p.source_id = p_registration_id and p.status in ('submitted', 'verified');
  if v_live + p_amount > v_reg.fee_snapshot then
    raise exception 'that is more than the fee (%.2f still to pay)', greatest(v_reg.fee_snapshot - v_live, 0) using errcode = '22023';
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
    values (p_id, v_member.org_id, v_member.id, 'event_registration', p_registration_id, p_method, v_ref, p_amount, v_file_id, v_hash)
    returning * into v_payment;
  exception when unique_violation then
    raise exception 'that reference number was already used for another payment' using errcode = '23505';
  end;
  perform core.write_audit(v_member.org_id, 'payment.submit', 'public.payment_submissions', p_id, null,
    jsonb_build_object('registration', p_registration_id, 'method', p_method, 'amount', p_amount));
  return jsonb_build_object('id', v_payment.id, 'doc_no', v_payment.doc_no, 'status', v_payment.status);
end $$;

-- ---------------------------------------------------------------------------
-- what the caller can join
-- ---------------------------------------------------------------------------
create or replace function core.my_event_options() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  m public.members;
  v_out jsonb;
begin
  select * into m from public.members x where x.profile_id = core.current_profile_id() and x.deleted_at is null;
  if not found or m.status <> 'active' then
    return '[]'::jsonb;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id, 'name', e.name, 'starts_on', e.starts_on, 'ends_on', e.ends_on, 'location', e.location, 'fee', e.fee,
    'registration_opens_at', e.registration_opens_at, 'registration_closes_at', e.registration_closes_at,
    'divisions', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', d.id, 'name', d.name, 'format', d.format, 'gender', d.gender, 'age_group', d.age_group,
        'category', c.name, 'max_entries', d.max_entries,
        'taken', (select count(*) from public.registrations r where r.division_id = d.id and r.status in ('requested', 'confirmed')),
        'waitlisted', (select count(*) from public.registrations r where r.division_id = d.id and r.status = 'waitlisted'),
        'problem', core.registration_problem(m.id, d.id, true),
        'mine', (
          select jsonb_build_object('id', r.id, 'status', r.status, 'fee', r.fee_snapshot, 'paid', core.registration_paid(r.id),
            'pending', (select coalesce(sum(p.amount), 0) from public.payment_submissions p
                        where p.source_type = 'event_registration' and p.source_id = r.id and p.status = 'submitted'),
            'payment_required', core.setting_bool(m.org_id, 'payments.required.event_registration', false))
          from public.registrations r
          where r.division_id = d.id and r.member_id = m.id and r.status in ('requested', 'confirmed', 'waitlisted')
          limit 1)
      ) order by d.name), '[]'::jsonb)
      from public.divisions d join public.categories c on c.id = d.category_id
      where d.event_id = e.id and d.status = 'open')
  ) order by e.starts_on), '[]'::jsonb) into v_out
  from public.events e
  where e.org_id = m.org_id and e.status = 'registration_open';
  return v_out;
end $$;

-- ---- public wrappers
create or replace function public.register_for_event(p_id text, p_division_id text, p_partner_member_id text default null,
  p_member_id text default null, p_override_reason text default null) returns jsonb
language sql security invoker set search_path = '' as $$
  select core.register_for_event(p_id, p_division_id, p_partner_member_id, p_member_id, p_override_reason) $$;
create or replace function public.decide_registration(p_registration_id text, p_action text, p_reason text) returns jsonb
language sql security invoker set search_path = '' as $$ select core.decide_registration(p_registration_id, p_action, p_reason) $$;
create or replace function public.submit_event_payment(p_id text, p_registration_id text, p_method text, p_reference_no text,
  p_amount numeric, p_proof_path text default null) returns jsonb
language sql security invoker set search_path = '' as $$
  select core.submit_event_payment(p_id, p_registration_id, p_method, p_reference_no, p_amount, p_proof_path) $$;
create or replace function public.my_event_options() returns jsonb
language sql stable security invoker set search_path = '' as $$ select core.my_event_options() $$;

revoke all on function
  core.register_for_event(text, text, text, text, text), core.decide_registration(text, text, text),
  core.submit_event_payment(text, text, text, text, numeric, text), core.my_event_options(),
  public.register_for_event(text, text, text, text, text), public.decide_registration(text, text, text),
  public.submit_event_payment(text, text, text, text, numeric, text), public.my_event_options()
from public, anon, authenticated;
grant execute on function
  core.register_for_event(text, text, text, text, text), core.decide_registration(text, text, text),
  core.submit_event_payment(text, text, text, text, numeric, text), core.my_event_options(),
  public.register_for_event(text, text, text, text, text), public.decide_registration(text, text, text),
  public.submit_event_payment(text, text, text, text, numeric, text), public.my_event_options()
to authenticated, service_role;
