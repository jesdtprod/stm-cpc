-- Photos for the event Registrations table: the avatar path of every member who is a registrant or a doubles partner in an
-- event's registrations. Staff only (events.manage); guests have no photo (the screen shows their initials).
create or replace function core.registration_photos(p_event_id text)
returns table (member_id text, avatar_path text)
language plpgsql stable security definer set search_path = '' as $$
declare ev public.events;
begin
  select * into ev from public.events e where e.id = p_event_id;
  if not found or core.current_profile_id() is null or not core.has_permission(ev.org_id, ev.unit_id, 'events.manage') then
    raise exception 'you do not have permission to view registrations' using errcode = '42501';
  end if;
  return query
  select distinct m.id, pe.avatar_path
  from public.members m join public.persons pe on pe.id = m.person_id and pe.deleted_at is null
  where m.org_id = ev.org_id and pe.avatar_path is not null
    and m.id in (
      select r.member_id from public.registrations r where r.event_id = ev.id and r.member_id is not null
      union
      select (r.meta ->> 'partner_member_id') from public.registrations r where r.event_id = ev.id and r.meta ->> 'partner_member_id' is not null);
end $$;
create or replace function public.registration_photos(p_event_id text)
returns table (member_id text, avatar_path text)
language sql stable security invoker set search_path = '' as $$ select * from core.registration_photos(p_event_id) $$;
revoke all on function core.registration_photos(text), public.registration_photos(text) from public, anon, authenticated;
grant execute on function core.registration_photos(text), public.registration_photos(text) to authenticated, service_role;

notify pgrst, 'reload schema';
