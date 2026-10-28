-- PLAN 9.3a: distinguish registration alerts using server-recorded player and entry details.
-- Existing append-only notifications are preserved; recipients and status-change rules stay intact.
create or replace function core.tg_notify_registration() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_player text;
  v_partner_name text;
  v_body text;
  v_div text;
  v_event text;
  v_url text;
  v_partner text := new.meta ->> 'partner_member_id';
  v_actor text := core.current_profile_id();
  v_owner_profile text;
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then
    return null;
  end if;
  select d.name, e.name, '#/bracket?division=' || d.id into v_div, v_event, v_url
  from public.divisions d join public.events e on e.id = d.event_id where d.id = new.division_id;
  select m.profile_id into v_owner_profile from public.members m where m.id = new.member_id;
  select p.display_name into v_player
  from public.members m join public.persons p on p.id = m.person_id
  where m.id = new.member_id and m.org_id = new.org_id;
  select p.display_name into v_partner_name
  from public.members m join public.persons p on p.id = m.person_id
  where m.id = v_partner and m.org_id = new.org_id;
  -- Keep each field within the existing 300-character message budget. No contact data.
  v_body := concat_ws(E'\n',
    'Player: ' || left(coalesce(new.guest_name_snapshot, v_player, 'Player'), 40),
    case when coalesce(new.guest_partner_name_snapshot, v_partner_name) is not null
      then 'Partner: ' || left(coalesce(new.guest_partner_name_snapshot, v_partner_name), 40) end,
    'Event: ' || left(v_event, 55),
    'Division: ' || left(v_div, 45),
    'Status: ' || initcap(new.status),
    'Reference: ' || new.id);
  if new.status = 'requested' and (tg_op = 'INSERT') then
    perform core.notify_staff(new.org_id, 'events.approve_registration', 'staff.registration_requested', 'New event registration',
      v_body, '#/admin/events');
  elsif new.status = 'confirmed' then
    perform core.notify_member(new.member_id, 'registration.confirmed', 'You are registered', v_body, '#/events');
    if v_partner is not null then
      perform core.notify_member(v_partner, 'registration.confirmed', 'You are registered as a partner', v_body, '#/events');
    end if;
  elsif new.status = 'rejected' then
    perform core.notify_member(new.member_id, 'registration.rejected', 'Your registration was not accepted', v_body, '#/events');
  elsif new.status = 'waitlisted' then
    perform core.notify_member(new.member_id, 'registration.waitlisted', 'You are on the waitlist', v_body, '#/events');
  elsif new.status = 'requested' and tg_op = 'UPDATE' and old.status = 'waitlisted' then
    perform core.notify_member(new.member_id, 'registration.promoted', 'A place opened up for you', v_body, '#/events');
  elsif new.status = 'withdrawn' and v_actor is distinct from v_owner_profile then
    perform core.notify_member(new.member_id, 'registration.withdrawn', 'Your registration was withdrawn by the club', v_body, '#/events');
  end if;
  return null;
end $$;
revoke all on function core.tg_notify_registration() from public, anon, authenticated;
