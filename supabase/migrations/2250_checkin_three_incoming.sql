begin;
-- Add a maximum of three incoming reservations, including a current slot awaiting check-in.
-- Preserve current_booking/next_booking for older clients and the existing permission boundary.
create or replace function core.checkin_court_board() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_org text;
  v_now timestamptz := now();
  v_courts jsonb;
begin
  select p.org_id into v_org from public.profiles p where p.id = core.current_profile_id();
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
    and c.name ~* '^Tennis Court [1-4]$'
    and core.has_permission(c.org_id, c.unit_id, 'bookings.checkin');
  return jsonb_build_object('as_of', v_now, 'courts', v_courts);
end $$;
create or replace function public.checkin_court_board() returns jsonb
language sql stable security invoker set search_path = '' as $$ select core.checkin_court_board() $$;
revoke all on function core.checkin_court_board(), public.checkin_court_board() from public, anon, authenticated;
grant execute on function core.checkin_court_board(), public.checkin_court_board() to authenticated;
comment on function public.checkin_court_board() is 'Current and next confirmed bookings for Tennis Courts 1-4; requires bookings.checkin; no contact details.';
notify pgrst, 'reload schema';

commit;
