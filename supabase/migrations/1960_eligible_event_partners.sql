-- Admin guest registration: the doubles partner list for a division. Lists the event's participants who could actually be
-- the partner: members who pass the same checks the registration enforces for a partner (rating, category, rank band,
-- gender, age, open registration), and guests (whose assessed rank is checked when registering). It leaves out the guest
-- being registered and anyone who already has a live registration in the division. A singles division has no partner,
-- so the list is empty. Registering still runs the strict checks in register_guest_for_event.
create or replace function core.eligible_event_partners(p_division_id text, p_guest_participant_id text default null)
returns table (id text, display_name text, member_id text, member_no text, is_guest boolean)
language plpgsql stable security definer set search_path = '' as $$
declare
  dv public.divisions; ev public.events;
begin
  select * into dv from public.divisions d where d.id = p_division_id;
  if not found then
    raise exception 'division not found' using errcode = '22023';
  end if;
  select * into ev from public.events e where e.id = dv.event_id;
  if core.current_profile_id() is null or not core.has_permission(ev.org_id, dv.unit_id, 'events.admin_roster') then
    raise exception 'you do not have permission to register guests' using errcode = '42501';
  end if;
  if dv.format <> 'doubles' then
    return;
  end if;
  return query
  select ep.id, pe.display_name, ep.member_id, m.member_no, ep.member_id is null
  from public.event_participants ep
  join public.persons pe on pe.id = ep.person_id
  left join public.members m on m.id = ep.member_id
  where ep.event_id = ev.id and ep.deleted_at is null and pe.deleted_at is null
    and ep.id is distinct from p_guest_participant_id
    and (ep.member_id is null
         or (m.status = 'active' and m.deleted_at is null and core.registration_problem(ep.member_id, dv.id, true) is null))
    and not exists (
      select 1 from public.registrations r
      where r.division_id = dv.id and r.status in ('requested', 'confirmed', 'waitlisted')
        and (r.guest_participant_id = ep.id or r.guest_partner_participant_id = ep.id
             or (ep.member_id is not null and (r.member_id = ep.member_id or (r.meta ->> 'partner_member_id') = ep.member_id))))
  order by pe.display_name, ep.id;
end $$;
create or replace function public.eligible_event_partners(p_division_id text, p_guest_participant_id text default null)
returns table (id text, display_name text, member_id text, member_no text, is_guest boolean)
language sql stable security invoker set search_path = '' as $$ select * from core.eligible_event_partners(p_division_id, p_guest_participant_id) $$;
revoke all on function core.eligible_event_partners(text, text), public.eligible_event_partners(text, text) from public, anon, authenticated;
grant execute on function core.eligible_event_partners(text, text), public.eligible_event_partners(text, text) to authenticated, service_role;

notify pgrst, 'reload schema';
