-- 1020_courts_bookings (PLAN 2.3, part 1 of 2; design: docs/CLUB_SCHEMA.md 4.3)
-- courts, court_hours, court_rates, court_blackouts, bookings (no double-booking), booking_participants,
-- booking_events. Courts and their schedules are edited by courts.manage. Bookings are documents:
-- clients get SELECT only; the booking RPCs (stage 5) create and move them, inside the state machine below.

create extension if not exists btree_gist with schema extensions;

-- True when the caller is the member (their profile is the member's profile).
create or replace function core.is_own_member(p_member_id text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.members m
    where m.id = p_member_id and m.profile_id = core.current_profile_id() and m.deleted_at is null
  )
$$;
revoke all on function core.is_own_member(text) from public, anon;
grant execute on function core.is_own_member(text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- courts. class: master. permissions: courts.manage
-- ---------------------------------------------------------------------------
create table public.courts (
  id            text collate "C" primary key default core.ulid(),
  org_id        text not null references public.orgs (id) on delete restrict,
  unit_id       text collate "C" references public.org_units (id) on delete restrict,
  code          text not null constraint courts_code_chk check (code ~ '^[a-z0-9][a-z0-9_-]{0,31}$'),
  name          text not null constraint courts_name_chk check (length(btrim(name)) > 0),
  status        text not null default 'available' constraint courts_status_chk check (status in ('available', 'maintenance', 'closed')),
  surface       text,
  indoor        boolean not null default false,
  notes         text,
  file_id       text collate "C" references public.files (id) on delete restrict,
  sort_order    integer not null default 0,
  created_at    timestamptz not null default now(),
  created_by    text,
  updated_at    timestamptz not null default now(),
  updated_by    text,
  version       integer not null default 1,
  deleted_at    timestamptz,
  deleted_by    text,
  delete_reason text,
  meta          jsonb not null default '{}'::jsonb
);
comment on table public.courts is 'class: master. permissions: courts.manage. A court with bookings is set to closed, not deleted.';
create index courts_org_idx on public.courts (org_id);
create index courts_unit_idx on public.courts (unit_id);
create index courts_file_idx on public.courts (file_id);
create unique index courts_code_active_uq on public.courts (org_id, code) where deleted_at is null;

-- ---------------------------------------------------------------------------
-- court_hours: operating hours per weekday, effective-dated. court_id null = every court.
-- ---------------------------------------------------------------------------
create table public.court_hours (
  id            text collate "C" primary key default core.ulid(),
  org_id        text not null references public.orgs (id) on delete restrict,
  unit_id       text collate "C" references public.org_units (id) on delete restrict,
  court_id      text collate "C" references public.courts (id) on delete restrict,
  weekday       smallint not null constraint court_hours_weekday_chk check (weekday between 0 and 6),
  opens_at      time not null,
  closes_at     time not null,
  valid_from    date not null,
  valid_to      date,
  created_at    timestamptz not null default now(),
  created_by    text,
  updated_at    timestamptz not null default now(),
  updated_by    text,
  version       integer not null default 1,
  deleted_at    timestamptz,
  deleted_by    text,
  delete_reason text,
  meta          jsonb not null default '{}'::jsonb,
  constraint court_hours_time_chk check (closes_at > opens_at),
  constraint court_hours_valid_chk check (valid_to is null or valid_to >= valid_from),
  -- One window per court (or all courts) per weekday at any date.
  constraint court_hours_no_overlap_excl exclude using gist (
    org_id with =, (coalesce(court_id, '')) with =, weekday with =,
    daterange(valid_from, valid_to, '[]') with &&
  ) where (deleted_at is null)
);
comment on table public.court_hours is 'class: master. permissions: courts.manage. weekday 0 = Sunday. Times are Asia/Manila wall-clock times.';
create index court_hours_org_idx on public.court_hours (org_id);
create index court_hours_unit_idx on public.court_hours (unit_id);
create index court_hours_court_idx on public.court_hours (court_id);

-- ---------------------------------------------------------------------------
-- court_rates: price rules per hour, effective-dated. The booking copies the result (snapshot).
-- ---------------------------------------------------------------------------
create table public.court_rates (
  id            text collate "C" primary key default core.ulid(),
  org_id        text not null references public.orgs (id) on delete restrict,
  unit_id       text collate "C" references public.org_units (id) on delete restrict,
  court_id      text collate "C" references public.courts (id) on delete restrict,
  weekday       smallint constraint court_rates_weekday_chk check (weekday is null or weekday between 0 and 6),
  from_time     time not null default '00:00',
  to_time       time not null default '23:59:59',
  rate_per_hour numeric(12, 2) not null constraint court_rates_rate_chk check (rate_per_hour >= 0),
  valid_from    date not null,
  valid_to      date,
  created_at    timestamptz not null default now(),
  created_by    text,
  updated_at    timestamptz not null default now(),
  updated_by    text,
  version       integer not null default 1,
  deleted_at    timestamptz,
  deleted_by    text,
  delete_reason text,
  meta          jsonb not null default '{}'::jsonb,
  constraint court_rates_time_chk check (to_time > from_time),
  constraint court_rates_valid_chk check (valid_to is null or valid_to >= valid_from)
);
comment on table public.court_rates is 'class: master. permissions: courts.manage. Never edited in place once used: add a new row with a new valid_from. The most specific matching rule wins (court, then weekday).';
create index court_rates_org_idx on public.court_rates (org_id);
create index court_rates_unit_idx on public.court_rates (unit_id);
create index court_rates_court_idx on public.court_rates (court_id);

-- ---------------------------------------------------------------------------
-- court_blackouts: times when a court (or all courts) cannot be booked.
-- ---------------------------------------------------------------------------
create table public.court_blackouts (
  id            text collate "C" primary key default core.ulid(),
  org_id        text not null references public.orgs (id) on delete restrict,
  unit_id       text collate "C" references public.org_units (id) on delete restrict,
  court_id      text collate "C" references public.courts (id) on delete restrict,
  during        tstzrange not null,
  reason        text not null constraint court_blackouts_reason_chk check (length(btrim(reason)) > 0),
  created_at    timestamptz not null default now(),
  created_by    text,
  updated_at    timestamptz not null default now(),
  updated_by    text,
  version       integer not null default 1,
  deleted_at    timestamptz,
  deleted_by    text,
  delete_reason text,
  meta          jsonb not null default '{}'::jsonb,
  constraint court_blackouts_range_chk check (
    not isempty(during) and lower(during) is not null and upper(during) is not null
    and lower_inc(during) and not upper_inc(during))
);
comment on table public.court_blackouts is 'class: master. permissions: courts.manage. Half-open range [from, to).';
create index court_blackouts_org_idx on public.court_blackouts (org_id);
create index court_blackouts_unit_idx on public.court_blackouts (unit_id);
create index court_blackouts_court_idx on public.court_blackouts (court_id);
create index court_blackouts_during_idx on public.court_blackouts using gist (during) where deleted_at is null;

-- ---------------------------------------------------------------------------
-- bookings. class: document.
-- Status machine: pending_approval -> confirmed | rejected | expired | cancelled
--                 confirmed -> checked_in | cancelled | no_show;  checked_in -> completed.
-- ---------------------------------------------------------------------------
create table public.bookings (
  id                     text collate "C" primary key default core.ulid(),
  org_id                 text not null references public.orgs (id) on delete restrict,
  unit_id                text collate "C" references public.org_units (id) on delete restrict,
  doc_no                 text not null,
  court_id               text collate "C" not null references public.courts (id) on delete restrict,
  requested_by_member_id text collate "C" not null references public.members (id) on delete restrict,
  during                 tstzrange not null,
  status                 text not null default 'pending_approval'
                         constraint bookings_status_chk check (status in
                           ('pending_approval', 'confirmed', 'checked_in', 'completed', 'rejected', 'cancelled', 'no_show', 'expired')),
  status_reason          text,
  payload_hash           text not null constraint bookings_hash_chk check (payload_hash ~ '^[0-9a-f]{64}$'),
  rate_snapshot          numeric(12, 2) not null constraint bookings_rate_chk check (rate_snapshot >= 0),
  price_snapshot         numeric(12, 2) not null constraint bookings_price_chk check (price_snapshot >= 0),
  court_name_snapshot    text not null,
  expires_at             timestamptz,
  approved_at            timestamptz,
  approved_by            text,
  cancelled_at           timestamptz,
  cancelled_by           text,
  cancel_reason          text,
  checked_in_at          timestamptz,
  checked_in_by          text,
  created_at             timestamptz not null default now(),
  created_by             text,
  updated_at             timestamptz not null default now(),
  updated_by             text,
  version                integer not null default 1,
  meta                   jsonb not null default '{}'::jsonb,
  constraint bookings_doc_no_uq unique (org_id, doc_no),
  constraint bookings_range_chk check (
    not isempty(during) and lower(during) is not null and upper(during) is not null
    and lower_inc(during) and not upper_inc(during)),
  constraint bookings_approved_chk check (status not in ('confirmed', 'checked_in', 'completed') or approved_at is not null),
  constraint bookings_cancelled_chk check (status <> 'cancelled' or cancelled_at is not null),
  constraint bookings_checked_in_chk check (status not in ('checked_in', 'completed') or checked_in_at is not null),
  -- The arbiter of concurrent requests: two live bookings of one court can never overlap.
  constraint bookings_no_double_booking_excl exclude using gist (court_id with =, during with &&)
    where (status in ('pending_approval', 'confirmed', 'checked_in'))
);
comment on table public.bookings is 'class: document. permissions: bookings.create, bookings.read_all, bookings.approve, bookings.cancel_any, bookings.checkin. Written by booking RPCs only. Price and court name are snapshots.';
create index bookings_org_idx on public.bookings (org_id);
create index bookings_unit_idx on public.bookings (unit_id);
create index bookings_court_idx on public.bookings (court_id);
create index bookings_member_idx on public.bookings (requested_by_member_id);
create index bookings_status_idx on public.bookings (org_id, status);
create index bookings_expiry_idx on public.bookings (expires_at) where status = 'pending_approval';
create index bookings_during_idx on public.bookings using gist (during);

-- doc_no (BK-YYYY-NNNNN, year in Asia/Manila) is filled here when the caller leaves it empty (NOT NULL is checked after this trigger); checks on insert.
create or replace function core.tg_bookings_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  yr integer := extract(year from (now() at time zone 'Asia/Manila'))::integer;
  court public.courts;
begin
  if new.status <> 'pending_approval' then
    raise exception 'a new booking starts as pending_approval' using errcode = '22023';
  end if;
  if not exists (select 1 from public.members m where m.id = new.requested_by_member_id
                 and m.status = 'active' and m.deleted_at is null) then
    raise exception 'only an active member can request a booking' using errcode = '22023';
  end if;
  select * into court from public.courts where id = new.court_id and deleted_at is null;
  if not found or court.status <> 'available' then
    raise exception 'the court is not available for booking' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.court_blackouts b
    where b.deleted_at is null and b.org_id = new.org_id
      and (b.court_id is null or b.court_id = new.court_id) and b.during && new.during
  ) then
    raise exception 'the court is closed during that time' using errcode = '22023';
  end if;
  if new.doc_no is null or new.doc_no = '' then
    new.doc_no := format('BK-%s-%s', yr, lpad(core.next_number(new.org_id, null, 'booking-' || yr)::text, 5, '0'));
  end if;
  return new;
end $$;
revoke all on function core.tg_bookings_insert() from public, anon, authenticated;
create trigger a2_bookings_insert before insert on public.bookings
  for each row execute function core.tg_bookings_insert();

-- Status machine and frozen fields.
create or replace function core.tg_bookings_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (old.doc_no, old.court_id, old.requested_by_member_id, old.during, old.payload_hash,
      old.rate_snapshot, old.price_snapshot, old.court_name_snapshot)
     is distinct from
     (new.doc_no, new.court_id, new.requested_by_member_id, new.during, new.payload_hash,
      new.rate_snapshot, new.price_snapshot, new.court_name_snapshot) then
    raise exception 'a booking''s court, time, requester, number, price and hash cannot change; cancel it and book again' using errcode = '42501';
  end if;
  if new.status <> old.status and not (
       (old.status = 'pending_approval' and new.status in ('confirmed', 'rejected', 'expired', 'cancelled'))
    or (old.status = 'confirmed' and new.status in ('checked_in', 'cancelled', 'no_show'))
    or (old.status = 'checked_in' and new.status = 'completed')
  ) then
    raise exception 'booking status cannot change from % to %', old.status, new.status using errcode = '22023';
  end if;
  return new;
end $$;
create trigger c2_bookings_update before update on public.bookings
  for each row execute function core.tg_bookings_update();

-- ---------------------------------------------------------------------------
-- booking_events: append-only status history, written by a trigger on bookings.
-- ---------------------------------------------------------------------------
create table public.booking_events (
  id          text collate "C" primary key default core.ulid(),
  org_id      text not null references public.orgs (id) on delete restrict,
  unit_id     text collate "C" references public.org_units (id) on delete restrict,
  booking_id  text collate "C" not null references public.bookings (id) on delete restrict,
  from_status text,
  to_status   text not null,
  reason      text,
  occurred_at timestamptz not null default now(),
  created_at  timestamptz not null default now(),
  created_by  text,
  updated_at  timestamptz not null default now(),
  updated_by  text,
  version     integer not null default 1,
  meta        jsonb not null default '{}'::jsonb
);
comment on table public.booking_events is 'class: ledger (log, append-only). created_by is the actor.';
create index booking_events_org_idx on public.booking_events (org_id);
create index booking_events_unit_idx on public.booking_events (unit_id);
create index booking_events_booking_idx on public.booking_events (booking_id, occurred_at desc);

create or replace function core.tg_bookings_log() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    insert into public.booking_events (org_id, unit_id, booking_id, from_status, to_status, reason)
    values (new.org_id, new.unit_id, new.id, null, new.status, new.status_reason);
  elsif new.status is distinct from old.status then
    insert into public.booking_events (org_id, unit_id, booking_id, from_status, to_status, reason)
    values (new.org_id, new.unit_id, new.id, old.status, new.status, coalesce(new.cancel_reason, new.status_reason));
  end if;
  return null;
end $$;
revoke all on function core.tg_bookings_log() from public, anon, authenticated;
create trigger y_bookings_log after insert or update on public.bookings
  for each row execute function core.tg_bookings_log();

-- ---------------------------------------------------------------------------
-- booking_participants: who plays. class: document (immutable once added).
-- ---------------------------------------------------------------------------
create table public.booking_participants (
  id         text collate "C" primary key default core.ulid(),
  org_id     text not null references public.orgs (id) on delete restrict,
  unit_id    text collate "C" references public.org_units (id) on delete restrict,
  booking_id text collate "C" not null references public.bookings (id) on delete restrict,
  member_id  text collate "C" not null references public.members (id) on delete restrict,
  created_at timestamptz not null default now(),
  created_by text,
  updated_at timestamptz not null default now(),
  updated_by text,
  version    integer not null default 1,
  meta       jsonb not null default '{}'::jsonb,
  constraint booking_participants_uq unique (booking_id, member_id)
);
comment on table public.booking_participants is 'class: document. Written by booking RPCs only. Every participant is an active member.';
create index booking_participants_org_idx on public.booking_participants (org_id);
create index booking_participants_unit_idx on public.booking_participants (unit_id);
create index booking_participants_member_idx on public.booking_participants (member_id);

create or replace function core.tg_participants_check() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.members m where m.id = new.member_id and m.status = 'active' and m.deleted_at is null) then
    raise exception 'every participant must be an active member' using errcode = '22023';
  end if;
  return new;
end $$;
revoke all on function core.tg_participants_check() from public, anon, authenticated;
create trigger a2_participants_check before insert on public.booking_participants
  for each row execute function core.tg_participants_check();

create or replace function core.tg_participants_frozen() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'a participant row cannot be changed; the booking RPCs add and cancel bookings instead' using errcode = '42501';
end $$;
create trigger c2_participants_frozen before update on public.booking_participants
  for each row execute function core.tg_participants_frozen();

-- True when the caller requested the booking or plays in it.
create or replace function core.is_booking_party(p_booking_id text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.bookings b
    where b.id = p_booking_id and core.is_own_member(b.requested_by_member_id)
  ) or exists (
    select 1 from public.booking_participants p
    where p.booking_id = p_booking_id and core.is_own_member(p.member_id)
  )
$$;
revoke all on function core.is_booking_party(text) from public, anon;
grant execute on function core.is_booking_party(text) to authenticated, service_role;

select core.attach_standard('public.courts', 'master');
select core.attach_standard('public.court_hours', 'master');
select core.attach_standard('public.court_rates', 'master');
select core.attach_standard('public.court_blackouts', 'master');
select core.attach_standard('public.bookings', 'document');
select core.attach_standard('public.booking_events', 'ledger');
select core.attach_standard('public.booking_participants', 'document');

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.courts enable row level security;
alter table public.court_hours enable row level security;
alter table public.court_rates enable row level security;
alter table public.court_blackouts enable row level security;
alter table public.bookings enable row level security;
alter table public.booking_events enable row level security;
alter table public.booking_participants enable row level security;

do $$
declare t text;
begin
  foreach t in array array['courts', 'court_hours', 'court_rates', 'court_blackouts'] loop
    execute format('create policy %I on public.%I for select to authenticated using (core.is_org_member(org_id))', t || '_select', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (core.has_permission(org_id, null, ''courts.manage''))', t || '_insert', t);
    execute format('create policy %I on public.%I for update to authenticated using (core.has_permission(org_id, null, ''courts.manage'')) with check (core.has_permission(org_id, null, ''courts.manage''))', t || '_update', t);
  end loop;
end $$;

create policy bookings_select on public.bookings for select to authenticated
  using (core.has_permission(org_id, null, 'bookings.read_all') or core.is_booking_party(id));
create policy booking_participants_select on public.booking_participants for select to authenticated
  using (core.has_permission(org_id, null, 'bookings.read_all') or core.is_booking_party(booking_id));
create policy booking_events_select on public.booking_events for select to authenticated
  using (core.has_permission(org_id, null, 'bookings.read_all') or core.is_booking_party(booking_id));

select core.grant_client_dml('public.courts', true, true);
select core.grant_client_dml('public.court_hours', true, true);
select core.grant_client_dml('public.court_rates', true, true);
select core.grant_client_dml('public.court_blackouts', true, true);
select core.grant_client_dml('public.bookings', false, false);
select core.grant_client_dml('public.booking_events', false, false);
select core.grant_client_dml('public.booking_participants', false, false);

grant select, insert, update on public.courts, public.court_hours, public.court_rates, public.court_blackouts,
  public.bookings to service_role;
grant select, insert on public.booking_events, public.booking_participants to service_role;

-- ---------------------------------------------------------------------------
-- What is taken, without showing who took it. Members call this to draw the availability grid.
-- The definer function reads bookings past RLS and returns only court, time range and kind.
-- ---------------------------------------------------------------------------
create or replace function core.court_availability(p_from timestamptz, p_to timestamptz)
returns table (court_id text, during tstzrange, kind text)
language plpgsql stable security definer set search_path = '' as $$
declare
  org text;
begin
  select m.org_id into org
  from public.profiles p join public.org_members m on m.profile_id = p.id
  where p.id = core.current_profile_id() and m.is_active and m.deleted_at is null
  limit 1;
  if org is null then return; end if;
  if p_to <= p_from or p_to - p_from > interval '62 days' then
    raise exception 'ask for at most 62 days, in order' using errcode = '22023';
  end if;
  return query
    select b.court_id, b.during, 'booked'::text
    from public.bookings b
    where b.org_id = org and b.status in ('pending_approval', 'confirmed', 'checked_in')
      and b.during && tstzrange(p_from, p_to, '[)')
    union all
    select x.court_id, x.during, 'closed'::text
    from public.court_blackouts x
    where x.org_id = org and x.deleted_at is null and x.during && tstzrange(p_from, p_to, '[)');
end $$;
revoke all on function core.court_availability(timestamptz, timestamptz) from public, anon;
grant execute on function core.court_availability(timestamptz, timestamptz) to authenticated, service_role;

create or replace function public.court_availability(p_from timestamptz, p_to timestamptz)
returns table (court_id text, during tstzrange, kind text)
language sql stable security invoker set search_path = '' as $$
  select * from core.court_availability(p_from, p_to)
$$;
revoke all on function public.court_availability(timestamptz, timestamptz) from public, anon;
grant execute on function public.court_availability(timestamptz, timestamptz) to authenticated;
