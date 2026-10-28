-- Guest partners must pass the same division checks as the lead guest.
-- With ratings enabled, always use the stored discipline rating, never a caller-supplied rank.
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
  if core.cpc_points_enabled(ev.org_id) then
    select cr.points into v_points from public.event_participant_cpc_ratings cr
      where cr.participant_id = ep.id and cr.org_id = ev.org_id and cr.discipline = dv.format and cr.deleted_at is null;
    if v_points is null then return format('Assess this guest''s %s rating before registering them.', dv.format); end if;
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

create or replace function core.eligible_event_partners(p_division_id text, p_guest_participant_id text default null)
returns table (id text, display_name text, member_id text, member_no text, is_guest boolean)
language plpgsql stable security definer set search_path = '' as $$
declare dv public.divisions; ev public.events; v_ratings boolean;
begin
  select * into dv from public.divisions d where d.id = p_division_id;
  if not found then raise exception 'division not found' using errcode = '22023'; end if;
  select * into ev from public.events e where e.id = dv.event_id;
  if core.current_profile_id() is null or not core.has_permission(ev.org_id, dv.unit_id, 'events.admin_roster') then
    raise exception 'you do not have permission to register guests' using errcode = '42501';
  end if;
  if dv.format <> 'doubles' then return; end if;
  v_ratings := core.cpc_points_enabled(ev.org_id);
  if v_ratings and p_guest_participant_id is not null
    and core.guest_registration_problem(p_guest_participant_id, dv.id, null) is not null then return; end if;
  return query
  select ep.id, pe.display_name, ep.member_id, m.member_no, ep.member_id is null
  from public.event_participants ep
  join public.persons pe on pe.id = ep.person_id
  left join public.members m on m.id = ep.member_id
  where ep.event_id = ev.id and ep.org_id = ev.org_id and ep.deleted_at is null and pe.deleted_at is null
    and ep.id is distinct from p_guest_participant_id
    and ((ep.member_id is null and (not v_ratings or core.guest_registration_problem(ep.id, dv.id, null) is null))
      or (ep.member_id is not null and m.status = 'active' and m.deleted_at is null and core.registration_problem(ep.member_id, dv.id, true) is null))
    and not exists (
      select 1 from public.registrations r
      where r.division_id = dv.id and r.status in ('requested', 'confirmed', 'waitlisted')
        and (r.guest_participant_id = ep.id or r.guest_partner_participant_id = ep.id
          or (ep.member_id is not null and (r.member_id = ep.member_id or r.meta ->> 'partner_member_id' = ep.member_id))))
  order by pe.display_name, ep.id;
end $$;
revoke all on function core.eligible_event_partners(text, text) from public, anon, authenticated;
grant execute on function core.eligible_event_partners(text, text) to authenticated, service_role;
notify pgrst, 'reload schema';
