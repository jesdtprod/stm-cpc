-- Court check-in by QR scan. The member shows the QR of an approved booking; the person in charge of the court scans it.
--   scan_check_in(booking, key)   needs bookings.checkin. Valid only from the start of the booking until its end
--                                 (Asia/Manila instants are stored as timestamptz, so the comparison is exact).
-- The state change is made by decide_booking (same locks, audit and idempotency); this function only adds the strict window
-- and returns what the court in-charge needs to see.
create or replace function core.scan_check_in(p_booking_id text, p_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  b public.bookings;
  v_name text;
  v_member_no text;
  v_result jsonb;
begin
  select * into b from public.bookings x where x.id = p_booking_id;
  if not found then
    raise exception 'this QR code does not match any booking' using errcode = '22023';
  end if;
  if not core.has_permission(b.org_id, null, 'bookings.checkin') then
    raise exception 'you do not have permission to check bookings in' using errcode = '42501';
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

create or replace function public.scan_check_in(p_booking_id text, p_key text) returns jsonb
language sql security invoker set search_path = '' as $$ select core.scan_check_in(p_booking_id, p_key) $$;

revoke all on function core.scan_check_in(text, text), public.scan_check_in(text, text) from public, anon, authenticated;
grant execute on function core.scan_check_in(text, text), public.scan_check_in(text, text) to authenticated, service_role;
comment on function public.scan_check_in(text, text) is 'QR check-in. Requires bookings.checkin; valid only between the start and end of a confirmed booking.';

notify pgrst, 'reload schema';
