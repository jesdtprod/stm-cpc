-- PLAN 8.7: edit a guest. Event roster administrators (events.admin_roster) can correct a guest's profile (name, mobile, gender,
-- birth date, DUPR ID) and their Singles and Doubles ratings. Rating changes need a reason and are refused for a format whose
-- rating is frozen in a drawn division. A change that would make the guest ineligible for a division they are already in is
-- refused (same rules as registering). Registrations keep the name they were made under (they are fixed records).

-- the guest as the edit form shows it
create or replace function core.event_guest_profile(p_participant_id text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  ep public.event_participants; ev public.events; pe public.persons; s public.event_participant_cpc_ratings; d public.event_participant_cpc_ratings;
begin
  select * into ep from public.event_participants x where x.id = p_participant_id and x.deleted_at is null;
  if not found then raise exception 'guest not found' using errcode = '22023'; end if;
  select * into ev from public.events e where e.id = ep.event_id;
  if core.current_profile_id() is null or not core.has_permission(ev.org_id, ev.unit_id, 'events.admin_roster') then
    raise exception 'You do not have permission to manage these event participants' using errcode = '42501';
  end if;
  select * into pe from public.persons p where p.id = ep.person_id and p.kind = 'guest' and p.deleted_at is null;
  if not found or ep.member_id is not null then raise exception 'Only a guest can be edited here' using errcode = '22023'; end if;
  select * into s from public.event_participant_cpc_ratings r where r.participant_id = ep.id and r.discipline = 'singles' and r.deleted_at is null;
  select * into d from public.event_participant_cpc_ratings r where r.participant_id = ep.id and r.discipline = 'doubles' and r.deleted_at is null;
  return jsonb_build_object(
    'participant_id', ep.id, 'person_id', pe.id, 'display_name', pe.display_name, 'mobile', pe.mobile, 'gender', pe.gender,
    'date_of_birth', pe.date_of_birth, 'dupr_id', pe.dupr_id,
    'singles', jsonb_build_object('points', s.points, 'frozen', exists (select 1 from public.division_cpc_rating_snapshots z where z.participant_id = ep.id and z.discipline = 'singles')),
    'doubles', jsonb_build_object('points', d.points, 'frozen', exists (select 1 from public.division_cpc_rating_snapshots z where z.participant_id = ep.id and z.discipline = 'doubles')));
end $$;

-- Replaces the profile fields as given (the form sends the current values for anything unchanged); a rating left null is unchanged.
create or replace function core.update_event_guest(
  p_participant_id text, p_name text, p_mobile text, p_gender text, p_birth_date date, p_dupr_id text,
  p_singles_rating numeric, p_doubles_rating numeric, p_reason text, p_key text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  ep public.event_participants; ev public.events; pe public.persons; r public.registrations; dv public.divisions;
  v_name text := nullif(btrim(coalesce(p_name, '')), ''); v_mobile text := nullif(btrim(coalesce(p_mobile, '')), '');
  v_dupr text := nullif(upper(btrim(coalesce(p_dupr_id, ''))), ''); v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  d text; v_new numeric; cur public.event_participant_cpc_ratings; v_changed jsonb := '{}'::jsonb; v_rank text; v_problem text;
  replay jsonb; response jsonb; v_actor text := core.current_profile_id();
begin
  select * into ep from public.event_participants x where x.id = p_participant_id and x.deleted_at is null for update;
  if not found then raise exception 'guest not found' using errcode = '22023'; end if;
  select * into ev from public.events e where e.id = ep.event_id;
  if v_actor is null or not core.has_permission(ev.org_id, ev.unit_id, 'events.admin_roster') then
    raise exception 'You do not have permission to manage these event participants' using errcode = '42501';
  end if;
  select * into pe from public.persons p where p.id = ep.person_id and p.kind = 'guest' and p.deleted_at is null for update;
  if not found or ep.member_id is not null then raise exception 'Only a guest can be edited here' using errcode = '22023'; end if;
  if v_name is null or char_length(v_name) > 120 then raise exception 'A guest name is required (up to 120 characters)' using errcode = '22023'; end if;
  if v_mobile is not null and char_length(v_mobile) > 40 then raise exception 'The mobile number is too long' using errcode = '22023'; end if;
  if p_gender is not null and p_gender not in ('male', 'female') then raise exception 'Gender is male or female' using errcode = '22023'; end if;
  if v_dupr is not null and v_dupr !~ '^[A-Z0-9]{1,32}$' then raise exception 'DUPR ID must contain 1 to 32 letters or numbers' using errcode = '22023'; end if;
  if p_singles_rating is not null then perform core.cpc_rating_band_code(p_singles_rating); end if;
  if p_doubles_rating is not null then perform core.cpc_rating_band_code(p_doubles_rating); end if;
  if v_reason is not null and char_length(v_reason) > 500 then raise exception 'The reason is too long' using errcode = '22023'; end if;
  replay := core.idem_begin(p_key, ev.org_id, 'guest.update', jsonb_build_object('guest', ep.id, 'name', v_name, 'mobile', v_mobile,
    'gender', p_gender, 'birth', p_birth_date, 'dupr', v_dupr, 'singles', p_singles_rating, 'doubles', p_doubles_rating, 'reason', v_reason));
  if replay is not null then return replay; end if;

  -- ratings: only a changed value, with a reason, and never one that is frozen in a drawn division
  foreach d in array array['singles', 'doubles'] loop
    v_new := case d when 'singles' then p_singles_rating else p_doubles_rating end;
    continue when v_new is null;
    select * into cur from public.event_participant_cpc_ratings x where x.participant_id = ep.id and x.discipline = d and x.deleted_at is null for update;
    continue when found and cur.points is not distinct from v_new;
    if exists (select 1 from public.division_cpc_rating_snapshots z where z.participant_id = ep.id and z.discipline = d) then
      raise exception 'The guest''s % rating is frozen in a drawn division', d using errcode = '22023';
    end if;
    if v_reason is null or char_length(v_reason) < 3 then
      raise exception 'Give a reason (at least 3 characters) for changing a rating' using errcode = '22023';
    end if;
    if found then
      update public.event_participant_cpc_ratings set points = v_new, source = 'admin_assessment', reason = v_reason,
        assessed_at = now(), assessed_by = v_actor where id = cur.id;
    else
      insert into public.event_participant_cpc_ratings(org_id, unit_id, participant_id, discipline, points, source, reason, assessed_at, assessed_by)
        values (ev.org_id, ev.unit_id, ep.id, d, v_new, 'admin_assessment', v_reason, now(), v_actor);
    end if;
    v_changed := v_changed || jsonb_build_object(d, jsonb_build_object('from', cur.points, 'to', v_new));
  end loop;

  begin
    update public.persons set display_name = v_name, mobile = v_mobile, gender = p_gender, date_of_birth = p_birth_date, dupr_id = v_dupr
    where id = pe.id;
  exception when unique_violation then
    raise exception 'That DUPR ID is already recorded for another person in this club' using errcode = '23505';
  end;
  if (pe.display_name, pe.mobile, pe.gender, pe.date_of_birth, pe.dupr_id) is distinct from (v_name, v_mobile, p_gender, p_birth_date, v_dupr) then
    v_changed := v_changed || jsonb_build_object('profile', jsonb_build_object(
      'from', jsonb_build_object('name', pe.display_name, 'mobile', pe.mobile, 'gender', pe.gender, 'birth_date', pe.date_of_birth, 'dupr_id', pe.dupr_id),
      'to', jsonb_build_object('name', v_name, 'mobile', v_mobile, 'gender', p_gender, 'birth_date', p_birth_date, 'dupr_id', v_dupr)));
  end if;

  -- the guest must still be eligible for every open division they are already in (same rules as registering)
  for r in select x.* from public.registrations x
    where x.status in ('requested', 'confirmed', 'waitlisted') and (x.guest_participant_id = ep.id or x.guest_partner_participant_id = ep.id) loop
    select * into dv from public.divisions z where z.id = r.division_id;
    continue when dv.status <> 'open';
    v_rank := null;
    begin
      v_rank := core.guest_assessed_rank(ep.id, dv.format, ev.org_id);
    exception when others then
      v_rank := null;
    end;
    v_rank := coalesce(v_rank, case when r.guest_participant_id = ep.id then r.guest_rank_id else r.guest_partner_rank_id end);
    v_problem := core.guest_registration_problem(ep.id, dv.id, v_rank, true);
    if v_problem is not null then
      raise exception 'This change would make the guest ineligible for %: %', dv.name, v_problem using errcode = '22023';
    end if;
  end loop;

  perform core.write_audit(ev.org_id, 'event_guest.update', 'public.event_participants', ep.id, null,
    jsonb_build_object('participant_id', ep.id, 'changes', v_changed, 'reason', v_reason));
  response := jsonb_build_object('ok', true, 'participant_id', ep.id, 'changed', v_changed <> '{}'::jsonb);
  perform core.idem_complete(p_key, response);
  return response;
end $$;

create or replace function public.event_guest_profile(p_participant_id text)
returns jsonb language sql stable security invoker set search_path = '' as $$ select core.event_guest_profile(p_participant_id) $$;
create or replace function public.update_event_guest(
  p_participant_id text, p_name text, p_mobile text, p_gender text, p_birth_date date, p_dupr_id text,
  p_singles_rating numeric, p_doubles_rating numeric, p_reason text, p_key text
) returns jsonb language sql security invoker set search_path = '' as $$
  select core.update_event_guest(p_participant_id, p_name, p_mobile, p_gender, p_birth_date, p_dupr_id, p_singles_rating, p_doubles_rating, p_reason, p_key) $$;
revoke all on function core.event_guest_profile(text), public.event_guest_profile(text),
  core.update_event_guest(text, text, text, text, date, text, numeric, numeric, text, text),
  public.update_event_guest(text, text, text, text, date, text, numeric, numeric, text, text) from public, anon, authenticated;
grant execute on function core.event_guest_profile(text), public.event_guest_profile(text),
  core.update_event_guest(text, text, text, text, date, text, numeric, numeric, text, text),
  public.update_event_guest(text, text, text, text, date, text, numeric, numeric, text, text) to authenticated, service_role;

notify pgrst, 'reload schema';
