-- 1320_booking_helpers (PLAN 5.1, 5.4): what the booking screens need besides the booking functions.
--   find_players(term)               active members a member can add to a booking: name and member ID only, at most 10,
--                                    never the caller, needs bookings.create
--   quote_booking(court, start, min) the price and the first problem (if any) for a time, without booking anything;
--                                    the same rules request_booking applies, so the screen can warn early
--   expiry schedule                  expire_bookings() runs every 5 minutes through pg_cron when the extension is
--                                    available (requests are also expired whenever someone requests or approves)

create or replace function core.find_players(p_term text) returns table (member_id text, member_no text, display_name text)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_me public.members;
  v_term text := nullif(btrim(coalesce(p_term, '')), '');
begin
  select * into v_me from public.members m where m.profile_id = core.current_profile_id() and m.deleted_at is null;
  if not found or v_me.status <> 'active' or not core.has_permission(v_me.org_id, null, 'bookings.create') then
    raise exception 'only an active member can look up players' using errcode = '42501';
  end if;
  if v_term is null or char_length(v_term) < 2 then
    raise exception 'type at least 2 characters' using errcode = '22023';
  end if;
  return query
  select m.id, m.member_no, pe.display_name
  from public.members m join public.persons pe on pe.id = m.person_id
  where m.org_id = v_me.org_id and m.status = 'active' and m.deleted_at is null and m.id <> v_me.id
    and (m.member_no ilike '%' || replace(replace(v_term, '%', ''), '_', '') || '%'
         or pe.display_name ilike '%' || replace(replace(v_term, '%', ''), '_', '') || '%')
  order by pe.display_name
  limit 10;
end $$;

create or replace function core.quote_booking(p_court_id text, p_starts_at timestamptz, p_minutes integer)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_me public.members;
  v_org text;
  v_slot integer;
  v_end timestamptz;
  v_ls timestamp;
  v_le timestamp;
  v_court public.courts;
  v_hours record;
  v_problem text;
begin
  select * into v_me from public.members m where m.profile_id = core.current_profile_id() and m.deleted_at is null;
  if not found or v_me.status <> 'active' then
    raise exception 'only an active member can get a quote' using errcode = '42501';
  end if;
  v_org := v_me.org_id;
  v_slot := core.setting_int(v_org, 'booking.slot_minutes', 60);
  if p_minutes is null or p_minutes < v_slot or p_minutes > 240 or p_minutes % v_slot <> 0 then
    return jsonb_build_object('ok', false, 'problem', 'Choose a whole number of slots, up to 4 hours.');
  end if;
  v_end := p_starts_at + p_minutes * interval '1 minute';
  v_ls := p_starts_at at time zone 'Asia/Manila';
  v_le := v_end at time zone 'Asia/Manila';
  select * into v_court from public.courts c where c.id = p_court_id and c.org_id = v_org and c.deleted_at is null;
  if not found or v_court.status <> 'available' then
    v_problem := 'That court cannot be booked right now.';
  elsif p_starts_at <= now() then
    v_problem := 'Choose a time in the future.';
  elsif p_starts_at > now() + core.setting_int(v_org, 'booking.advance_days', 14) * interval '1 day' then
    v_problem := format('Bookings open up to %s days ahead.', core.setting_int(v_org, 'booking.advance_days', 14));
  else
    select * into v_hours from core.booking_hours(v_org, p_court_id, v_ls::date);
    if not found then
      v_problem := 'The court is closed that day.';
    elsif v_ls::time < v_hours.opens_at or (v_le::time > v_hours.closes_at and v_le::time <> '00:00') then
      v_problem := format('The court is open %s to %s.', to_char(v_hours.opens_at, 'HH24:MI'), to_char(v_hours.closes_at, 'HH24:MI'));
    elsif exists (select 1 from public.court_blackouts b where b.org_id = v_org and b.deleted_at is null
                  and (b.court_id is null or b.court_id = p_court_id) and b.during && tstzrange(p_starts_at, v_end, '[)')) then
      v_problem := 'The court is closed during that time.';
    elsif exists (select 1 from public.bookings b where b.court_id = p_court_id and b.status in ('pending_approval', 'confirmed', 'checked_in')
                  and not (b.status = 'pending_approval' and b.expires_at is not null and b.expires_at <= now())
                  and b.during && tstzrange(p_starts_at, v_end, '[)')) then
      v_problem := 'That time was just taken.';
    end if;
  end if;
  return jsonb_build_object('ok', v_problem is null, 'problem', v_problem,
    'price', core.booking_price(v_org, p_court_id, p_starts_at, v_end, v_slot),
    'approval_required', core.setting_bool(v_org, 'booking.approval_required', true),
    'payment_required', core.setting_bool(v_org, 'payments.required.court_booking', false));
end $$;

create or replace function public.find_players(p_term text) returns table (member_id text, member_no text, display_name text)
language sql stable security invoker set search_path = '' as $$ select * from core.find_players(p_term) $$;
create or replace function public.quote_booking(p_court_id text, p_starts_at timestamptz, p_minutes integer) returns jsonb
language sql stable security invoker set search_path = '' as $$ select core.quote_booking(p_court_id, p_starts_at, p_minutes) $$;

revoke all on function core.find_players(text), core.quote_booking(text, timestamptz, integer),
  public.find_players(text), public.quote_booking(text, timestamptz, integer) from public, anon, authenticated;
-- The functions check who the caller is.
grant execute on function core.find_players(text), core.quote_booking(text, timestamptz, integer),
  public.find_players(text), public.quote_booking(text, timestamptz, integer) to authenticated, service_role;

-- Scheduled expiry. Skipped quietly where pg_cron cannot be enabled; the lazy expiry still frees slots.
do $$
begin
  create extension if not exists pg_cron;
  perform cron.unschedule('cpc-expire-bookings') where exists (select 1 from cron.job where jobname = 'cpc-expire-bookings');
  perform cron.schedule('cpc-expire-bookings', '*/5 * * * *', 'select core.expire_bookings()');
exception when others then
  raise notice 'pg_cron not scheduled: %', sqlerrm;
end $$;
