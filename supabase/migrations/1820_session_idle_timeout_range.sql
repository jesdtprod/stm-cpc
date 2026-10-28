-- 1820_session_idle_timeout_range: allow any positive whole-minute session timeout.
-- The browser and server both enforce this so long-lived club sessions (for example,
-- 3600 minutes) can be saved without permitting zero, negative, or fractional values.

create or replace function core.setting_valid(p_key text, p_value jsonb) returns boolean
language plpgsql stable set search_path = '' as $$
declare
  t text;
  n numeric;
  item text;
begin
  if p_value is null or p_value = 'null'::jsonb then
    return false;
  end if;
  t := jsonb_typeof(p_value);

  if p_key = 'timezone' then
    return t = 'string' and exists (select 1 from pg_catalog.pg_timezone_names z where z.name = p_value #>> '{}');
  end if;

  if p_key in ('members.signup_enabled', 'members.auto_approve_imported', 'booking.approval_required',
               'payments.required.court_booking', 'payments.required.event_registration',
               'payments.proof_required_non_cash', 'events.registration_approval_required',
               'events.waitlist_enabled', 'ranks.movement_enabled', 'public.results_enabled', 'public.leaderboard_enabled',
               'member_menu.book', 'member_menu.bookings', 'member_menu.events', 'member_menu.ranking',
               'public.members_enabled') then
    return t = 'boolean';
  end if;

  if p_key in ('club.name', 'events.default_scoring_rule') then
    return t = 'string' and char_length(btrim(p_value #>> '{}')) between 1 and 80;
  end if;
  if p_key = 'members.id_prefix' then
    return t = 'string' and (p_value #>> '{}') ~ '^[A-Z]{2,6}$';
  end if;
  if p_key = 'members.id_pattern' then
    return t = 'string' and char_length(p_value #>> '{}') between 1 and 200;
  end if;
  if p_key = 'payments.instructions' then
    return t = 'string' and char_length(p_value #>> '{}') <= 1000;
  end if;

  if p_key = 'payments.methods' then
    if t <> 'array' or jsonb_array_length(p_value) not between 1 and 4 then
      return false;
    end if;
    for item in select jsonb_array_elements_text(p_value) loop
      if item not in ('cash', 'gcash', 'maya', 'bank_transfer') then
        return false;
      end if;
    end loop;
    return (select count(distinct e) = jsonb_array_length(p_value) from jsonb_array_elements_text(p_value) e);
  end if;

  if p_key in ('members.temp_password_days', 'session.idle_minutes', 'booking.slot_minutes', 'booking.advance_days',
               'booking.max_participants', 'booking.request_expiry_hours', 'booking.cancel_cutoff_hours') then
    if t <> 'number' then
      return false;
    end if;
    n := (p_value #>> '{}')::numeric;
    if n <> trunc(n) then
      return false;
    end if;
    return case p_key
      when 'members.temp_password_days' then n between 0 and 365
      when 'session.idle_minutes' then n >= 1
      when 'booking.slot_minutes' then n between 15 and 240
      when 'booking.advance_days' then n between 1 and 365
      when 'booking.max_participants' then n between 1 and 20
      when 'booking.request_expiry_hours' then n between 1 and 168
      else n between 0 and 168
    end;
  end if;

  if p_key in ('booking.cancel_fee', 'booking.no_show_fee') then
    if t <> 'number' then
      return false;
    end if;
    n := (p_value #>> '{}')::numeric;
    return n >= 0 and n <= 100000 and n = round(n, 2);
  end if;

  return true;
end $$;
