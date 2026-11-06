-- Team name for doubles registrations (members and admin-registered guests).
-- The name is kept on the registration (meta.team_name), so no table changes. The three registration functions that
-- already exist are left alone: each new "_team" function validates the name, calls the existing function and stores the
-- name in the same transaction, so a doubles registration never exists without one. core.entry_name (the name shown in
-- draws, matches, standings and notifications) uses the team name when there is one.

create or replace function core.team_name_clean(p_name text) returns text
language sql immutable set search_path = '' as $$
  select nullif(btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g')), '')
$$;

-- Validates and stores the team name for one registration just made (or replayed). Doubles need a name of 2 to 40
-- characters that no other active entry in the same event uses; singles take none.
create or replace function core.apply_team_name(p_registration_id text, p_division_id text, p_team_name text) returns void
language plpgsql security definer set search_path = '' as $$
declare dv public.divisions; v_name text := core.team_name_clean(p_team_name); reg public.registrations;
begin
  select * into dv from public.divisions d where d.id = p_division_id;
  if not found then raise exception 'division not found' using errcode = '22023'; end if;
  if dv.format <> 'doubles' then return; end if;
  if v_name is null then raise exception 'enter a team name' using errcode = '22023'; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 40 then
    raise exception 'the team name must be 2 to 40 characters' using errcode = '22023';
  end if;
  select * into reg from public.registrations r where r.id = p_registration_id;
  if not found then raise exception 'registration not found' using errcode = '22023'; end if;
  if exists (
    select 1 from public.registrations r
    where r.event_id = reg.event_id and r.id <> reg.id and r.status in ('requested', 'confirmed', 'waitlisted')
      and lower(r.meta ->> 'team_name') = lower(v_name)
  ) then
    raise exception 'that team name is already used in this event' using errcode = '23505';
  end if;
  update public.registrations set meta = meta || jsonb_build_object('team_name', v_name) where id = reg.id;
end $$;
revoke all on function core.team_name_clean(text), core.apply_team_name(text, text, text) from public, anon, authenticated;
grant execute on function core.team_name_clean(text), core.apply_team_name(text, text, text) to service_role;

-- Member registers with a member partner.
create or replace function public.register_for_event_team(p_id text, p_division_id text, p_team_name text,
  p_partner_member_id text default null, p_member_id text default null, p_override_reason text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r jsonb;
begin
  r := core.register_for_event(p_id, p_division_id, p_partner_member_id, p_member_id, p_override_reason);
  perform core.apply_team_name(p_id, p_division_id, p_team_name);
  return r;
end $$;

-- Member registers with a guest partner.
create or replace function public.register_for_event_with_guest_team(p_id text, p_division_id text, p_guest_participant_id text,
  p_team_name text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r jsonb;
begin
  r := public.register_for_event_with_guest(p_id, p_division_id, p_guest_participant_id);
  perform core.apply_team_name(p_id, p_division_id, p_team_name);
  return r;
end $$;

-- Admin registers a guest (and the partner).
create or replace function public.register_guest_for_event_team(p_id text, p_division_id text, p_participant_id text,
  p_rank_id text, p_team_name text, p_partner_participant_id text default null, p_partner_rank_id text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r jsonb;
begin
  r := public.register_guest_for_event(p_id, p_division_id, p_participant_id, p_rank_id, p_partner_participant_id, p_partner_rank_id);
  perform core.apply_team_name(p_id, p_division_id, p_team_name);
  return r;
end $$;

revoke all on function public.register_for_event_team(text, text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.register_for_event_with_guest_team(text, text, text, text) from public, anon, authenticated;
revoke all on function public.register_guest_for_event_team(text, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.register_for_event_team(text, text, text, text, text, text) to authenticated, service_role;
grant execute on function public.register_for_event_with_guest_team(text, text, text, text) to authenticated, service_role;
grant execute on function public.register_guest_for_event_team(text, text, text, text, text, text, text) to authenticated, service_role;

-- The name shown for an entry: its team name, otherwise the players' names.
create or replace function core.entry_name(p_entry_id text) returns text
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select core.team_name_clean(r.meta ->> 'team_name')
     from public.entries e join public.registrations r on r.id = e.registration_id where e.id = p_entry_id),
    (select string_agg(display_name, ' & ' order by display_name) from (
      select pe.display_name from public.entry_members em join public.members m on m.id = em.member_id
        join public.persons pe on pe.id = m.person_id where em.entry_id = p_entry_id
      union all
      select display_name_snapshot from public.entry_guests where entry_id = p_entry_id
    ) players)
  )
$$;

notify pgrst, 'reload schema';
