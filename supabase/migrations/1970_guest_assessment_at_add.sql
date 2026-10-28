-- PLAN 8.6: a guest is assessed once, when they are added, with a Singles and/or Doubles rating (2.000-8.000) stored with
-- the guest. Registering a guest then takes the rank from the rating for the division's format (Singles for a singles
-- division, Doubles for a doubles division) instead of asking for an assessed rank again; the same for a guest partner.
-- A guest with no rating for that format cannot be registered until they are assessed. While ratings are off nothing
-- changes: the assessed rank is still passed in, as before.

create or replace function core.guest_assessed_rank(p_participant text, p_format text, p_org text) returns text
language plpgsql stable security definer set search_path = '' as $$
declare v_points numeric;
begin
  if not core.cpc_points_enabled(p_org) then
    return null;
  end if;
  select r.points into v_points from public.event_participant_cpc_ratings r
  where r.participant_id = p_participant and r.discipline = p_format and r.deleted_at is null;
  if v_points is null then
    raise exception 'Assess this guest''s % rating first: add it to the guest before registering them', p_format using errcode = '22023';
  end if;
  return core.cpc_rank_for_points(p_org, v_points);
end $$;
revoke all on function core.guest_assessed_rank(text, text, text) from public, anon, authenticated;
grant execute on function core.guest_assessed_rank(text, text, text) to authenticated, service_role;

-- the ratings of an event's guests, for the registration form (roster administrators)
create or replace function public.guest_participant_ratings(p_event_id text)
returns table (participant_id text, discipline text, points numeric)
language plpgsql stable security definer set search_path = '' as $$
declare ev public.events;
begin
  select * into ev from public.events e where e.id = p_event_id;
  if not found or core.current_profile_id() is null or not core.has_permission(ev.org_id, ev.unit_id, 'events.admin_roster') then
    raise exception 'You do not have permission to view guest ratings' using errcode = '42501';
  end if;
  return query
  select r.participant_id, r.discipline, r.points
  from public.event_participant_cpc_ratings r join public.event_participants ep on ep.id = r.participant_id
  where ep.event_id = ev.id and r.deleted_at is null and r.points is not null
  order by r.participant_id, r.discipline;
end $$;
revoke all on function public.guest_participant_ratings(text) from public, anon, authenticated;
grant execute on function public.guest_participant_ratings(text) to authenticated, service_role;

-- Add Guest now takes the assessment (replaces the 8-argument version)
drop function public.create_guest_event_participant(text, text, text, text, text, text, date, text);
create or replace function public.create_guest_event_participant(
  p_id text, p_event_id text, p_guest_person_id text, p_guest_name text,
  p_guest_mobile text default null, p_guest_gender text default null,
  p_guest_birth_date date default null, p_dupr_id text default null,
  p_singles_rating numeric default null, p_doubles_rating numeric default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare ev public.events; guest public.persons; result jsonb; replay jsonb;
  dupr text := nullif(upper(btrim(coalesce(p_dupr_id,''))), '');
  guest_name text := nullif(btrim(coalesce(p_guest_name,'')), '');
  mobile text := nullif(btrim(coalesce(p_guest_mobile,'')), '');
begin
  select * into ev from public.events where id = p_event_id for update;
  if not found or not core.has_permission(ev.org_id,ev.unit_id,'events.admin_roster') then
    raise exception 'You do not have permission to manage these event participants' using errcode = '42501';
  end if;
  if dupr is not null and dupr !~ '^[A-Z0-9]{1,32}$' then
    raise exception 'DUPR ID must contain 1 to 32 letters or numbers' using errcode = '22023';
  end if;
  if p_guest_person_id is null or not core.is_ulid(p_guest_person_id) or guest_name is null
    or char_length(guest_name) > 120 then
    raise exception 'A guest ID and name are required (up to 120 characters)' using errcode = '22023';
  end if;
  if p_singles_rating is not null then perform core.cpc_rating_band_code(p_singles_rating); end if;
  if p_doubles_rating is not null then perform core.cpc_rating_band_code(p_doubles_rating); end if;
  if core.cpc_points_enabled(ev.org_id) and p_singles_rating is null and p_doubles_rating is null then
    raise exception 'Assess the guest: enter a Singles rating, a Doubles rating, or both' using errcode = '22023';
  end if;
  replay := core.idem_begin(p_id,ev.org_id,'guest_participant.create',jsonb_build_object(
    'event',p_event_id,'person',p_guest_person_id,'name',guest_name,'mobile',mobile,
    'gender',p_guest_gender,'birth_date',p_guest_birth_date,'dupr_id',dupr,
    'singles',p_singles_rating,'doubles',p_doubles_rating));
  if replay is not null then return replay; end if;
  -- Seed the real guest identity first, so the participant trigger snapshots its ID.
  -- Any validation failure from the existing participant RPC rolls this insert back.
  begin
    insert into public.persons(id,org_id,kind,display_name,mobile,gender,date_of_birth,dupr_id)
      values(p_guest_person_id,ev.org_id,'guest',guest_name,mobile,p_guest_gender,p_guest_birth_date,dupr)
      on conflict(id) do nothing;
  exception when unique_violation then
    raise exception 'That DUPR ID is already recorded for another person in this club' using errcode = '23505';
  end;
  select * into guest from public.persons where id = p_guest_person_id for update;
  if guest.org_id <> ev.org_id or guest.kind <> 'guest' or guest.deleted_at is not null then
    raise exception 'Choose a guest identity in this club' using errcode = '22023';
  end if;
  if guest.dupr_id is distinct from dupr then
    raise exception 'Adding a participant cannot replace an existing person DUPR ID' using errcode = 'CP422';
  end if;
  result := public.create_event_participant(p_id,ev.id,null,p_guest_person_id,guest_name,mobile,p_guest_gender,p_guest_birth_date);
  -- the assessment is recorded once, with the guest (assessed by the roster administrator who adds them)
  if p_singles_rating is not null then
    insert into public.event_participant_cpc_ratings(org_id, unit_id, participant_id, discipline, points, source, reason, assessed_at, assessed_by)
      values (ev.org_id, ev.unit_id, p_id, 'singles', p_singles_rating, 'admin_assessment', 'Assessed when added as a guest', now(), core.current_profile_id());
  end if;
  if p_doubles_rating is not null then
    insert into public.event_participant_cpc_ratings(org_id, unit_id, participant_id, discipline, points, source, reason, assessed_at, assessed_by)
      values (ev.org_id, ev.unit_id, p_id, 'doubles', p_doubles_rating, 'admin_assessment', 'Assessed when added as a guest', now(), core.current_profile_id());
  end if;
  if p_singles_rating is not null or p_doubles_rating is not null then
    perform core.write_audit(ev.org_id, 'cpc_rating.guest_assessment', 'public.event_participants', p_id, null,
      jsonb_build_object('participant_id', p_id, 'singles', p_singles_rating, 'doubles', p_doubles_rating, 'at', 'add guest'));
  end if;
  result := result || jsonb_build_object('dupr_id',dupr);
  perform core.idem_complete(p_id,result);
  return result;
end $$;

create or replace function public.register_guest_for_event(p_id text, p_division_id text, p_participant_id text,
  p_rank_id text, p_partner_participant_id text default null, p_partner_rank_id text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare dv public.divisions; ev public.events; ep public.event_participants; partner public.event_participants;
  existing public.registrations; problem text; payload text; taken integer; reg_status text;
  guest_partner text; member_partner text; guest_name text; partner_name text;
begin
  select * into dv from public.divisions where id = p_division_id for update;
  if not found or not core.has_permission(dv.org_id, dv.unit_id, 'events.admin_roster') then
    raise exception 'You do not have permission to register guest players' using errcode = '42501';
  end if;
  if p_id is null or not core.is_ulid(p_id) then raise exception 'A registration ID is required' using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('registration:' || p_id,0));
  payload := core.hash_of(jsonb_build_object('division',p_division_id,'guest',p_participant_id,'rank',p_rank_id,
    'partner',p_partner_participant_id,'partner_rank',p_partner_rank_id));
  select * into existing from public.registrations where id = p_id;
  if found then
    if existing.org_id <> dv.org_id or existing.payload_hash <> payload then
      raise exception 'This registration ID was used for a different request' using errcode = 'CP422';
    end if;
    return jsonb_build_object('id',p_id,'status',existing.status,'fee',existing.fee_snapshot,'replayed',true);
  end if;
  select * into ev from public.events where id = dv.event_id;
  if p_rank_id is null then p_rank_id := core.guest_assessed_rank(p_participant_id, dv.format, ev.org_id); end if;
  problem := core.guest_registration_problem(p_participant_id,dv.id,p_rank_id);
  if problem is not null then raise exception '%',problem using errcode = '22023'; end if;
  select * into ep from public.event_participants where id = p_participant_id;
  select display_name into guest_name from public.persons where id = ep.person_id;
  if dv.format = 'doubles' then
    if p_partner_participant_id is null or p_partner_participant_id = ep.id then
      raise exception 'Choose another participant as the doubles partner' using errcode = '22023';
    end if;
    select * into partner from public.event_participants where id = p_partner_participant_id
      and event_id = ev.id and org_id = ev.org_id and deleted_at is null;
    if not found then raise exception 'Choose a partner from this event' using errcode = '22023'; end if;
    if partner.member_id is not null then
      if p_partner_rank_id is not null then raise exception 'Member rank comes from their profile' using errcode = '22023'; end if;
      problem := core.registration_problem(partner.member_id,dv.id,true);
      member_partner := partner.member_id;
    else
      if p_partner_rank_id is null then p_partner_rank_id := core.guest_assessed_rank(partner.id, dv.format, ev.org_id); end if;
      problem := core.guest_registration_problem(partner.id,dv.id,p_partner_rank_id);
      guest_partner := partner.id;
      select display_name into partner_name from public.persons where id = partner.person_id;
    end if;
    if problem is not null then raise exception 'Partner cannot join: %',problem using errcode = '22023'; end if;
  elsif p_partner_participant_id is not null or p_partner_rank_id is not null then
    raise exception 'Singles take no partner' using errcode = '22023';
  end if;
  if exists(select 1 from public.registrations r where r.division_id = dv.id and r.status in ('requested','confirmed','waitlisted')
    and (r.guest_participant_id in (ep.id,guest_partner) or r.guest_partner_participant_id in (ep.id,guest_partner)
      or (member_partner is not null and (r.member_id = member_partner or r.meta->>'partner_member_id' = member_partner)))) then
    raise exception 'A player already has an entry or pending registration in this division' using errcode = '22023';
  end if;
  select count(*) into taken from public.registrations where division_id = dv.id and status in ('requested','confirmed');
  reg_status := 'requested';
  if dv.max_entries is not null and taken >= dv.max_entries then
    if not core.setting_bool(ev.org_id,'events.waitlist_enabled',true) then raise exception 'This division is full' using errcode = '22023'; end if;
    reg_status := 'waitlisted';
  end if;
  insert into public.registrations(id,org_id,unit_id,event_id,division_id,member_id,fee_snapshot,payload_hash,
    guest_participant_id,guest_partner_participant_id,guest_rank_id,guest_partner_rank_id,guest_name_snapshot,guest_partner_name_snapshot,meta)
    values(p_id,ev.org_id,dv.unit_id,ev.id,dv.id,null,ev.fee,payload,ep.id,guest_partner,p_rank_id,p_partner_rank_id,guest_name,partner_name,
      case when member_partner is not null then jsonb_build_object('partner_member_id',member_partner) else '{}'::jsonb end);
  if reg_status = 'waitlisted' then update public.registrations set status = 'waitlisted' where id = p_id;
  else perform core.try_confirm_registration(p_id); end if;
  select * into existing from public.registrations where id = p_id;
  return jsonb_build_object('id',p_id,'status',existing.status,'fee',existing.fee_snapshot,'replayed',false);
end $$;

revoke all on function public.create_guest_event_participant(text, text, text, text, text, text, date, text, numeric, numeric) from public, anon, authenticated;
grant execute on function public.create_guest_event_participant(text, text, text, text, text, text, date, text, numeric, numeric) to authenticated;
revoke all on function public.register_guest_for_event(text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.register_guest_for_event(text, text, text, text, text, text) to authenticated;

notify pgrst, 'reload schema';
