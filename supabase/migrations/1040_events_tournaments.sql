-- 1040_events_tournaments (PLAN 2.4, part 1 of 2; design: docs/CLUB_SCHEMA.md 4.4)
-- events, format_templates, scoring_rules, divisions, division_stages, registrations, entries, entry_members,
-- plus the generic entity_events status history. Part 2 (1050) adds draws, matches, games, scores, results.
-- Format templates and scoring rules are edited directly (events.manage / brackets.manage). Everything else
-- is a document: clients get SELECT only; the tournament RPCs (stage 6) create and move rows inside the
-- state machines below. Deviation: status history for these tables lives in one generic table,
-- entity_events (created_by is the actor), instead of one history table each.

select core.add_permission('divisions.manage', 'Create and edit divisions', array['manager']);
select core.add_permission('registrations.manage', 'Confirm, waitlist or reject registrations', array['manager']);
select core.add_permission('reports.read', 'View reports', array['manager']);

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

-- p_map is {"from_status": ["allowed", "to", "statuses"], ...}; anything else is refused.
create or replace function core.check_transition(p_what text, p_from text, p_to text, p_map jsonb) returns void
language plpgsql immutable set search_path = '' as $$
begin
  if p_to is distinct from p_from and not coalesce((p_map -> p_from) ? p_to, false) then
    raise exception '% status cannot change from % to %', p_what, p_from, p_to using errcode = '22023';
  end if;
end $$;
revoke all on function core.check_transition(text, text, text, jsonb) from public, anon, authenticated;

create or replace function core.stages_valid(s jsonb) returns boolean
language sql immutable parallel safe set search_path = '' as $$
  select coalesce(
    jsonb_typeof(s) = 'array' and jsonb_array_length(s) between 1 and 6
    and not exists (
      select 1 from jsonb_array_elements(s) e
      where jsonb_typeof(e) <> 'object'
         or e ->> 'stage_type' is null
         or e ->> 'stage_type' not in ('round_robin', 'single_elimination', 'pool_play', 'best_of_n_playoff', 'split_single_elimination')
         or (e ? 'config' and jsonb_typeof(e -> 'config') <> 'object')
    ), false)
$$;

create or replace function core.tiebreaks_valid(t text[]) returns boolean
language sql immutable parallel safe set search_path = '' as $$
  select coalesce(
    cardinality(t) between 1 and 6
    and not exists (select 1 from unnest(t) x where x not in ('match_wins', 'head_to_head', 'game_diff', 'point_diff', 'points_for', 'coin_toss'))
    and (select count(distinct x) from unnest(t) x) = cardinality(t), false)
$$;
revoke all on function core.stages_valid(jsonb), core.tiebreaks_valid(text[]) from public, anon;
grant execute on function core.stages_valid(jsonb), core.tiebreaks_valid(text[]) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- entity_events: append-only status history for events, divisions, stages, registrations and matches.
-- ---------------------------------------------------------------------------
create table public.entity_events (
  id          text collate "C" primary key default core.ulid(),
  org_id      text not null references public.orgs (id) on delete restrict,
  unit_id     text collate "C" references public.org_units (id) on delete restrict,
  entity_type text not null constraint entity_events_type_chk check (entity_type in ('event', 'division', 'division_stage', 'registration', 'match')),
  entity_id   text collate "C" not null,
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
comment on table public.entity_events is 'class: ledger (log, append-only). permissions: events.manage. created_by is the actor.';
create index entity_events_org_idx on public.entity_events (org_id);
create index entity_events_unit_idx on public.entity_events (unit_id);
create index entity_events_entity_idx on public.entity_events (entity_type, entity_id, occurred_at desc);

create or replace function core.tg_log_status() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  reason text := coalesce(to_jsonb(new) ->> 'cancel_reason', to_jsonb(new) ->> 'status_reason');
begin
  if tg_op = 'INSERT' then
    insert into public.entity_events (org_id, unit_id, entity_type, entity_id, from_status, to_status, reason)
    values (new.org_id, new.unit_id, tg_argv[0], new.id, null, new.status, reason);
  elsif new.status is distinct from old.status then
    insert into public.entity_events (org_id, unit_id, entity_type, entity_id, from_status, to_status, reason)
    values (new.org_id, new.unit_id, tg_argv[0], new.id, old.status, new.status, reason);
  end if;
  return null;
end $$;
revoke all on function core.tg_log_status() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- events. class: document.
-- draft -> registration_open -> registration_closed -> drawn -> in_progress -> completed; cancel before completed.
-- ---------------------------------------------------------------------------
create table public.events (
  id                     text collate "C" primary key default core.ulid(),
  org_id                 text not null references public.orgs (id) on delete restrict,
  unit_id                text collate "C" references public.org_units (id) on delete restrict,
  doc_no                 text not null,
  name                   text not null constraint events_name_chk check (length(btrim(name)) > 0),
  starts_on              date not null,
  ends_on                date not null,
  location               text,
  status                 text not null default 'draft'
                         constraint events_status_chk check (status in
                           ('draft', 'registration_open', 'registration_closed', 'drawn', 'in_progress', 'completed', 'cancelled')),
  status_reason          text,
  registration_opens_at  timestamptz,
  registration_closes_at timestamptz,
  fee                    numeric(12, 2) not null default 0 constraint events_fee_chk check (fee >= 0),
  settings               jsonb not null default '{}'::jsonb constraint events_settings_chk check (jsonb_typeof(settings) = 'object'),
  payload_hash           text not null constraint events_hash_chk check (payload_hash ~ '^[0-9a-f]{64}$'),
  cancelled_at           timestamptz,
  cancelled_by           text,
  cancel_reason          text,
  created_at             timestamptz not null default now(),
  created_by             text,
  updated_at             timestamptz not null default now(),
  updated_by             text,
  version                integer not null default 1,
  meta                   jsonb not null default '{}'::jsonb,
  constraint events_doc_no_uq unique (org_id, doc_no),
  constraint events_dates_chk check (ends_on >= starts_on),
  constraint events_window_chk check (registration_closes_at is null or registration_opens_at is null or registration_closes_at > registration_opens_at),
  constraint events_cancelled_chk check (status <> 'cancelled' or (cancelled_at is not null and length(btrim(coalesce(cancel_reason, ''))) > 0))
);
comment on table public.events is 'class: document. permissions: events.manage, events.register. Written by tournament RPCs only. Drafts are visible to staff only.';
create index events_org_idx on public.events (org_id);
create index events_unit_idx on public.events (unit_id);
create index events_status_idx on public.events (org_id, status, starts_on);

create or replace function core.tg_events_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  yr integer := extract(year from (now() at time zone 'Asia/Manila'))::integer;
begin
  if new.status <> 'draft' then
    raise exception 'a new event starts as a draft' using errcode = '22023';
  end if;
  if new.doc_no is null or new.doc_no = '' then
    new.doc_no := format('EV-%s-%s', yr, lpad(core.next_number(new.org_id, null, 'event-' || yr)::text, 5, '0'));
  end if;
  return new;
end $$;
revoke all on function core.tg_events_insert() from public, anon, authenticated;
create trigger a2_events_insert before insert on public.events
  for each row execute function core.tg_events_insert();

create or replace function core.tg_events_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (old.doc_no, old.payload_hash) is distinct from (new.doc_no, new.payload_hash) then
    raise exception 'an event''s number and hash cannot change' using errcode = '42501';
  end if;
  perform core.check_transition('event', old.status, new.status, '{
    "draft": ["registration_open", "cancelled"],
    "registration_open": ["registration_closed", "cancelled"],
    "registration_closed": ["registration_open", "drawn", "cancelled"],
    "drawn": ["in_progress", "cancelled"],
    "in_progress": ["completed", "cancelled"]
  }'::jsonb);
  return new;
end $$;
create trigger c2_events_update before update on public.events
  for each row execute function core.tg_events_update();
create trigger y_events_log after insert or update on public.events
  for each row execute function core.tg_log_status('event');

-- ---------------------------------------------------------------------------
-- format_templates: reusable stage pipelines. class: master. permissions: brackets.manage
-- ---------------------------------------------------------------------------
create table public.format_templates (
  id               text collate "C" primary key default core.ulid(),
  org_id           text not null references public.orgs (id) on delete restrict,
  unit_id          text collate "C" references public.org_units (id) on delete restrict,
  name             text not null constraint format_templates_name_chk check (length(btrim(name)) > 0),
  description      text,
  stages           jsonb not null constraint format_templates_stages_chk check (core.stages_valid(stages)),
  template_version integer not null default 1 constraint format_templates_tver_chk check (template_version >= 1),
  is_active        boolean not null default true,
  created_at       timestamptz not null default now(),
  created_by       text,
  updated_at       timestamptz not null default now(),
  updated_by       text,
  version          integer not null default 1,
  deleted_at       timestamptz,
  deleted_by       text,
  delete_reason    text,
  meta             jsonb not null default '{}'::jsonb
);
comment on table public.format_templates is 'class: master. permissions: brackets.manage. A division copies the stages at creation; later edits never change existing divisions.';
create index format_templates_org_idx on public.format_templates (org_id);
create index format_templates_unit_idx on public.format_templates (unit_id);
create unique index format_templates_name_active_uq on public.format_templates (org_id, lower(name)) where deleted_at is null;

-- ---------------------------------------------------------------------------
-- scoring_rules: how a match is scored. class: master. permissions: events.manage
-- ---------------------------------------------------------------------------
create table public.scoring_rules (
  id              text collate "C" primary key default core.ulid(),
  org_id          text not null references public.orgs (id) on delete restrict,
  unit_id         text collate "C" references public.org_units (id) on delete restrict,
  name            text not null constraint scoring_rules_name_chk check (length(btrim(name)) > 0),
  games_to_win    smallint not null default 1 constraint scoring_rules_games_chk check (games_to_win between 1 and 5),
  points_per_game smallint not null default 11 constraint scoring_rules_points_chk check (points_per_game between 1 and 99),
  win_by          smallint not null default 2 constraint scoring_rules_winby_chk check (win_by between 1 and 5),
  point_cap       smallint constraint scoring_rules_cap_chk check (point_cap is null or point_cap >= points_per_game),
  forfeit_score   smallint not null default 11 constraint scoring_rules_forfeit_chk check (forfeit_score between 0 and 99),
  tiebreak_order  text[] not null default array['match_wins', 'head_to_head', 'point_diff']
                  constraint scoring_rules_tiebreak_chk check (core.tiebreaks_valid(tiebreak_order)),
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  created_by      text,
  updated_at      timestamptz not null default now(),
  updated_by      text,
  version         integer not null default 1,
  deleted_at      timestamptz,
  deleted_by      text,
  delete_reason   text,
  meta            jsonb not null default '{}'::jsonb
);
comment on table public.scoring_rules is 'class: master. permissions: events.manage. Copied into divisions and stages as snapshots.';
create index scoring_rules_org_idx on public.scoring_rules (org_id);
create index scoring_rules_unit_idx on public.scoring_rules (unit_id);
create unique index scoring_rules_name_active_uq on public.scoring_rules (org_id, lower(name)) where deleted_at is null;

-- ---------------------------------------------------------------------------
-- divisions. class: document.   open -> drawn -> in_progress -> finalized (once);  cancel before finalized.
-- ---------------------------------------------------------------------------
create table public.divisions (
  id                text collate "C" primary key default core.ulid(),
  org_id            text not null references public.orgs (id) on delete restrict,
  unit_id           text collate "C" references public.org_units (id) on delete restrict,
  event_id          text collate "C" not null references public.events (id) on delete restrict,
  name              text not null constraint divisions_name_chk check (length(btrim(name)) > 0),
  category_id       text collate "C" not null references public.categories (id) on delete restrict,
  format            text not null constraint divisions_format_chk check (format in ('singles', 'doubles')),
  gender            text constraint divisions_gender_chk check (gender is null or gender in ('male', 'female', 'mixed')),
  age_group         text,
  min_rank_id       text collate "C" references public.ranks (id) on delete restrict,
  max_rank_id       text collate "C" references public.ranks (id) on delete restrict,
  status            text not null default 'open'
                    constraint divisions_status_chk check (status in ('open', 'drawn', 'in_progress', 'finalized', 'cancelled')),
  status_reason     text,
  max_entries       integer constraint divisions_max_entries_chk check (max_entries is null or max_entries >= 2),
  finalized_at      timestamptz,
  finalized_by      text,
  format_snapshot   jsonb not null constraint divisions_format_snap_chk check (core.stages_valid(format_snapshot)),
  scoring_snapshot  jsonb not null constraint divisions_scoring_snap_chk check (jsonb_typeof(scoring_snapshot) = 'object'),
  payload_hash      text not null constraint divisions_hash_chk check (payload_hash ~ '^[0-9a-f]{64}$'),
  cancelled_at      timestamptz,
  cancelled_by      text,
  cancel_reason     text,
  created_at        timestamptz not null default now(),
  created_by        text,
  updated_at        timestamptz not null default now(),
  updated_by        text,
  version           integer not null default 1,
  meta              jsonb not null default '{}'::jsonb,
  constraint divisions_finalized_chk check (status <> 'finalized' or finalized_at is not null),
  constraint divisions_cancelled_chk check (status <> 'cancelled' or (cancelled_at is not null and length(btrim(coalesce(cancel_reason, ''))) > 0))
);
comment on table public.divisions is 'class: document. permissions: divisions.manage, events.manage. The format and scoring are snapshots taken at creation.';
create index divisions_org_idx on public.divisions (org_id);
create index divisions_unit_idx on public.divisions (unit_id);
create index divisions_event_idx on public.divisions (event_id);
create index divisions_category_idx on public.divisions (category_id);
create index divisions_min_rank_idx on public.divisions (min_rank_id);
create index divisions_max_rank_idx on public.divisions (max_rank_id);
create unique index divisions_name_live_uq on public.divisions (event_id, lower(name)) where status <> 'cancelled';

create or replace function core.tg_divisions_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  ev public.events;
  lo public.ranks;
  hi public.ranks;
begin
  if new.status <> 'open' then
    raise exception 'a new division starts open' using errcode = '22023';
  end if;
  select * into ev from public.events where id = new.event_id;
  if not found or ev.org_id <> new.org_id or ev.status in ('completed', 'cancelled') then
    raise exception 'divisions can be added only to a live event' using errcode = '22023';
  end if;
  if new.min_rank_id is not null then select * into lo from public.ranks where id = new.min_rank_id; end if;
  if new.max_rank_id is not null then select * into hi from public.ranks where id = new.max_rank_id; end if;
  if (new.min_rank_id is not null or new.max_rank_id is not null) then
    if not exists (select 1 from public.rank_ladders l where l.category_id = new.category_id and l.deleted_at is null
                   and (lo.id is null or lo.ladder_id = l.id) and (hi.id is null or hi.ladder_id = l.id)) then
      raise exception 'the rank band must belong to the category''s ladder' using errcode = '22023';
    end if;
    if lo.id is not null and hi.id is not null and lo.sort_order > hi.sort_order then
      raise exception 'the minimum rank cannot be above the maximum rank' using errcode = '22023';
    end if;
  end if;
  return new;
end $$;
revoke all on function core.tg_divisions_insert() from public, anon, authenticated;
create trigger a2_divisions_insert before insert on public.divisions
  for each row execute function core.tg_divisions_insert();

create or replace function core.tg_divisions_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (old.event_id, old.category_id, old.format, old.format_snapshot, old.scoring_snapshot, old.payload_hash)
     is distinct from
     (new.event_id, new.category_id, new.format, new.format_snapshot, new.scoring_snapshot, new.payload_hash) then
    raise exception 'a division''s event, category, format, snapshots and hash cannot change' using errcode = '42501';
  end if;
  perform core.check_transition('division', old.status, new.status, '{
    "open": ["drawn", "cancelled"],
    "drawn": ["in_progress", "cancelled"],
    "in_progress": ["finalized", "cancelled"]
  }'::jsonb);
  return new;
end $$;
create trigger c2_divisions_update before update on public.divisions
  for each row execute function core.tg_divisions_update();
create trigger y_divisions_log after insert or update on public.divisions
  for each row execute function core.tg_log_status('division');

-- ---------------------------------------------------------------------------
-- division_stages: one row per stage of the division's format. class: document.
-- ---------------------------------------------------------------------------
create table public.division_stages (
  id                     text collate "C" primary key default core.ulid(),
  org_id                 text not null references public.orgs (id) on delete restrict,
  unit_id                text collate "C" references public.org_units (id) on delete restrict,
  division_id            text collate "C" not null references public.divisions (id) on delete restrict,
  stage_no               smallint not null constraint division_stages_no_chk check (stage_no between 1 and 6),
  stage_type             text not null constraint division_stages_type_chk check (stage_type in
                           ('round_robin', 'single_elimination', 'pool_play', 'best_of_n_playoff', 'split_single_elimination')),
  config                 jsonb not null default '{}'::jsonb constraint division_stages_config_chk check (jsonb_typeof(config) = 'object'),
  scoring_rule_snapshot  jsonb not null constraint division_stages_scoring_chk check (jsonb_typeof(scoring_rule_snapshot) = 'object'),
  status                 text not null default 'pending'
                         constraint division_stages_status_chk check (status in ('pending', 'drawn', 'in_progress', 'completed', 'cancelled')),
  status_reason          text,
  created_at             timestamptz not null default now(),
  created_by             text,
  updated_at             timestamptz not null default now(),
  updated_by             text,
  version                integer not null default 1,
  meta                   jsonb not null default '{}'::jsonb,
  constraint division_stages_no_uq unique (division_id, stage_no)
);
comment on table public.division_stages is 'class: document. permissions: brackets.manage. Created with the division from its format snapshot.';
create index division_stages_org_idx on public.division_stages (org_id);
create index division_stages_unit_idx on public.division_stages (unit_id);

create or replace function core.tg_stages_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (old.division_id, old.stage_no, old.stage_type) is distinct from (new.division_id, new.stage_no, new.stage_type) then
    raise exception 'a stage''s division, number and type cannot change' using errcode = '42501';
  end if;
  perform core.check_transition('stage', old.status, new.status, '{
    "pending": ["drawn", "cancelled"],
    "drawn": ["in_progress", "cancelled"],
    "in_progress": ["completed", "cancelled"]
  }'::jsonb);
  return new;
end $$;
create trigger c2_stages_update before update on public.division_stages
  for each row execute function core.tg_stages_update();
create trigger y_stages_log after insert or update on public.division_stages
  for each row execute function core.tg_log_status('division_stage');

-- ---------------------------------------------------------------------------
-- registrations. class: document.
-- requested -> confirmed | waitlisted | rejected | withdrawn;  confirmed -> withdrawn;  waitlisted -> confirmed | withdrawn
-- ---------------------------------------------------------------------------
create table public.registrations (
  id             text collate "C" primary key default core.ulid(),
  org_id         text not null references public.orgs (id) on delete restrict,
  unit_id        text collate "C" references public.org_units (id) on delete restrict,
  event_id       text collate "C" not null references public.events (id) on delete restrict,
  division_id    text collate "C" not null references public.divisions (id) on delete restrict,
  member_id      text collate "C" not null references public.members (id) on delete restrict,
  status         text not null default 'requested'
                 constraint registrations_status_chk check (status in ('requested', 'confirmed', 'waitlisted', 'withdrawn', 'rejected')),
  status_reason  text,
  fee_snapshot   numeric(12, 2) not null constraint registrations_fee_chk check (fee_snapshot >= 0),
  payload_hash   text not null constraint registrations_hash_chk check (payload_hash ~ '^[0-9a-f]{64}$'),
  created_at     timestamptz not null default now(),
  created_by     text,
  updated_at     timestamptz not null default now(),
  updated_by     text,
  version        integer not null default 1,
  meta           jsonb not null default '{}'::jsonb,
  constraint registrations_rejected_chk check (status not in ('rejected', 'withdrawn') or length(btrim(coalesce(status_reason, ''))) > 0)
);
comment on table public.registrations is 'class: document. permissions: events.register, events.approve_registration, registrations.manage. Eligibility is checked by the registration RPC.';
create index registrations_org_idx on public.registrations (org_id);
create index registrations_unit_idx on public.registrations (unit_id);
create index registrations_event_idx on public.registrations (event_id);
create index registrations_member_idx on public.registrations (member_id);
create index registrations_division_status_idx on public.registrations (division_id, status);
create unique index registrations_live_uq on public.registrations (division_id, member_id)
  where status in ('requested', 'confirmed', 'waitlisted');

create or replace function core.tg_registrations_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  dv public.divisions;
begin
  if new.status <> 'requested' then
    raise exception 'a new registration starts as requested' using errcode = '22023';
  end if;
  select * into dv from public.divisions where id = new.division_id;
  if not found or dv.event_id <> new.event_id or dv.org_id <> new.org_id then
    raise exception 'the division does not belong to that event' using errcode = '22023';
  end if;
  if dv.status <> 'open' then
    raise exception 'the division is not open for registration' using errcode = '22023';
  end if;
  if not exists (select 1 from public.members m where m.id = new.member_id and m.status = 'active' and m.deleted_at is null) then
    raise exception 'only an active member can register' using errcode = '22023';
  end if;
  return new;
end $$;
revoke all on function core.tg_registrations_insert() from public, anon, authenticated;
create trigger a2_registrations_insert before insert on public.registrations
  for each row execute function core.tg_registrations_insert();

create or replace function core.tg_registrations_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (old.event_id, old.division_id, old.member_id, old.fee_snapshot, old.payload_hash)
     is distinct from (new.event_id, new.division_id, new.member_id, new.fee_snapshot, new.payload_hash) then
    raise exception 'a registration''s event, division, member, fee and hash cannot change' using errcode = '42501';
  end if;
  perform core.check_transition('registration', old.status, new.status, '{
    "requested": ["confirmed", "waitlisted", "rejected", "withdrawn"],
    "confirmed": ["withdrawn"],
    "waitlisted": ["confirmed", "withdrawn"]
  }'::jsonb);
  return new;
end $$;
create trigger c2_registrations_update before update on public.registrations
  for each row execute function core.tg_registrations_update();
create trigger y_registrations_log after insert or update on public.registrations
  for each row execute function core.tg_log_status('registration');

-- ---------------------------------------------------------------------------
-- entries: the competing unit in a division (one member, or a pair). class: document.
-- ---------------------------------------------------------------------------
create table public.entries (
  id              text collate "C" primary key default core.ulid(),
  org_id          text not null references public.orgs (id) on delete restrict,
  unit_id         text collate "C" references public.org_units (id) on delete restrict,
  division_id     text collate "C" not null references public.divisions (id) on delete restrict,
  registration_id text collate "C" not null references public.registrations (id) on delete restrict,
  seed            integer constraint entries_seed_chk check (seed is null or seed >= 1),
  status          text not null default 'active' constraint entries_status_chk check (status in ('active', 'withdrawn', 'disqualified')),
  created_at      timestamptz not null default now(),
  created_by      text,
  updated_at      timestamptz not null default now(),
  updated_by      text,
  version         integer not null default 1,
  meta            jsonb not null default '{}'::jsonb,
  constraint entries_registration_uq unique (registration_id)
);
comment on table public.entries is 'class: document. permissions: draws.run, registrations.manage. A doubles entry has two entry_members.';
create index entries_org_idx on public.entries (org_id);
create index entries_unit_idx on public.entries (unit_id);
create index entries_division_idx on public.entries (division_id);
create unique index entries_seed_live_uq on public.entries (division_id, seed) where seed is not null and status = 'active';

create or replace function core.tg_entries_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (
    select 1 from public.registrations r
    where r.id = new.registration_id and r.division_id = new.division_id and r.org_id = new.org_id and r.status = 'confirmed'
  ) then
    raise exception 'an entry needs a confirmed registration in the same division' using errcode = '22023';
  end if;
  return new;
end $$;
revoke all on function core.tg_entries_insert() from public, anon, authenticated;
create trigger a2_entries_insert before insert on public.entries
  for each row execute function core.tg_entries_insert();

create or replace function core.tg_entries_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (old.division_id, old.registration_id) is distinct from (new.division_id, new.registration_id) then
    raise exception 'an entry''s division and registration cannot change' using errcode = '42501';
  end if;
  if old.status <> 'active' and new.status <> old.status then
    raise exception 'a withdrawn or disqualified entry cannot be reactivated' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger c2_entries_update before update on public.entries
  for each row execute function core.tg_entries_update();

-- ---------------------------------------------------------------------------
-- entry_members: who is in an entry. division_id is copied from the entry by a trigger.
-- ---------------------------------------------------------------------------
create table public.entry_members (
  id          text collate "C" primary key default core.ulid(),
  org_id      text not null references public.orgs (id) on delete restrict,
  unit_id     text collate "C" references public.org_units (id) on delete restrict,
  entry_id    text collate "C" not null references public.entries (id) on delete restrict,
  division_id text collate "C" not null references public.divisions (id) on delete restrict,
  member_id   text collate "C" not null references public.members (id) on delete restrict,
  created_at  timestamptz not null default now(),
  created_by  text,
  updated_at  timestamptz not null default now(),
  updated_by  text,
  version     integer not null default 1,
  meta        jsonb not null default '{}'::jsonb,
  constraint entry_members_uq unique (entry_id, member_id)
);
comment on table public.entry_members is 'class: document. A member is in at most one active entry per division; a singles entry has one member, a doubles entry two.';
create index entry_members_org_idx on public.entry_members (org_id);
create index entry_members_unit_idx on public.entry_members (unit_id);
create index entry_members_division_idx on public.entry_members (division_id, member_id);
create index entry_members_member_idx on public.entry_members (member_id);

create or replace function core.tg_entry_members_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  en public.entries;
  fmt text;
  n integer;
  lim integer := 1;
begin
  select * into en from public.entries where id = new.entry_id;
  if not found or en.org_id <> new.org_id then
    raise exception 'the entry does not exist' using errcode = '22023';
  end if;
  if en.status <> 'active' then
    raise exception 'members can be added only to an active entry' using errcode = '22023';
  end if;
  new.division_id := en.division_id;
  select d.format into fmt from public.divisions d where d.id = en.division_id;
  select count(*) into n from public.entry_members where entry_id = new.entry_id;
  if fmt = 'doubles' then lim := 2; end if;
  if n >= lim then
    raise exception 'a % entry has at most % member(s)', fmt, lim using errcode = '22023';
  end if;
  if not exists (select 1 from public.members m where m.id = new.member_id and m.status = 'active' and m.deleted_at is null) then
    raise exception 'every entry member must be an active member' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.entry_members x join public.entries e on e.id = x.entry_id
    where x.division_id = en.division_id and x.member_id = new.member_id and e.status = 'active'
  ) then
    raise exception 'the member is already in an active entry of this division' using errcode = '23505';
  end if;
  return new;
end $$;
revoke all on function core.tg_entry_members_insert() from public, anon, authenticated;
create trigger a2_entry_members_insert before insert on public.entry_members
  for each row execute function core.tg_entry_members_insert();

create or replace function core.tg_entry_members_frozen() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'an entry member row cannot be changed' using errcode = '42501';
end $$;
create trigger c2_entry_members_frozen before update on public.entry_members
  for each row execute function core.tg_entry_members_frozen();

select core.attach_standard('public.entity_events', 'ledger');
select core.attach_standard('public.events', 'document');
select core.attach_standard('public.format_templates', 'master');
select core.attach_standard('public.scoring_rules', 'master');
select core.attach_standard('public.divisions', 'document');
select core.attach_standard('public.division_stages', 'document');
select core.attach_standard('public.registrations', 'document');
select core.attach_standard('public.entries', 'document');
select core.attach_standard('public.entry_members', 'document');

-- ---------------------------------------------------------------------------
-- Later steps point back at these tables: rank movement and event payments.
-- ---------------------------------------------------------------------------
alter table public.rank_history
  add constraint rank_history_division_fk foreign key (division_id) references public.divisions (id) on delete restrict,
  add constraint rank_history_event_fk foreign key (event_id) references public.events (id) on delete restrict;
alter table public.member_ranks
  add constraint member_ranks_division_fk foreign key (source_division_id) references public.divisions (id) on delete restrict;
create index member_ranks_division_idx on public.member_ranks (source_division_id);

-- A payment for an event registration must point at a real registration (1030 checked bookings only).
create or replace function core.tg_payments_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  yr integer := extract(year from (now() at time zone 'Asia/Manila'))::integer;
begin
  if new.status <> 'submitted' then
    raise exception 'a new payment starts as submitted' using errcode = '22023';
  end if;
  if not exists (select 1 from public.members m where m.id = new.payer_member_id and m.status = 'active' and m.deleted_at is null) then
    raise exception 'only an active member can submit a payment' using errcode = '22023';
  end if;
  if new.source_type = 'booking' and not exists (
    select 1 from public.bookings b where b.id = new.source_id and b.org_id = new.org_id
  ) then
    raise exception 'the booking being paid does not exist' using errcode = '22023';
  end if;
  if new.source_type = 'event_registration' and not exists (
    select 1 from public.registrations r where r.id = new.source_id and r.org_id = new.org_id
  ) then
    raise exception 'the registration being paid does not exist' using errcode = '22023';
  end if;
  if new.doc_no is null or new.doc_no = '' then
    new.doc_no := format('PAY-%s-%s', yr, lpad(core.next_number(new.org_id, null, 'payment-' || yr)::text, 5, '0'));
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- RLS. Members read published events and their divisions; registrations are private to the registrant.
-- ---------------------------------------------------------------------------
alter table public.entity_events enable row level security;
alter table public.events enable row level security;
alter table public.format_templates enable row level security;
alter table public.scoring_rules enable row level security;
alter table public.divisions enable row level security;
alter table public.division_stages enable row level security;
alter table public.registrations enable row level security;
alter table public.entries enable row level security;
alter table public.entry_members enable row level security;

create policy entity_events_select on public.entity_events for select to authenticated
  using (core.has_permission(org_id, null, 'events.manage'));

create policy events_select on public.events for select to authenticated
  using ((status <> 'draft' and core.is_org_member(org_id)) or core.has_permission(org_id, null, 'events.manage'));

create policy format_templates_select on public.format_templates for select to authenticated using (core.is_org_member(org_id));
create policy format_templates_insert on public.format_templates for insert to authenticated with check (core.has_permission(org_id, null, 'brackets.manage'));
create policy format_templates_update on public.format_templates for update to authenticated
  using (core.has_permission(org_id, null, 'brackets.manage')) with check (core.has_permission(org_id, null, 'brackets.manage'));

create policy scoring_rules_select on public.scoring_rules for select to authenticated using (core.is_org_member(org_id));
create policy scoring_rules_insert on public.scoring_rules for insert to authenticated with check (core.has_permission(org_id, null, 'events.manage'));
create policy scoring_rules_update on public.scoring_rules for update to authenticated
  using (core.has_permission(org_id, null, 'events.manage')) with check (core.has_permission(org_id, null, 'events.manage'));

-- Whoever can see the event can see its divisions and stages (the events policy decides).
create policy divisions_select on public.divisions for select to authenticated
  using (exists (select 1 from public.events e where e.id = event_id));
create policy division_stages_select on public.division_stages for select to authenticated
  using (exists (select 1 from public.divisions d where d.id = division_id));

create policy registrations_select on public.registrations for select to authenticated
  using (
    core.is_own_member(member_id)
    or core.has_permission(org_id, null, 'events.manage')
    or core.has_permission(org_id, null, 'registrations.manage')
    or core.has_permission(org_id, null, 'events.approve_registration')
  );

-- Entries are visible once the draw has happened (before that, staff only): they carry ids, not names.
create policy entries_select on public.entries for select to authenticated
  using (
    core.has_permission(org_id, null, 'registrations.manage') or core.has_permission(org_id, null, 'events.manage')
    or exists (select 1 from public.divisions d where d.id = division_id and d.status in ('drawn', 'in_progress', 'finalized'))
  );
create policy entry_members_select on public.entry_members for select to authenticated
  using (
    core.has_permission(org_id, null, 'registrations.manage') or core.has_permission(org_id, null, 'events.manage')
    or core.is_own_member(member_id)
    or exists (select 1 from public.divisions d where d.id = division_id and d.status in ('drawn', 'in_progress', 'finalized'))
  );

select core.grant_client_dml('public.entity_events', false, false);
select core.grant_client_dml('public.events', false, false);
select core.grant_client_dml('public.format_templates', true, true);
select core.grant_client_dml('public.scoring_rules', true, true);
select core.grant_client_dml('public.divisions', false, false);
select core.grant_client_dml('public.division_stages', false, false);
select core.grant_client_dml('public.registrations', false, false);
select core.grant_client_dml('public.entries', false, false);
select core.grant_client_dml('public.entry_members', false, false);

grant select, insert, update on public.events, public.format_templates, public.scoring_rules, public.divisions,
  public.division_stages, public.registrations, public.entries to service_role;
grant select, insert on public.entity_events, public.entry_members to service_role;
