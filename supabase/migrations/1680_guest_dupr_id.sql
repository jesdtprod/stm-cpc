-- Optional self-reported guest DUPR ID. Recording is not verification or rating sync.
-- Reuse persons.dupr_id validation/uniqueness from 1630; preserve an event snapshot.
alter table public.event_participants add column dupr_id_snapshot text
  check (dupr_id_snapshot is null or dupr_id_snapshot ~ '^[A-Z0-9]{1,32}$');
comment on column public.event_participants.dupr_id_snapshot is
  'Self-reported DUPR ID when the participant was added; not verified. Older records remain null rather than inferring historical IDs.';

create function core.tg_event_participant_dupr() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    select dupr_id into new.dupr_id_snapshot from public.persons where id = new.person_id;
  elsif new.dupr_id_snapshot is distinct from old.dupr_id_snapshot then
    raise exception 'The event participant DUPR snapshot cannot be changed' using errcode = '22023';
  end if;
  return new;
end $$;
revoke all on function core.tg_event_participant_dupr() from public, anon, authenticated;
create trigger c_participant_dupr before insert or update on public.event_participants
  for each row execute function core.tg_event_participant_dupr();

create function public.create_guest_event_participant(
  p_id text, p_event_id text, p_guest_person_id text, p_guest_name text,
  p_guest_mobile text default null, p_guest_gender text default null,
  p_guest_birth_date date default null, p_dupr_id text default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare ev public.events; guest public.persons; result jsonb; replay jsonb;
  dupr text := nullif(upper(btrim(coalesce(p_dupr_id,''))), '');
  guest_name text := nullif(btrim(coalesce(p_guest_name,'')), '');
  mobile text := nullif(btrim(coalesce(p_guest_mobile,'')), '');
begin
  select * into ev from public.events where id = p_event_id for update;
  if not found or not core.has_permission(ev.org_id,ev.unit_id,'events.manage') then
    raise exception 'You do not have permission to manage these event participants' using errcode = '42501';
  end if;
  if dupr is not null and dupr !~ '^[A-Z0-9]{1,32}$' then
    raise exception 'DUPR ID must contain 1 to 32 letters or numbers' using errcode = '22023';
  end if;
  if p_guest_person_id is null or not core.is_ulid(p_guest_person_id) or guest_name is null
    or char_length(guest_name) > 120 then
    raise exception 'A guest ID and name are required (up to 120 characters)' using errcode = '22023';
  end if;
  replay := core.idem_begin(p_id,ev.org_id,'guest_participant.create',jsonb_build_object(
    'event',p_event_id,'person',p_guest_person_id,'name',guest_name,'mobile',mobile,
    'gender',p_guest_gender,'birth_date',p_guest_birth_date,'dupr_id',dupr));
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
  result := result || jsonb_build_object('dupr_id',dupr);
  perform core.idem_complete(p_id,result);
  return result;
end $$;
revoke all on function public.create_guest_event_participant(text,text,text,text,text,text,date,text)
  from public, anon, authenticated;
grant execute on function public.create_guest_event_participant(text,text,text,text,text,text,date,text) to authenticated;
