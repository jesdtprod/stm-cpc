-- PLAN 6.2a: participant identity foundation. This is a registry, not a registration
-- or an entry: existing member-only registration/fee/rank guards remain in force.
-- Reuse persons(kind = guest); never create an Auth account or a member for a guest.
create table public.event_participants (
  id text collate "C" primary key default core.ulid(),
  org_id text collate "C" not null references public.orgs(id) on delete restrict,
  unit_id text collate "C" references public.org_units(id) on delete restrict,
  event_id text collate "C" not null references public.events(id) on delete restrict,
  person_id text collate "C" not null references public.persons(id) on delete restrict,
  member_id text collate "C" references public.members(id) on delete restrict,
  payload_hash text not null check (payload_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  created_by text,
  updated_at timestamptz not null default now(),
  updated_by text,
  version integer not null default 1,
  deleted_at timestamptz,
  deleted_by text,
  delete_reason text,
  meta jsonb not null default '{}'::jsonb,
  constraint event_participants_deleted_chk check ((deleted_at is null) = (deleted_by is null))
);
comment on table public.event_participants is
  'class: master. permissions: events.manage. Reusable event participant identity; member_id null denotes a guest. Not an entry, payment, or eligibility approval.';
create index event_participants_org_idx on public.event_participants(org_id);
create index event_participants_unit_idx on public.event_participants(unit_id);
create index event_participants_person_idx on public.event_participants(person_id);
create index event_participants_member_idx on public.event_participants(member_id);
create unique index event_participants_person_live_uq
  on public.event_participants(event_id, person_id) where deleted_at is null;
select core.attach_standard('public.event_participants', 'master');
select core.enable_standard_rls('public.event_participants', 'org', 'events');
drop policy event_participants_select on public.event_participants;
drop policy event_participants_insert on public.event_participants;
drop policy event_participants_update on public.event_participants;
create policy event_participants_select on public.event_participants for select to authenticated
  using (core.has_permission(org_id, unit_id, 'events.manage'));
revoke all on public.event_participants from anon, authenticated;
grant select on public.event_participants to authenticated;

create function core.tg_event_participant_identity() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    if (new.org_id, new.unit_id, new.event_id, new.person_id, new.member_id, new.payload_hash)
      is distinct from (old.org_id, old.unit_id, old.event_id, old.person_id, old.member_id, old.payload_hash) then
      raise exception 'Participant identity cannot be reassigned' using errcode = '22023';
    end if;
    return new;
  end if;
  if not exists (select 1 from public.events e where e.id = new.event_id
    and e.org_id = new.org_id and e.unit_id is not distinct from new.unit_id) then
    raise exception 'Participant and event must belong to the same club and unit' using errcode = '22023';
  end if;
  if not exists (select 1 from public.persons p where p.id = new.person_id
    and p.org_id = new.org_id and p.deleted_at is null
    and ((new.member_id is null and p.kind = 'guest' and not exists (
      select 1 from public.members m where m.person_id = p.id))
    or exists (select 1 from public.members m where m.id = new.member_id
      and m.person_id = p.id and m.org_id = new.org_id
      and m.status = 'active' and m.deleted_at is null))) then
    raise exception 'Choose an active club member or an existing guest' using errcode = '22023';
  end if;
  return new;
end $$;
revoke all on function core.tg_event_participant_identity() from public, anon, authenticated;
create trigger c_participant_identity before insert or update on public.event_participants
  for each row execute function core.tg_event_participant_identity();

create function public.create_event_participant(
  p_id text, p_event_id text, p_member_id text default null,
  p_guest_person_id text default null, p_guest_name text default null,
  p_guest_mobile text default null, p_guest_gender text default null,
  p_guest_birth_date date default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_org text;
  v_event public.events;
  v_existing public.event_participants;
  v_person public.persons;
  v_person_id text;
  v_name text := nullif(btrim(coalesce(p_guest_name, '')), '');
  v_mobile text := nullif(btrim(coalesce(p_guest_mobile, '')), '');
  v_hash text;
begin
  select org_id into v_org from core.my_profile();
  select * into v_event from public.events where id = p_event_id and org_id = v_org for update;
  if not found or not core.has_permission(v_org, v_event.unit_id, 'events.manage') then
    raise exception 'You do not have permission to manage these event participants' using errcode = '42501';
  end if;
  if p_id is null or not core.is_ulid(p_id) then
    raise exception 'A participant ID is required' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('event-participant:' || p_id, 0));
  if (p_member_id is null) = (p_guest_person_id is null) then
    raise exception 'Choose either a member or a guest' using errcode = '22023';
  end if;
  if p_member_id is not null and (v_name is not null or v_mobile is not null
    or p_guest_gender is not null or p_guest_birth_date is not null) then
    raise exception 'Member details come from the member profile' using errcode = '22023';
  end if;
  v_hash := core.hash_of(jsonb_build_object('event', p_event_id, 'member', p_member_id,
    'guest', p_guest_person_id, 'name', v_name, 'mobile', v_mobile,
    'gender', p_guest_gender, 'birth_date', p_guest_birth_date));
  select * into v_existing from public.event_participants where id = p_id;
  if found then
    if v_existing.org_id <> v_org or v_existing.payload_hash <> v_hash then
      raise exception 'This participant ID was used for a different request' using errcode = 'CP422';
    end if;
    if v_existing.deleted_at is not null then
      raise exception 'This participant has been removed' using errcode = '22023';
    end if;
    return jsonb_build_object('id', p_id, 'person_id', v_existing.person_id,
      'member_id', v_existing.member_id, 'replayed', true);
  end if;
  if v_event.status not in ('draft', 'registration_open', 'registration_closed') then
    raise exception 'Participant setup is closed after the draw' using errcode = '22023';
  end if;
  if p_member_id is not null then
    select m.person_id into v_person_id from public.members m
      join public.persons p on p.id = m.person_id
      where m.id = p_member_id and m.org_id = v_org and m.status = 'active'
      and m.deleted_at is null and p.deleted_at is null;
    if not found then
      raise exception 'Choose an active club member' using errcode = '22023';
    end if;
  else
    if not core.is_ulid(p_guest_person_id) or char_length(v_name) > 120
      or char_length(v_mobile) > 40 or p_guest_gender not in ('male', 'female')
      or p_guest_birth_date > (now() at time zone 'Asia/Manila')::date then
      raise exception 'Guest details are invalid' using errcode = '22023';
    end if;
    if v_name is not null then
      insert into public.persons(id, org_id, kind, display_name, mobile, gender, date_of_birth)
        values (p_guest_person_id, v_org, 'guest', v_name, v_mobile, p_guest_gender, p_guest_birth_date)
        on conflict (id) do nothing;
    end if;
    select * into v_person from public.persons where id = p_guest_person_id for update;
    if not found or v_person.org_id <> v_org or v_person.kind <> 'guest'
      or v_person.deleted_at is not null then
      raise exception 'Choose an existing guest or provide a name for a new guest' using errcode = '22023';
    end if;
    if (v_name is not null and (v_person.display_name, v_person.mobile, v_person.gender, v_person.date_of_birth)
      is distinct from (v_name, v_mobile, p_guest_gender, p_guest_birth_date))
      or (v_name is null and (v_mobile is not null or p_guest_gender is not null or p_guest_birth_date is not null)) then
      raise exception 'Guest details cannot be changed while adding a participant' using errcode = 'CP422';
    end if;
    v_person_id := v_person.id;
  end if;
  if exists (select 1 from public.event_participants where event_id = p_event_id
    and person_id = v_person_id and deleted_at is null) then
    raise exception 'This person is already an event participant; reuse their participant record' using errcode = '22023';
  end if;
  insert into public.event_participants(id, org_id, unit_id, event_id, person_id, member_id, payload_hash)
    values (p_id, v_org, v_event.unit_id, p_event_id, v_person_id, p_member_id, v_hash);
  return jsonb_build_object('id', p_id, 'person_id', v_person_id, 'member_id', p_member_id, 'replayed', false);
end $$;
revoke all on function public.create_event_participant(text,text,text,text,text,text,text,date)
  from public, anon, authenticated;
grant execute on function public.create_event_participant(text,text,text,text,text,text,text,date) to authenticated;
