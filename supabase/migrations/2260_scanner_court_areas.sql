begin;
-- Court desk scopes are protected profile fields, not user-editable metadata.
alter table public.profiles add column if not exists checkin_court_scope text
  check (checkin_court_scope in ('tennis', 'backgate'));
comment on column public.profiles.checkin_court_scope is 'Optional scanner restriction: tennis = Tennis Courts 1-4; backgate = all Back Gate courts. Null preserves existing permission-based access. Set only through trusted administration.';

create or replace function core.can_checkin_court(p_court_id text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles p
    join public.courts c on c.org_id = p.org_id and c.id = p_court_id
    where p.id = core.current_profile_id() and c.deleted_at is null
      and core.has_permission(c.org_id, c.unit_id, 'bookings.checkin')
      and (p.checkin_court_scope is null
        or (p.checkin_court_scope = 'tennis' and c.name ~* '^Tennis Court [1-4]$')
        or (p.checkin_court_scope = 'backgate' and c.name ~* '^Back[[:space:]]*Gate[[:space:]]+Court[[:space:]]+[0-9]+$'))
  )
$$;
revoke all on function core.can_checkin_court(text) from public, anon;
grant execute on function core.can_checkin_court(text) to authenticated;

-- Add a maximum of three incoming reservations, including a current slot awaiting check-in.
-- Preserve current_booking/next_booking for older clients and the existing permission boundary.
create or replace function core.checkin_court_board() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_org text;
  v_scope text;
  v_now timestamptz := now();
  v_courts jsonb;
begin
  select p.org_id, coalesce(p.checkin_court_scope, 'tennis') into v_org, v_scope from public.profiles p where p.id = core.current_profile_id();
  if v_org is null or not core.has_permission(v_org, null, 'bookings.checkin') then
    raise exception 'you do not have permission to view the court board' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id, 'name', c.name, 'court_status', c.status,
    'blocked_until', (select max(upper(x.during)) from public.court_blackouts x
      where x.org_id = v_org and (x.court_id is null or x.court_id = c.id) and x.deleted_at is null and x.during @> v_now),
    'current_booking', (select jsonb_build_object(
      'status', b.status, 'starts_at', lower(b.during), 'ends_at', upper(b.during),
      'booked_by', pe.display_name,
      'players', (select coalesce(jsonb_agg(pp.display_name order by pp.display_name), '[]'::jsonb)
        from public.booking_participants bp
        join public.members pm on pm.id = bp.member_id and pm.org_id = v_org
        join public.persons pp on pp.id = pm.person_id and pp.org_id = v_org
        where bp.booking_id = b.id and bp.org_id = v_org))
      from public.bookings b
      join public.members m on m.id = b.requested_by_member_id and m.org_id = v_org
      join public.persons pe on pe.id = m.person_id and pe.org_id = v_org
      where b.org_id = v_org and b.court_id = c.id and b.status in ('confirmed', 'checked_in')
        and b.during @> v_now order by lower(b.during) limit 1),
    'incoming_bookings', (select coalesce(jsonb_agg(q.item order by q.starts_at), '[]'::jsonb) from (
      select lower(b.during) as starts_at, jsonb_build_object('starts_at', lower(b.during),
        'ends_at', upper(b.during), 'booked_by', pe.display_name) as item
      from public.bookings b
      join public.members m on m.id = b.requested_by_member_id and m.org_id = v_org
      join public.persons pe on pe.id = m.person_id and pe.org_id = v_org
      where b.org_id = v_org and b.court_id = c.id and b.status = 'confirmed'
        and upper(b.during) > v_now
        and lower(b.during) < ((v_now at time zone 'Asia/Manila')::date + 1)::timestamp at time zone 'Asia/Manila'
      order by lower(b.during), b.id limit 3
    ) q),
    'next_booking', (select jsonb_build_object('starts_at', lower(b.during),
      'ends_at', upper(b.during), 'booked_by', pe.display_name)
      from public.bookings b
      join public.members m on m.id = b.requested_by_member_id and m.org_id = v_org
      join public.persons pe on pe.id = m.person_id and pe.org_id = v_org
      where b.org_id = v_org and b.court_id = c.id and b.status = 'confirmed'
        and lower(b.during) > v_now
        and lower(b.during) < ((v_now at time zone 'Asia/Manila')::date + 1)::timestamp at time zone 'Asia/Manila'
      order by lower(b.during) limit 1)
    ) order by c.name), '[]'::jsonb) into v_courts
  from public.courts c
  where c.org_id = v_org and c.deleted_at is null
    and ((v_scope = 'tennis' and c.name ~* '^Tennis Court [1-4]$')
      or (v_scope = 'backgate' and c.name ~* '^Back[[:space:]]*Gate[[:space:]]+Court[[:space:]]+[0-9]+$'))
    and core.can_checkin_court(c.id)
    and core.has_permission(c.org_id, c.unit_id, 'bookings.checkin');
  return jsonb_build_object('as_of', v_now, 'court_area', v_scope, 'courts', v_courts);
end $$;
create or replace function public.checkin_court_board() returns jsonb
language sql stable security invoker set search_path = '' as $$ select core.checkin_court_board() $$;
revoke all on function core.checkin_court_board(), public.checkin_court_board() from public, anon, authenticated;
grant execute on function core.checkin_court_board(), public.checkin_court_board() to authenticated;
comment on function public.checkin_court_board() is 'Assigned court area, current check-ins and next three arrivals; requires bookings.checkin and enforces profile scope; no contact details.';
notify pgrst, 'reload schema';


create or replace function core.scan_check_in(p_booking_id text, p_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  b public.bookings;
  v_name text;
  v_member_no text;
  v_result jsonb;
begin
  select * into b from public.bookings x
  where x.id = p_booking_id
     or (x.doc_no = upper(btrim(p_booking_id)) and core.has_permission(x.org_id, null, 'bookings.checkin'))
  order by (x.id = p_booking_id) desc
  limit 1;
  if not found then
    raise exception 'this code does not match any booking' using errcode = '22023';
  end if;
  if not core.has_permission(b.org_id, null, 'bookings.checkin') then
    raise exception 'you do not have permission to check bookings in' using errcode = '42501';
  end if;
  if not core.can_checkin_court(b.court_id) then
    raise exception 'this court is not assigned to your scanner account' using errcode = '42501';
  end if;
  select p.display_name, m.member_no into v_name, v_member_no
  from public.members m join public.persons p on p.id = m.person_id where m.id = b.requested_by_member_id;
  if b.status = 'checked_in' then
    raise exception 'this booking is already checked in' using errcode = '22023';
  end if;
  if b.status <> 'confirmed' then
    raise exception 'this booking is % and cannot be checked in', replace(b.status, '_', ' ') using errcode = '22023';
  end if;
  if now() < lower(b.during) then
    raise exception 'too early: check-in opens at the start of the booking' using errcode = '22023';
  end if;
  if now() >= upper(b.during) then
    raise exception 'this booking has ended and its QR code is no longer valid' using errcode = '22023';
  end if;
  v_result := core.decide_booking(b.id, 'check_in', null, p_key);
  return v_result || jsonb_build_object('doc_no', b.doc_no, 'court', b.court_name_snapshot,
    'starts_at', lower(b.during), 'ends_at', upper(b.during), 'member_name', v_name, 'member_no', v_member_no);
end $$;

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
  if p_action in ('check_in', 'no_show', 'complete') and not core.can_checkin_court(b.court_id) then
    raise exception 'this court is not assigned to your scanner account' using errcode = '42501';
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

notify pgrst, 'reload schema';
commit;
