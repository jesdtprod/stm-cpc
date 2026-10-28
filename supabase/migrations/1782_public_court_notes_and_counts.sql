-- Public court cards: approved court notes and count-only availability for today.
-- Booking/member identities, times, prices and blackout reasons stay private.
create function core.public_court_slot_counts(
  p_org text, p_court text, p_day date, p_asof timestamptz
) returns table (vacant integer, occupied integer)
language sql stable set search_path = '' as $$
  with hours as (
    select h.opens_at, h.closes_at
    from public.court_hours h
    where h.org_id = p_org and (h.court_id = p_court or h.court_id is null)
      and h.deleted_at is null and h.weekday = extract(dow from p_day)::integer
      and h.valid_from <= p_day and (h.valid_to is null or h.valid_to >= p_day)
    order by (h.court_id is not null) desc, h.valid_from desc, h.id desc limit 1
  ), step as (
    select make_interval(mins => greatest(1, core.setting_int(p_org, 'booking.slot_minutes', 60))) as duration
  ), slots as (
    select s.starts, s.starts + step.duration as ends
    from hours h cross join step
    cross join lateral generate_series(
      (p_day + h.opens_at) at time zone 'Asia/Manila',
      ((case when h.closes_at = '23:59'::time then p_day + interval '1 day'
        else p_day + h.closes_at end) at time zone 'Asia/Manila') - step.duration,
      step.duration
    ) s(starts)
  ), states as (
    select s.starts,
      exists(select 1 from public.bookings b where b.org_id = p_org and b.court_id = p_court
        and b.status in ('pending_approval', 'confirmed', 'checked_in')
        and b.during && tstzrange(s.starts, s.ends, '[)')) as booked,
      exists(select 1 from public.court_blackouts x where x.org_id = p_org
        and (x.court_id = p_court or x.court_id is null) and x.deleted_at is null
        and x.during && tstzrange(s.starts, s.ends, '[)')) as blocked
    from slots s
  )
  select count(*) filter(where not booked and not blocked and starts > p_asof)::integer,
    count(*) filter(where booked)::integer from states
$$;
revoke all on function core.public_court_slot_counts(text,text,date,timestamptz) from public, anon, authenticated;

create function public.public_courts() returns jsonb
language sql stable security definer set search_path = '' as $$
  with today as (select (now() at time zone 'Asia/Manila')::date as day), club as (
    select id from public.orgs where code = 'cpc' and deleted_at is null
  )
  select jsonb_build_object('courts', coalesce((
    select jsonb_agg(jsonb_build_object(
      'name', c.name, 'indoor', c.indoor, 'surface', c.surface,
      'notes', nullif(btrim(c.notes), ''),
      'hours', (
        select jsonb_build_object('opens', to_char(min(h.opens_at), 'HH24:MI'),
          'closes', to_char(max(h.closes_at), 'HH24:MI'), 'days', count(distinct h.weekday))
        from public.court_hours h where h.org_id = c.org_id
          and (h.court_id = c.id or h.court_id is null) and h.deleted_at is null
          and h.valid_from <= t.day and (h.valid_to is null or h.valid_to >= t.day)
      ),
      'availability', jsonb_build_object('day', t.day, 'vacant', a.vacant, 'occupied', a.occupied)
    ) order by c.sort_order, c.name, c.id)
    from public.courts c cross join today t
    cross join lateral core.public_court_slot_counts(c.org_id, c.id, t.day, now()) a
    where c.org_id in (select id from club) and c.deleted_at is null and c.status = 'available'
  ), '[]'::jsonb))
$$;
revoke all on function public.public_courts() from public, anon, authenticated;
grant execute on function public.public_courts() to anon, authenticated, service_role;
notify pgrst, 'reload schema';
