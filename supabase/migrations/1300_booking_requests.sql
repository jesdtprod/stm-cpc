-- 1300_booking_requests (PLAN 5.1 and 5.3): court bookings as server-side functions.
-- Members request, admins decide, everything is checked here and not in the browser.
--   request_booking(id, court, starts_at, minutes, other players)   the member asks for a court
--   decide_booking(booking, action, reason, key)                    approve / reject (bookings.approve);
--                                                                   check_in / no_show / complete (bookings.checkin)
--   cancel_booking(booking, reason, key)                            the requester, or bookings.cancel_any
--   expire_bookings()                                               frees the slot of every request past its time limit
-- Rules enforced: a member must be active; the length is a whole number of slots (setting booking.slot_minutes); the
-- day is inside the booking window (booking.advance_days) and inside the court's opening hours (dated, a court's own
-- hours beat "all courts"); the court is available and not blacked out; the group is within booking.max_participants
-- and every player is an active member; the price comes from the dated rates and is copied into the booking; the
-- database exclusion constraint makes two requests for one slot a single success. The booking ID is chosen by the
-- browser when the form opens: sending the same request again returns the same booking, a different request with the
-- same ID is refused (CP422).
-- Money (ledger, append-only; positive = credit to the member, negative = charge): confirming a booking charges its
-- price; cancelling a confirmed booking reverses that charge and may add the late cancellation fee; a no-show adds
-- the no-show fee. Payments (step 5.2) add credits.

-- ---- settings and member helpers
create or replace function core.setting_value(p_org text, p_key text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select s.value from public.settings s
  where s.org_id = p_org and s.unit_id is null and s.key = p_key and s.deleted_at is null
$$;
create or replace function core.setting_int(p_org text, p_key text, p_default integer) returns integer
language sql stable security definer set search_path = '' as $$
  select coalesce((select (core.setting_value(p_org, p_key) #>> '{}')::numeric::integer), p_default)
$$;
create or replace function core.setting_bool(p_org text, p_key text, p_default boolean) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select (core.setting_value(p_org, p_key) #>> '{}')::boolean), p_default)
$$;
create or replace function core.setting_money(p_org text, p_key text) returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce((select (core.setting_value(p_org, p_key) #>> '{}')::numeric), 0)
$$;
revoke all on function core.setting_value(text, text), core.setting_int(text, text, integer),
  core.setting_bool(text, text, boolean), core.setting_money(text, text) from public, anon, authenticated;
grant execute on function core.setting_value(text, text), core.setting_int(text, text, integer),
  core.setting_bool(text, text, boolean), core.setting_money(text, text) to service_role;

-- ---- opening hours and price
-- The hours that apply to a court on a date: its own row wins over the "all courts" row.
create or replace function core.booking_hours(p_org text, p_court text, p_day date)
returns table (opens_at time, closes_at time)
language sql stable security definer set search_path = '' as $$
  select h.opens_at, h.closes_at from public.court_hours h
  where h.org_id = p_org and h.deleted_at is null and (h.court_id = p_court or h.court_id is null)
    and h.weekday = extract(dow from p_day)::smallint and h.valid_from <= p_day and (h.valid_to is null or h.valid_to >= p_day)
  order by (h.court_id is not null) desc, h.valid_from desc
  limit 1
$$;

-- The price of a time range, one slot at a time: the most specific dated rate wins (a court beats "all courts", a
-- weekday beats every day, the latest start date beats an older one). No rate means free.
create or replace function core.booking_price(p_org text, p_court text, p_start timestamptz, p_end timestamptz, p_slot integer)
returns numeric
language plpgsql stable security definer set search_path = '' as $$
declare
  t timestamptz := p_start;
  seg_end timestamptz;
  local_ts timestamp;
  rate numeric;
  total numeric := 0;
begin
  while t < p_end loop
    seg_end := least(t + p_slot * interval '1 minute', p_end);
    local_ts := t at time zone 'Asia/Manila';
    select r.rate_per_hour into rate from public.court_rates r
    where r.org_id = p_org and r.deleted_at is null and (r.court_id = p_court or r.court_id is null)
      and (r.weekday is null or r.weekday = extract(dow from local_ts)::smallint)
      and r.valid_from <= local_ts::date and (r.valid_to is null or r.valid_to >= local_ts::date)
      and r.from_time <= local_ts::time and local_ts::time < r.to_time
    order by (r.court_id is not null) desc, (r.weekday is not null) desc, r.valid_from desc
    limit 1;
    total := total + coalesce(rate, 0) * (extract(epoch from (seg_end - t)) / 3600.0);
    t := seg_end;
  end loop;
  return round(total, 2);
end $$;
revoke all on function core.booking_hours(text, text, date), core.booking_price(text, text, timestamptz, timestamptz, integer)
  from public, anon, authenticated;
grant execute on function core.booking_hours(text, text, date), core.booking_price(text, text, timestamptz, timestamptz, integer) to service_role;

-- ---- ledger helpers
create or replace function core.ledger_account_for(p_org text, p_member text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_id text;
begin
  select a.id into v_id from public.ledger_accounts a
  where a.org_id = p_org and a.owner_type = 'member' and a.owner_id = p_member and a.currency = 'PHP' and a.deleted_at is null;
  if v_id is null then
    insert into public.ledger_accounts (org_id, owner_type, owner_id) values (p_org, 'member', p_member)
    on conflict (org_id, owner_type, owner_id, currency) where deleted_at is null do nothing;
    select a.id into v_id from public.ledger_accounts a
    where a.org_id = p_org and a.owner_type = 'member' and a.owner_id = p_member and a.currency = 'PHP' and a.deleted_at is null;
  end if;
  return v_id;
end $$;

-- One entry per business event: the same client_ref is recorded once however often the caller retries.
create or replace function core.post_ledger(p_org text, p_member text, p_amount numeric, p_source_type text, p_source_id text,
  p_client_ref text, p_note text, p_reverses text default null) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_account text := core.ledger_account_for(p_org, p_member);
  v_id text;
begin
  select e.id into v_id from public.ledger_entries e
  where e.org_id = p_org and e.source_type = p_source_type and e.source_id = p_source_id and e.client_ref = p_client_ref;
  if v_id is not null then
    return v_id;
  end if;
  insert into public.ledger_entries (org_id, account_id, amount, source_type, source_id, client_ref, note, reverses_entry_id)
  values (p_org, v_account, p_amount, p_source_type, p_source_id, p_client_ref, p_note, p_reverses)
  returning id into v_id;
  return v_id;
end $$;
revoke all on function core.ledger_account_for(text, text), core.post_ledger(text, text, numeric, text, text, text, text, text)
  from public, anon, authenticated;
grant execute on function core.ledger_account_for(text, text), core.post_ledger(text, text, numeric, text, text, text, text, text) to service_role;

-- Total of verified payments for a booking.
create or replace function core.booking_paid(p_booking text) returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce(sum(p.amount), 0) from public.payment_submissions p
  where p.source_type = 'booking' and p.source_id = p_booking and p.status = 'verified'
$$;
revoke all on function core.booking_paid(text) from public, anon, authenticated;
grant execute on function core.booking_paid(text) to service_role;

-- Moves a pending booking to confirmed and posts its charge. Used by approval, by a verified payment and by instant
-- confirmation, so the charge is always posted exactly once.
create or replace function core.confirm_booking_row(p_booking_id text, p_actor text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  b public.bookings;
begin
  select * into b from public.bookings where id = p_booking_id for update;
  if b.status <> 'pending_approval' then
    return;
  end if;
  update public.bookings set status = 'confirmed', approved_at = now(), approved_by = p_actor, expires_at = null where id = b.id;
  if b.price_snapshot > 0 then
    perform core.post_ledger(b.org_id, b.requested_by_member_id, -b.price_snapshot, 'booking', b.id, 'charge',
      'Court booking ' || b.doc_no);
  end if;
end $$;
revoke all on function core.confirm_booking_row(text, text) from public, anon, authenticated;
grant execute on function core.confirm_booking_row(text, text) to service_role;

-- Confirms a pending booking when the club does not need to approve it by hand and any required payment is verified.
create or replace function core.try_confirm_booking(p_booking_id text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  b public.bookings;
begin
  select * into b from public.bookings where id = p_booking_id;
  if b.status <> 'pending_approval' or core.setting_bool(b.org_id, 'booking.approval_required', true) then
    return;
  end if;
  if core.setting_bool(b.org_id, 'payments.required.court_booking', false) and b.price_snapshot > 0
     and core.booking_paid(b.id) < b.price_snapshot then
    return;
  end if;
  perform core.confirm_booking_row(b.id, 'system');
end $$;
revoke all on function core.try_confirm_booking(text) from public, anon, authenticated;
grant execute on function core.try_confirm_booking(text) to service_role;

-- ---- expiry
create or replace function core.expire_bookings() returns integer
language plpgsql security definer set search_path = '' as $$
declare
  n integer;
begin
  update public.bookings set status = 'expired', status_reason = 'the request was not approved in time'
  where status = 'pending_approval' and expires_at is not null and expires_at <= now();
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function core.expire_bookings() from public, anon, authenticated;
grant execute on function core.expire_bookings() to service_role;

-- ---- request
create or replace function core.request_booking(p_id text, p_court_id text, p_starts_at timestamptz, p_minutes integer,
  p_participants text[] default '{}') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_member public.members;
  v_org text;
  v_court public.courts;
  v_slot integer;
  v_end timestamptz;
  v_local_start timestamp;
  v_local_end timestamp;
  v_hours record;
  v_players text[];
  v_hash text;
  v_existing public.bookings;
  v_price numeric;
  v_hourly numeric;
  v_max integer;
  v_advance integer;
  v_booking public.bookings;
  v_other text;
begin
  select * into v_member from public.members m where m.profile_id = core.current_profile_id() and m.deleted_at is null;
  if not found or v_member.status <> 'active' then
    raise exception 'only an active member can book a court' using errcode = '42501';
  end if;
  v_org := v_member.org_id;
  if not core.has_permission(v_org, null, 'bookings.create') then
    raise exception 'you do not have permission to book a court' using errcode = '42501';
  end if;
  if p_id is null or not core.is_ulid(p_id) then
    raise exception 'the booking needs an ID made when the form opened' using errcode = '22023';
  end if;
  select coalesce(array_agg(distinct x order by x), '{}') into v_players
  from unnest(coalesce(p_participants, '{}')) x where x is not null and x <> v_member.id;
  v_slot := core.setting_int(v_org, 'booking.slot_minutes', 60);
  if p_minutes is null or p_minutes < v_slot or p_minutes > 240 or p_minutes % v_slot <> 0 then
    raise exception 'the booking length must be a whole number of % minute slots, up to 4 hours', v_slot using errcode = '22023';
  end if;
  v_end := p_starts_at + p_minutes * interval '1 minute';
  v_hash := encode(extensions.digest(convert_to(jsonb_build_object('court', p_court_id, 'start', p_starts_at,
    'minutes', p_minutes, 'players', to_jsonb(v_players), 'member', v_member.id)::text, 'utf8'), 'sha256'), 'hex');

  -- The same request again returns the same booking; another request under the same ID is refused.
  select * into v_existing from public.bookings b where b.id = p_id;
  if found then
    if v_existing.payload_hash = v_hash and v_existing.requested_by_member_id = v_member.id then
      return jsonb_build_object('id', v_existing.id, 'doc_no', v_existing.doc_no, 'status', v_existing.status,
        'price', v_existing.price_snapshot, 'expires_at', v_existing.expires_at, 'replayed', true);
    end if;
    raise exception 'this booking ID was already used for a different request' using errcode = 'CP422';
  end if;

  perform core.expire_bookings();
  if p_starts_at <= now() then
    raise exception 'choose a time in the future' using errcode = '22023';
  end if;
  v_advance := core.setting_int(v_org, 'booking.advance_days', 14);
  if p_starts_at > now() + v_advance * interval '1 day' then
    raise exception 'bookings open up to % days ahead', v_advance using errcode = '22023';
  end if;
  v_local_start := p_starts_at at time zone 'Asia/Manila';
  v_local_end := v_end at time zone 'Asia/Manila';
  if (extract(hour from v_local_start)::integer * 60 + extract(minute from v_local_start)::integer) % v_slot <> 0 then
    raise exception 'a booking starts on a % minute slot', v_slot using errcode = '22023';
  end if;
  if v_local_end::date <> v_local_start::date and not (v_local_end::time = '00:00' and v_local_end::date = v_local_start::date + 1) then
    raise exception 'a booking stays within one day' using errcode = '22023';
  end if;

  select * into v_court from public.courts c where c.id = p_court_id and c.org_id = v_org and c.deleted_at is null;
  if not found or v_court.status <> 'available' then
    raise exception 'the court is not available for booking' using errcode = '22023';
  end if;
  select * into v_hours from core.booking_hours(v_org, p_court_id, v_local_start::date);
  if not found then
    raise exception 'the court is closed that day' using errcode = '22023';
  end if;
  if v_local_start::time < v_hours.opens_at or (v_local_end::time > v_hours.closes_at and v_local_end::time <> '00:00')
     or (v_local_end::time = '00:00' and v_hours.closes_at <> '23:59:59' and v_hours.closes_at <> '24:00') then
    raise exception 'that time is outside the court''s opening hours (% to %)', to_char(v_hours.opens_at, 'HH24:MI'), to_char(v_hours.closes_at, 'HH24:MI') using errcode = '22023';
  end if;

  v_max := core.setting_int(v_org, 'booking.max_participants', 4);
  if cardinality(v_players) + 1 > v_max then
    raise exception 'a booking can have at most % players', v_max using errcode = '22023';
  end if;
  foreach v_other in array v_players loop
    if not exists (select 1 from public.members m where m.id = v_other and m.org_id = v_org and m.status = 'active' and m.deleted_at is null) then
      raise exception 'every player must be an active member' using errcode = '22023';
    end if;
  end loop;

  v_price := core.booking_price(v_org, p_court_id, p_starts_at, v_end, v_slot);
  v_hourly := round(v_price / (p_minutes / 60.0), 2);
  begin
    insert into public.bookings (id, org_id, court_id, requested_by_member_id, during, payload_hash, rate_snapshot, price_snapshot,
      court_name_snapshot, expires_at)
    values (p_id, v_org, p_court_id, v_member.id, tstzrange(p_starts_at, v_end, '[)'), v_hash, v_hourly, v_price, v_court.name,
      now() + core.setting_int(v_org, 'booking.request_expiry_hours', 24) * interval '1 hour')
    returning * into v_booking;
  exception when exclusion_violation then
    raise exception 'that time was just taken; choose another slot' using errcode = '23P01';
  end;
  insert into public.booking_participants (org_id, booking_id, member_id) values (v_org, v_booking.id, v_member.id);
  foreach v_other in array v_players loop
    insert into public.booking_participants (org_id, booking_id, member_id) values (v_org, v_booking.id, v_other);
  end loop;
  perform core.write_audit(v_org, 'booking.request', 'public.bookings', v_booking.id, null,
    jsonb_build_object('court', v_court.name, 'starts_at', p_starts_at, 'minutes', p_minutes, 'price', v_price));
  perform core.try_confirm_booking(v_booking.id);
  select * into v_booking from public.bookings where id = v_booking.id;
  return jsonb_build_object('id', v_booking.id, 'doc_no', v_booking.doc_no, 'status', v_booking.status,
    'price', v_booking.price_snapshot, 'expires_at', v_booking.expires_at);
end $$;

-- ---- decisions
create or replace function core.decide_booking(p_booking_id text, p_action text, p_reason text, p_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  b public.bookings;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_needed text;
  v_replay jsonb;
  v_response jsonb;
  v_target text;
  v_fee numeric;
begin
  if p_action not in ('approve', 'reject', 'check_in', 'no_show', 'complete') then
    raise exception 'unknown action' using errcode = '22023';
  end if;
  select * into b from public.bookings x where x.id = p_booking_id for update;
  if not found then
    raise exception 'booking not found' using errcode = '22023';
  end if;
  v_needed := case when p_action in ('approve', 'reject') then 'bookings.approve' else 'bookings.checkin' end;
  if not core.has_permission(b.org_id, null, v_needed) then
    raise exception 'you do not have permission to % bookings', replace(p_action, '_', ' ') using errcode = '42501';
  end if;
  if p_action = 'reject' and (v_reason is null or char_length(v_reason) < 3) then
    raise exception 'a reason is required' using errcode = '22023';
  end if;
  if v_reason is not null and char_length(v_reason) > 500 then
    raise exception 'the reason is too long' using errcode = '22023';
  end if;

  v_replay := core.idem_begin(p_key, b.org_id, 'booking.' || p_action,
    jsonb_build_object('booking_id', p_booking_id, 'reason', v_reason));
  if v_replay is not null then
    return v_replay;
  end if;
  v_target := case p_action when 'approve' then 'confirmed' when 'reject' then 'rejected' when 'check_in' then 'checked_in'
                            when 'no_show' then 'no_show' else 'completed' end;
  if b.status = v_target then
    v_response := jsonb_build_object('ok', true, 'booking_id', b.id, 'status', b.status, 'unchanged', true);
    perform core.idem_complete(p_key, v_response);
    return v_response;
  end if;

  if p_action in ('approve', 'reject') then
    if b.status <> 'pending_approval' then
      raise exception 'only a request that is waiting can be % (this one is %)', replace(p_action, 'approve', 'approved'), replace(b.status, '_', ' ') using errcode = '22023';
    end if;
    if p_action = 'approve' then
      if b.expires_at is not null and b.expires_at <= now() then
        perform core.expire_bookings();
        raise exception 'this request has expired and its time was released' using errcode = '22023';
      end if;
      if core.setting_bool(b.org_id, 'payments.required.court_booking', false) and b.price_snapshot > 0
         and core.booking_paid(b.id) < b.price_snapshot then
        raise exception 'the payment has not been verified yet' using errcode = '22023';
      end if;
      perform core.confirm_booking_row(b.id, coalesce(core.current_profile_id(), 'system'));
      if v_reason is not null then
        update public.bookings set status_reason = v_reason where id = b.id;
      end if;
    else
      update public.bookings set status = 'rejected', status_reason = v_reason, expires_at = null where id = b.id;
    end if;
  elsif p_action = 'check_in' then
    if b.status <> 'confirmed' then
      raise exception 'only a confirmed booking can be checked in' using errcode = '22023';
    end if;
    if now() < lower(b.during) - interval '60 minutes' or now() >= upper(b.during) then
      raise exception 'check-in opens one hour before the start and closes at the end of the booking' using errcode = '22023';
    end if;
    update public.bookings set status = 'checked_in', checked_in_at = now(), checked_in_by = coalesce(core.current_profile_id(), 'system') where id = b.id;
  elsif p_action = 'no_show' then
    if b.status <> 'confirmed' then
      raise exception 'only a confirmed booking can be a no-show' using errcode = '22023';
    end if;
    if now() < lower(b.during) then
      raise exception 'a booking cannot be a no-show before it starts' using errcode = '22023';
    end if;
    update public.bookings set status = 'no_show', status_reason = v_reason where id = b.id;
    v_fee := core.setting_money(b.org_id, 'booking.no_show_fee');
    if v_fee > 0 then
      perform core.post_ledger(b.org_id, b.requested_by_member_id, -v_fee, 'booking', b.id, 'no-show-fee', 'No-show fee ' || b.doc_no);
    end if;
  else
    if b.status <> 'checked_in' then
      raise exception 'only a checked-in booking can be completed' using errcode = '22023';
    end if;
    update public.bookings set status = 'completed' where id = b.id;
  end if;
  perform core.write_audit(b.org_id, 'booking.' || p_action, 'public.bookings', b.id,
    jsonb_build_object('status', b.status), jsonb_build_object('status', v_target, 'reason', v_reason));
  v_response := jsonb_build_object('ok', true, 'booking_id', b.id, 'status', v_target);
  perform core.idem_complete(p_key, v_response);
  return v_response;
end $$;

-- Cancelling: the requester (until the booking starts) or anyone with bookings.cancel_any.
-- A confirmed booking's charge is reversed. A member cancelling inside the cut-off (booking.cancel_cutoff_hours) pays
-- the late cancellation fee; staff cancelling never does.
create or replace function core.cancel_booking(p_booking_id text, p_reason text, p_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  b public.bookings;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_staff boolean;
  v_own boolean;
  v_replay jsonb;
  v_response jsonb;
  v_fee numeric := 0;
  v_charge text;
  v_cutoff integer;
begin
  select * into b from public.bookings x where x.id = p_booking_id for update;
  if not found then
    raise exception 'booking not found' using errcode = '22023';
  end if;
  v_staff := core.has_permission(b.org_id, null, 'bookings.cancel_any');
  v_own := core.is_own_member(b.requested_by_member_id);
  if not v_staff and not v_own then
    raise exception 'you cannot cancel this booking' using errcode = '42501';
  end if;
  if v_staff and not v_own and (v_reason is null or char_length(v_reason) < 3) then
    raise exception 'a reason is required' using errcode = '22023';
  end if;
  if v_reason is not null and char_length(v_reason) > 500 then
    raise exception 'the reason is too long' using errcode = '22023';
  end if;
  v_reason := coalesce(v_reason, 'cancelled by the member');

  v_replay := core.idem_begin(p_key, b.org_id, 'booking.cancel', jsonb_build_object('booking_id', p_booking_id, 'reason', v_reason));
  if v_replay is not null then
    return v_replay;
  end if;
  if b.status = 'cancelled' then
    v_response := jsonb_build_object('ok', true, 'booking_id', b.id, 'status', 'cancelled', 'unchanged', true);
    perform core.idem_complete(p_key, v_response);
    return v_response;
  end if;
  if b.status not in ('pending_approval', 'confirmed') then
    raise exception 'a booking that is % cannot be cancelled', replace(b.status, '_', ' ') using errcode = '22023';
  end if;
  if not v_staff and now() >= lower(b.during) then
    raise exception 'a booking that has started cannot be cancelled; ask the front desk' using errcode = '22023';
  end if;

  update public.bookings set status = 'cancelled', cancelled_at = now(), cancelled_by = coalesce(core.current_profile_id(), 'system'),
    cancel_reason = v_reason, expires_at = null where id = b.id;
  if b.status = 'confirmed' then
    select e.id into v_charge from public.ledger_entries e
    where e.org_id = b.org_id and e.source_type = 'booking' and e.source_id = b.id and e.client_ref = 'charge';
    if v_charge is not null then
      perform core.post_ledger(b.org_id, b.requested_by_member_id, b.price_snapshot, 'booking', b.id, 'charge-reversal',
        'Cancelled ' || b.doc_no, v_charge);
    end if;
    v_cutoff := core.setting_int(b.org_id, 'booking.cancel_cutoff_hours', 24);
    if not v_staff and lower(b.during) - now() < v_cutoff * interval '1 hour' then
      v_fee := core.setting_money(b.org_id, 'booking.cancel_fee');
      if v_fee > 0 then
        perform core.post_ledger(b.org_id, b.requested_by_member_id, -v_fee, 'booking', b.id, 'cancel-fee', 'Late cancellation ' || b.doc_no);
      end if;
    end if;
  end if;
  perform core.write_audit(b.org_id, 'booking.cancel', 'public.bookings', b.id,
    jsonb_build_object('status', b.status), jsonb_build_object('status', 'cancelled', 'reason', v_reason, 'fee', v_fee));
  v_response := jsonb_build_object('ok', true, 'booking_id', b.id, 'status', 'cancelled', 'fee', v_fee);
  perform core.idem_complete(p_key, v_response);
  return v_response;
end $$;

-- ---- public wrappers
create or replace function public.request_booking(p_id text, p_court_id text, p_starts_at timestamptz, p_minutes integer,
  p_participants text[] default '{}') returns jsonb
language sql security invoker set search_path = '' as $$ select core.request_booking(p_id, p_court_id, p_starts_at, p_minutes, p_participants) $$;
create or replace function public.decide_booking(p_booking_id text, p_action text, p_reason text, p_key text) returns jsonb
language sql security invoker set search_path = '' as $$ select core.decide_booking(p_booking_id, p_action, p_reason, p_key) $$;
create or replace function public.cancel_booking(p_booking_id text, p_reason text, p_key text) returns jsonb
language sql security invoker set search_path = '' as $$ select core.cancel_booking(p_booking_id, p_reason, p_key) $$;
create or replace function public.expire_bookings() returns integer
language sql security invoker set search_path = '' as $$ select core.expire_bookings() $$;

revoke all on function core.request_booking(text, text, timestamptz, integer, text[]), core.decide_booking(text, text, text, text),
  core.cancel_booking(text, text, text),
  public.request_booking(text, text, timestamptz, integer, text[]), public.decide_booking(text, text, text, text),
  public.cancel_booking(text, text, text), public.expire_bookings() from public, anon, authenticated;
-- Members and staff call these; each function checks who the caller is and what they may do.
grant execute on function core.request_booking(text, text, timestamptz, integer, text[]), core.decide_booking(text, text, text, text),
  core.cancel_booking(text, text, text),
  public.request_booking(text, text, timestamptz, integer, text[]), public.decide_booking(text, text, text, text),
  public.cancel_booking(text, text, text) to authenticated, service_role;
-- Expiry is run by the scheduler (service role) and also whenever a request is made.
grant execute on function public.expire_bookings() to service_role;
