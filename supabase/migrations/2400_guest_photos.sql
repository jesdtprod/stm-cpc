-- Photos for event guests. A guest has no login, so staff with events.admin_roster add the photo for them.
-- Files live in the private "avatars" bucket under <org id>/g<guest person id>/<file>. The guest's persons row keeps the
-- path (avatar_path), the same column members use. Staff read the photos through signed links, as for member photos.

-- The folder and file name a new photo must use (made here so the browser never needs the person id).
create or replace function core.guest_photo_path(p_participant_id text) returns text
language plpgsql security definer set search_path = '' as $$
declare ep public.event_participants; ev public.events;
begin
  select * into ep from public.event_participants x where x.id = p_participant_id and x.member_id is null and x.deleted_at is null;
  if not found then raise exception 'guest not found' using errcode = '22023'; end if;
  select * into ev from public.events e where e.id = ep.event_id;
  if core.current_profile_id() is null or not core.has_permission(ev.org_id, ev.unit_id, 'events.admin_roster') then
    raise exception 'you do not have permission to change guest photos' using errcode = '42501';
  end if;
  return ev.org_id || '/g' || ep.person_id || '/' || core.ulid() || '.jpg';
end $$;

create or replace function core.set_event_guest_avatar(p_participant_id text, p_path text) returns void
language plpgsql security definer set search_path = '' as $$
declare ep public.event_participants; ev public.events; v_path text := nullif(btrim(coalesce(p_path, '')), '');
begin
  select * into ep from public.event_participants x where x.id = p_participant_id and x.member_id is null and x.deleted_at is null;
  if not found then raise exception 'guest not found' using errcode = '22023'; end if;
  select * into ev from public.events e where e.id = ep.event_id;
  if core.current_profile_id() is null or not core.has_permission(ev.org_id, ev.unit_id, 'events.admin_roster') then
    raise exception 'you do not have permission to change guest photos' using errcode = '42501';
  end if;
  if v_path is not null then
    if split_part(v_path, '/', 1) <> ev.org_id or split_part(v_path, '/', 2) <> 'g' || ep.person_id
       or v_path !~ '^[A-Za-z0-9]+/[A-Za-z0-9]+/[A-Za-z0-9_-]+\.(jpg|jpeg|png|webp)$' then
      raise exception 'the photo must be uploaded to this guest''s folder' using errcode = '42501';
    end if;
    if not exists (select 1 from storage.objects o where o.bucket_id = 'avatars' and o.name = v_path) then
      raise exception 'the photo was not found; upload it again' using errcode = '22023';
    end if;
  end if;
  update public.persons set avatar_path = v_path where id = ep.person_id and kind = 'guest';
  perform core.write_audit(ev.org_id, 'guest.photo', 'public.persons', ep.person_id);
end $$;

-- Photo paths of the guests in one event (staff only), for the roster and registration screens.
create or replace function core.guest_photos(p_event_id text) returns table (participant_id text, avatar_path text)
language plpgsql stable security definer set search_path = '' as $$
declare ev public.events;
begin
  select * into ev from public.events e where e.id = p_event_id;
  if not found or core.current_profile_id() is null
     or not (core.has_permission(ev.org_id, ev.unit_id, 'events.admin_roster') or core.has_permission(ev.org_id, ev.unit_id, 'events.manage')) then
    raise exception 'you do not have permission to view guest photos' using errcode = '42501';
  end if;
  return query
  select ep.id, pe.avatar_path
  from public.event_participants ep join public.persons pe on pe.id = ep.person_id and pe.deleted_at is null
  where ep.event_id = ev.id and ep.member_id is null and ep.deleted_at is null and pe.avatar_path is not null;
end $$;

create or replace function public.guest_photo_path(p_participant_id text) returns text
language sql security invoker set search_path = '' as $$ select core.guest_photo_path(p_participant_id) $$;
create or replace function public.set_event_guest_avatar(p_participant_id text, p_path text) returns void
language sql security invoker set search_path = '' as $$ select core.set_event_guest_avatar(p_participant_id, p_path) $$;
create or replace function public.guest_photos(p_event_id text) returns table (participant_id text, avatar_path text)
language sql stable security invoker set search_path = '' as $$ select * from core.guest_photos(p_event_id) $$;
revoke all on function core.guest_photo_path(text), core.set_event_guest_avatar(text, text), core.guest_photos(text),
  public.guest_photo_path(text), public.set_event_guest_avatar(text, text), public.guest_photos(text) from public, anon, authenticated;
grant execute on function core.guest_photo_path(text), core.set_event_guest_avatar(text, text), core.guest_photos(text),
  public.guest_photo_path(text), public.set_event_guest_avatar(text, text), public.guest_photos(text) to authenticated, service_role;

-- Storage: staff may add and read photos in a guest's folder (g + the guest's person id) of their organisation.
create policy avatars_guest_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'avatars'
    and core.has_permission((storage.foldername(name))[1], null, 'events.admin_roster')
    and exists (select 1 from public.persons p
      where p.id = substr((storage.foldername(name))[2], 2) and p.kind = 'guest' and p.org_id = (storage.foldername(name))[1])
  );
create policy avatars_guest_select on storage.objects for select to authenticated
  using (
    bucket_id = 'avatars'
    and (core.has_permission((storage.foldername(name))[1], null, 'events.admin_roster')
      or core.has_permission((storage.foldername(name))[1], null, 'events.manage'))
    and exists (select 1 from public.persons p
      where p.id = substr((storage.foldername(name))[2], 2) and p.kind = 'guest' and p.org_id = (storage.foldername(name))[1])
  );

notify pgrst, 'reload schema';
