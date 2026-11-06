-- Setting events.allow_multiple_divisions (Settings > Events): whether one player, member or guest, may be registered in more
-- than one division of the same event. ON (the default, and how the club has worked so far): allowed, as long as the player
-- is not in the same division twice. OFF: one division per event, as a registrant or as a partner. The rule applies to
-- registering and to the partner lists, which use the same checks.

insert into public.settings (org_id, key, value)
select o.id, 'events.allow_multiple_divisions', 'true'::jsonb from public.orgs o
on conflict (org_id, (coalesce(unit_id, '')), key) where deleted_at is null do nothing;

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
               'public.members_enabled', 'events.allow_multiple_divisions') then
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
  if ev.status <> 'registration_open' and not (ev.status = 'registration_closed' and core.has_permission(ev.org_id,dv.unit_id,'events.admin_roster')) then
    return 'Registration for this event is not open.';
  end if;
  if not core.has_permission(ev.org_id,dv.unit_id,'events.admin_roster') and ((ev.registration_opens_at is not null and now() < ev.registration_opens_at)
     or (ev.registration_closes_at is not null and now() >= ev.registration_closes_at)) then
    return 'Registration for this event is outside its registration window.';
  end if;
  if dv.status <> 'open' then
    return 'This division is not open for registration.';
  end if;
  if not p_soft then
    return null;
  end if;

  -- One division per event when the club turns multiple divisions off (events.allow_multiple_divisions).
  if not core.setting_bool(m.org_id, 'events.allow_multiple_divisions', true)
     and exists (select 1 from public.registrations r
       where r.event_id = dv.event_id and r.division_id <> dv.id and r.status in ('requested', 'confirmed', 'waitlisted')
         and (r.member_id = m.id or r.meta ->> 'partner_member_id' = m.id)) then
    return 'This member is already registered in another division of this event. Joining more than one division is turned off in Settings.';
  end if;

  if core.cpc_points_enabled(m.org_id) then
    -- ratings are on: the rating for this division's format decides (Singles or Doubles), never the Club Rank
    select r.id, r.sort_order, l.category_id into v_rank
    from public.member_cpc_ratings cr
    join public.ranks r on r.id = core.cpc_rank_for_points(m.org_id, cr.points)
    join public.rank_ladders l on l.id = r.ladder_id
    where cr.member_id = m.id and cr.discipline = dv.format and cr.deleted_at is null and cr.points is not null;
    if not found then
      -- No rating for this format: no division at all, so nobody can sandbag a low division. Staff set a rating first.
      return format('You have no %s rating yet, so you cannot join a division. Ask an administrator, manager or editor to assess your rating.', dv.format);
    end if;
  else
    select r.id, r.sort_order, l.category_id into v_rank
    from public.member_ranks mr
    join public.ranks r on r.id = mr.rank_id
    join public.rank_ladders l on l.id = r.ladder_id
    where mr.member_id = m.id and mr.deleted_at is null;
    if not found then
      return 'You have no rank yet, so you cannot join a ranked division.';
    end if;
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

create or replace function core.guest_registration_problem(p_participant text, p_division text, p_rank text, p_confirm boolean default false) returns text
language plpgsql stable security definer set search_path = '' as $$
declare ep public.event_participants; pe public.persons; dv public.divisions; ev public.events;
  rk record; lo integer; hi integer; age_years integer; grp text; v_points numeric;
begin
  select * into ep from public.event_participants where id = p_participant and deleted_at is null;
  if not found or ep.member_id is not null then return 'Choose a guest participant.'; end if;
  select * into dv from public.divisions where id = p_division;
  if not found or dv.event_id <> ep.event_id or dv.org_id <> ep.org_id then return 'That participant belongs to another event.'; end if;
  select * into ev from public.events where id = dv.event_id;
  if not ev.allow_guest_players then return 'This event does not allow guest players.'; end if;
  if ev.dupr_rated then return 'DUPR guest eligibility is not available yet.'; end if;
  if dv.status <> 'open' or (ev.status <> 'registration_open' and not ((p_confirm or core.has_permission(ev.org_id,dv.unit_id,'events.admin_roster')) and ev.status = 'registration_closed')) then return 'Registration is not open.'; end if;
  if not p_confirm and not core.has_permission(ev.org_id,dv.unit_id,'events.admin_roster') and ((ev.registration_opens_at is not null and now() < ev.registration_opens_at)
    or (ev.registration_closes_at is not null and now() >= ev.registration_closes_at)) then return 'Outside the registration window.'; end if;
  select * into pe from public.persons where id = ep.person_id and kind = 'guest' and deleted_at is null;
  if not found or exists(select 1 from public.members where person_id = pe.id) then return 'Choose an active guest identity.'; end if;
  if not core.setting_bool(ev.org_id, 'events.allow_multiple_divisions', true)
     and exists (select 1 from public.registrations r
       where r.event_id = ev.id and r.division_id <> dv.id and r.status in ('requested', 'confirmed', 'waitlisted')
         and (r.guest_participant_id = ep.id or r.guest_partner_participant_id = ep.id)) then
    return 'This guest is already registered in another division of this event. Joining more than one division is turned off in Settings.';
  end if;
  if core.cpc_points_enabled(ev.org_id) then
    select cr.points into v_points from public.event_participant_cpc_ratings cr
      where cr.participant_id = ep.id and cr.org_id = ev.org_id and cr.discipline = dv.format and cr.deleted_at is null;
    if v_points is null then
      -- No rating for this format: no division at all, the same rule as for members. An admin assesses the guest first.
      return format('This guest has no %s rating yet. Assess the guest''s rating before registering.', dv.format);
    end if;
    p_rank := core.cpc_rank_for_points(ev.org_id, v_points);
  end if;
  select r.sort_order, l.category_id into rk from public.ranks r join public.rank_ladders l on l.id = r.ladder_id
    join public.categories c on c.id = l.category_id
    where r.id = p_rank and r.deleted_at is null and l.deleted_at is null and c.deleted_at is null and r.org_id = ep.org_id;
  if not found or rk.category_id <> dv.category_id then return 'Assess the guest at a rank in this division category.'; end if;
  select sort_order into lo from public.ranks where id = dv.min_rank_id;
  select sort_order into hi from public.ranks where id = dv.max_rank_id;
  if rk.sort_order < lo or rk.sort_order > hi then return 'The guest rank is outside this division rank band.'; end if;
  if dv.gender in ('male','female') and pe.gender is distinct from dv.gender then return 'The guest does not meet this division gender requirement.'; end if;
  grp := btrim(coalesce(dv.age_group,''));
  if grp ~ '^\d{1,2}\+$' or grp ~ '^\d{1,2}\s*-\s*\d{1,2}$' then
    if pe.date_of_birth is null then return 'The guest birth date is required for this age group.'; end if;
    age_years := extract(year from age(ev.starts_on, pe.date_of_birth))::integer;
    if age_years < substring(grp from '^\d+')::integer
      or (grp !~ '\+$' and age_years > substring(grp from '(\d+)$')::integer) then return 'The guest does not meet this division age requirement.'; end if;
  end if;
  return null;
end $$;

notify pgrst, 'reload schema';
