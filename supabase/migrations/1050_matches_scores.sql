-- 1050_matches_scores (PLAN 2.4, part 2 of 2; design: docs/CLUB_SCHEMA.md 4.4)
-- draws, matches, match_games, score_events, division_results.
-- All are written by the tournament RPCs (stage 6): clients get SELECT only. Standings are computed on the
-- server from finalized matches, never stored by clients. Deviation from the design: a draw is superseded
-- by status (active -> superseded) and the replacement points back with replaces_draw_id, because a
-- partial unique index cannot hold two active rows for the moment between the two writes.

-- ---------------------------------------------------------------------------
-- draws: the seeded, reproducible draw for a stage. class: document.
-- ---------------------------------------------------------------------------
create table public.draws (
  id                 text collate "C" primary key default core.ulid(),
  org_id             text not null references public.orgs (id) on delete restrict,
  unit_id            text collate "C" references public.org_units (id) on delete restrict,
  division_stage_id  text collate "C" not null references public.division_stages (id) on delete restrict,
  seed               text not null constraint draws_seed_chk check (seed ~ '^[0-9a-f]{32,128}$'),
  entrant_snapshot   jsonb not null constraint draws_entrants_chk check (jsonb_typeof(entrant_snapshot) = 'array'),
  result             jsonb not null constraint draws_result_chk check (jsonb_typeof(result) in ('object', 'array')),
  status             text not null default 'active' constraint draws_status_chk check (status in ('active', 'superseded')),
  replaces_draw_id   text collate "C" references public.draws (id) on delete restrict,
  redo_reason        text,
  run_at             timestamptz not null default now(),
  created_at         timestamptz not null default now(),
  created_by         text,
  updated_at         timestamptz not null default now(),
  updated_by         text,
  version            integer not null default 1,
  meta               jsonb not null default '{}'::jsonb,
  constraint draws_redo_chk check ((replaces_draw_id is null) = (redo_reason is null)),
  constraint draws_not_self_chk check (replaces_draw_id is distinct from id)
);
comment on table public.draws is 'class: document. permissions: draws.run, draws.redo. The seed is stored so a draw can be reproduced; one active draw per stage, so a second run returns the first.';
create index draws_org_idx on public.draws (org_id);
create index draws_unit_idx on public.draws (unit_id);
create index draws_replaces_idx on public.draws (replaces_draw_id);
create unique index draws_active_uq on public.draws (division_stage_id) where status = 'active';
create index draws_stage_idx on public.draws (division_stage_id);

create or replace function core.tg_draws_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  st public.division_stages;
  prev public.draws;
begin
  if new.status <> 'active' then
    raise exception 'a new draw is active' using errcode = '22023';
  end if;
  select * into st from public.division_stages where id = new.division_stage_id;
  if not found or st.org_id <> new.org_id then
    raise exception 'the stage does not exist' using errcode = '22023';
  end if;
  if new.replaces_draw_id is null then
    if st.status <> 'pending' then
      raise exception 'the stage has already been drawn; redo the draw instead' using errcode = '22023';
    end if;
  else
    select * into prev from public.draws where id = new.replaces_draw_id;
    if not found or prev.division_stage_id <> new.division_stage_id then
      raise exception 'a redo must replace a draw of the same stage' using errcode = '22023';
    end if;
    if prev.status <> 'superseded' then
      raise exception 'supersede the old draw before recording its replacement' using errcode = '22023';
    end if;
    if st.status not in ('pending', 'drawn') then
      raise exception 'a stage in progress cannot be drawn again' using errcode = '22023';
    end if;
  end if;
  return new;
end $$;
revoke all on function core.tg_draws_insert() from public, anon, authenticated;
create trigger a2_draws_insert before insert on public.draws
  for each row execute function core.tg_draws_insert();

create or replace function core.tg_draws_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (old.division_stage_id, old.seed, old.entrant_snapshot, old.result, old.replaces_draw_id, old.redo_reason, old.run_at)
     is distinct from
     (new.division_stage_id, new.seed, new.entrant_snapshot, new.result, new.replaces_draw_id, new.redo_reason, new.run_at) then
    raise exception 'a draw cannot be edited; redo it' using errcode = '42501';
  end if;
  perform core.check_transition('draw', old.status, new.status, '{"active": ["superseded"]}'::jsonb);
  return new;
end $$;
create trigger c2_draws_update before update on public.draws
  for each row execute function core.tg_draws_update();

-- ---------------------------------------------------------------------------
-- matches. class: document.
-- scheduled -> in_progress | forfeited | cancelled | void;  in_progress -> completed | forfeited | void;
-- completed -> void;  forfeited -> void.  void and cancelled are final.
-- ---------------------------------------------------------------------------
create table public.matches (
  id                 text collate "C" primary key default core.ulid(),
  org_id             text not null references public.orgs (id) on delete restrict,
  unit_id            text collate "C" references public.org_units (id) on delete restrict,
  division_stage_id  text collate "C" not null references public.division_stages (id) on delete restrict,
  round_no           smallint not null constraint matches_round_chk check (round_no >= 1),
  match_no           smallint not null constraint matches_no_chk check (match_no >= 1),
  group_label        text constraint matches_group_chk check (group_label is null or group_label ~ '^[A-Z0-9]{1,3}$'),
  entry_a_id         text collate "C" references public.entries (id) on delete restrict,
  entry_b_id         text collate "C" references public.entries (id) on delete restrict,
  feeds_match_id     text collate "C" references public.matches (id) on delete restrict,
  slot               text constraint matches_slot_chk check (slot is null or slot in ('a', 'b')),
  court_id           text collate "C" references public.courts (id) on delete restrict,
  scheduled_at       timestamptz,
  referee_member_id  text collate "C" references public.members (id) on delete restrict,
  status             text not null default 'scheduled'
                     constraint matches_status_chk check (status in ('scheduled', 'in_progress', 'completed', 'forfeited', 'cancelled', 'void')),
  status_reason      text,
  winner_entry_id    text collate "C" references public.entries (id) on delete restrict,
  created_at         timestamptz not null default now(),
  created_by         text,
  updated_at         timestamptz not null default now(),
  updated_by         text,
  version            integer not null default 1,
  meta               jsonb not null default '{}'::jsonb,
  constraint matches_entries_differ_chk check (entry_a_id is distinct from entry_b_id or entry_a_id is null),
  constraint matches_feed_chk check ((feeds_match_id is null) = (slot is null)),
  constraint matches_winner_chk check (winner_entry_id is null or winner_entry_id in (entry_a_id, entry_b_id)),
  constraint matches_result_chk check (status not in ('completed', 'forfeited') or winner_entry_id is not null),
  constraint matches_not_self_feed_chk check (feeds_match_id is distinct from id)
);
comment on table public.matches is 'class: document. permissions: brackets.manage, scores.enter, scores.finalize, scores.correct. A correction voids the match and records a new one in its place.';
create index matches_org_idx on public.matches (org_id);
create index matches_unit_idx on public.matches (unit_id);
create index matches_stage_idx on public.matches (division_stage_id);
create index matches_entry_a_idx on public.matches (entry_a_id);
create index matches_entry_b_idx on public.matches (entry_b_id);
create index matches_feeds_idx on public.matches (feeds_match_id);
create index matches_court_idx on public.matches (court_id);
create index matches_referee_idx on public.matches (referee_member_id);
create index matches_winner_idx on public.matches (winner_entry_id);
create unique index matches_position_live_uq on public.matches (division_stage_id, round_no, match_no) where status <> 'void';

create or replace function core.tg_matches_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  st public.division_stages;
  feed public.matches;
  eid text;
begin
  if new.status <> 'scheduled' then
    raise exception 'a new match starts scheduled' using errcode = '22023';
  end if;
  select * into st from public.division_stages where id = new.division_stage_id;
  if not found or st.org_id <> new.org_id then
    raise exception 'the stage does not exist' using errcode = '22023';
  end if;
  foreach eid in array array[new.entry_a_id, new.entry_b_id] loop
    if eid is not null and not exists (
      select 1 from public.entries en where en.id = eid and en.division_id = st.division_id and en.status = 'active'
    ) then
      raise exception 'a match entry must be an active entry of the same division' using errcode = '22023';
    end if;
  end loop;
  if new.feeds_match_id is not null then
    select * into feed from public.matches where id = new.feeds_match_id;
    if not found or feed.division_stage_id <> new.division_stage_id then
      raise exception 'a match can feed only a match of the same stage' using errcode = '22023';
    end if;
  end if;
  if new.referee_member_id is not null and not exists (
    select 1 from public.members m where m.id = new.referee_member_id and m.status = 'active' and m.deleted_at is null
  ) then
    raise exception 'the referee must be an active member' using errcode = '22023';
  end if;
  return new;
end $$;
revoke all on function core.tg_matches_insert() from public, anon, authenticated;
create trigger a2_matches_insert before insert on public.matches
  for each row execute function core.tg_matches_insert();

create or replace function core.tg_matches_update() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  st public.division_stages;
begin
  if (old.division_stage_id, old.round_no, old.match_no, old.group_label, old.feeds_match_id, old.slot)
     is distinct from
     (new.division_stage_id, new.round_no, new.match_no, new.group_label, new.feeds_match_id, new.slot) then
    raise exception 'a match''s stage, position and feed cannot change' using errcode = '42501';
  end if;
  -- An opponent can be filled in once a feeder match finishes; a known opponent never changes.
  if (old.entry_a_id is not null and new.entry_a_id is distinct from old.entry_a_id)
     or (old.entry_b_id is not null and new.entry_b_id is distinct from old.entry_b_id) then
    raise exception 'a match''s opponents cannot change once set; void the match instead' using errcode = '42501';
  end if;
  if old.winner_entry_id is not null and new.winner_entry_id is distinct from old.winner_entry_id then
    raise exception 'a recorded winner cannot change; void the match instead' using errcode = '42501';
  end if;
  if new.winner_entry_id is not null and new.status not in ('completed', 'forfeited', 'void') then
    raise exception 'a winner is recorded only when the match is completed or forfeited' using errcode = '22023';
  end if;
  if (new.entry_a_id is distinct from old.entry_a_id or new.entry_b_id is distinct from old.entry_b_id) then
    select * into st from public.division_stages where id = new.division_stage_id;
    if exists (
      select 1 from (values (new.entry_a_id), (new.entry_b_id)) v(eid)
      where v.eid is not null and not exists (
        select 1 from public.entries en where en.id = v.eid and en.division_id = st.division_id and en.status = 'active')
    ) then
      raise exception 'a match entry must be an active entry of the same division' using errcode = '22023';
    end if;
  end if;
  perform core.check_transition('match', old.status, new.status, '{
    "scheduled": ["in_progress", "forfeited", "cancelled", "void"],
    "in_progress": ["completed", "forfeited", "void"],
    "completed": ["void"],
    "forfeited": ["void"]
  }'::jsonb);
  return new;
end $$;
revoke all on function core.tg_matches_update() from public, anon, authenticated;
create trigger c2_matches_update before update on public.matches
  for each row execute function core.tg_matches_update();
create trigger y_matches_log after insert or update on public.matches
  for each row execute function core.tg_log_status('match');

-- ---------------------------------------------------------------------------
-- match_games: the score of each game. Editable only while the match is live.
-- ---------------------------------------------------------------------------
create table public.match_games (
  id         text collate "C" primary key default core.ulid(),
  org_id     text not null references public.orgs (id) on delete restrict,
  unit_id    text collate "C" references public.org_units (id) on delete restrict,
  match_id   text collate "C" not null references public.matches (id) on delete restrict,
  game_no    smallint not null constraint match_games_no_chk check (game_no between 1 and 9),
  score_a    smallint not null constraint match_games_a_chk check (score_a between 0 and 99),
  score_b    smallint not null constraint match_games_b_chk check (score_b between 0 and 99),
  created_at timestamptz not null default now(),
  created_by text,
  updated_at timestamptz not null default now(),
  updated_by text,
  version    integer not null default 1,
  meta       jsonb not null default '{}'::jsonb,
  constraint match_games_no_tie_chk check (score_a <> score_b),
  constraint match_games_uq unique (match_id, game_no)
);
comment on table public.match_games is 'class: document. permissions: scores.enter. The score RPC checks each game against the stage''s scoring rule; the database refuses ties and edits to a finished match.';
create index match_games_org_idx on public.match_games (org_id);
create index match_games_unit_idx on public.match_games (unit_id);

create or replace function core.tg_match_games_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  mstatus text;
begin
  select status into mstatus from public.matches where id = new.match_id;
  if mstatus is null then
    raise exception 'the match does not exist' using errcode = '22023';
  end if;
  if tg_op = 'UPDATE' and (old.match_id, old.game_no) is distinct from (new.match_id, new.game_no) then
    raise exception 'a game''s match and number cannot change' using errcode = '42501';
  end if;
  if mstatus not in ('scheduled', 'in_progress') then
    raise exception 'games can be entered or edited only while the match is scheduled or in progress' using errcode = '22023';
  end if;
  return new;
end $$;
revoke all on function core.tg_match_games_guard() from public, anon, authenticated;
create trigger a2_match_games_guard before insert or update on public.match_games
  for each row execute function core.tg_match_games_guard();

-- ---------------------------------------------------------------------------
-- score_events: append-only. The result of a match is its latest finalized event that nothing reversed.
-- ---------------------------------------------------------------------------
create table public.score_events (
  id          text collate "C" primary key default core.ulid(),
  org_id      text not null references public.orgs (id) on delete restrict,
  unit_id     text collate "C" references public.org_units (id) on delete restrict,
  match_id    text collate "C" not null references public.matches (id) on delete restrict,
  kind        text not null constraint score_events_kind_chk check (kind in ('entered', 'finalized', 'corrected', 'forfeit')),
  payload     jsonb not null default '{}'::jsonb constraint score_events_payload_chk check (jsonb_typeof(payload) = 'object'),
  reverses_id text collate "C" references public.score_events (id) on delete restrict,
  occurred_at timestamptz not null default now(),
  created_at  timestamptz not null default now(),
  created_by  text,
  updated_at  timestamptz not null default now(),
  updated_by  text,
  version     integer not null default 1,
  meta        jsonb not null default '{}'::jsonb,
  constraint score_events_correction_chk check ((kind = 'corrected') = (reverses_id is not null)),
  constraint score_events_not_self_chk check (reverses_id is distinct from id)
);
comment on table public.score_events is 'class: ledger (append-only). created_by is the actor. A correction (kind corrected) reverses a finalized event, after which a new finalized event may follow.';
create index score_events_org_idx on public.score_events (org_id);
create index score_events_unit_idx on public.score_events (unit_id);
create index score_events_match_idx on public.score_events (match_id, occurred_at desc);
create unique index score_events_reverses_uq on public.score_events (reverses_id) where reverses_id is not null;

create or replace function core.tg_score_events_check() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  target public.score_events;
begin
  if not exists (select 1 from public.matches m where m.id = new.match_id and m.org_id = new.org_id) then
    raise exception 'the match does not exist' using errcode = '22023';
  end if;
  if new.reverses_id is not null then
    select * into target from public.score_events where id = new.reverses_id;
    if not found or target.match_id <> new.match_id or target.kind <> 'finalized' then
      raise exception 'a correction must reverse a finalized event of the same match' using errcode = '22023';
    end if;
  end if;
  if new.kind = 'finalized' and exists (
    select 1 from public.score_events e
    where e.match_id = new.match_id and e.kind = 'finalized'
      and not exists (select 1 from public.score_events r where r.reverses_id = e.id)
  ) then
    raise exception 'the match already has a final result; correct it first' using errcode = '23505';
  end if;
  return new;
end $$;
revoke all on function core.tg_score_events_check() from public, anon, authenticated;
create trigger a2_score_events_check before insert on public.score_events
  for each row execute function core.tg_score_events_check();

-- ---------------------------------------------------------------------------
-- division_results: final placements, written once when a division is finalized. class: document.
-- ---------------------------------------------------------------------------
create table public.division_results (
  id             text collate "C" primary key default core.ulid(),
  org_id         text not null references public.orgs (id) on delete restrict,
  unit_id        text collate "C" references public.org_units (id) on delete restrict,
  division_id    text collate "C" not null references public.divisions (id) on delete restrict,
  entry_id       text collate "C" not null references public.entries (id) on delete restrict,
  placement      integer not null constraint division_results_placement_chk check (placement >= 1),
  bracket_tier   text constraint division_results_tier_chk check (bracket_tier is null or bracket_tier in ('H', 'L')),
  bracket_result text constraint division_results_result_chk check (bracket_result is null or bracket_result in ('won', 'lost')),
  created_at     timestamptz not null default now(),
  created_by     text,
  updated_at     timestamptz not null default now(),
  updated_by     text,
  version        integer not null default 1,
  meta           jsonb not null default '{}'::jsonb,
  constraint division_results_uq unique (division_id, entry_id),
  constraint division_results_bracket_chk check (bracket_result is null or bracket_tier is not null)
);
comment on table public.division_results is 'class: document (immutable). permissions: scores.finalize. The rank engine reads these rows; ties may share a placement.';
create index division_results_org_idx on public.division_results (org_id);
create index division_results_unit_idx on public.division_results (unit_id);
create index division_results_entry_idx on public.division_results (entry_id);

create or replace function core.tg_division_results_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (
    select 1 from public.divisions d where d.id = new.division_id and d.org_id = new.org_id and d.status in ('in_progress', 'finalized')
  ) then
    raise exception 'results are written when a division is finalized' using errcode = '22023';
  end if;
  if not exists (select 1 from public.entries e where e.id = new.entry_id and e.division_id = new.division_id) then
    raise exception 'the entry does not belong to that division' using errcode = '22023';
  end if;
  return new;
end $$;
revoke all on function core.tg_division_results_insert() from public, anon, authenticated;
create trigger a2_division_results_insert before insert on public.division_results
  for each row execute function core.tg_division_results_insert();

create or replace function core.tg_division_results_frozen() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'division results are final' using errcode = '42501';
end $$;
create trigger c2_division_results_frozen before update on public.division_results
  for each row execute function core.tg_division_results_frozen();

select core.attach_standard('public.draws', 'document');
select core.attach_standard('public.matches', 'document');
select core.attach_standard('public.match_games', 'document');
select core.attach_standard('public.score_events', 'ledger');
select core.attach_standard('public.division_results', 'document');

-- ---------------------------------------------------------------------------
-- RLS. Brackets and results are public to members once the draw has happened; the draw seed is staff-only.
-- ---------------------------------------------------------------------------
alter table public.draws enable row level security;
alter table public.matches enable row level security;
alter table public.match_games enable row level security;
alter table public.score_events enable row level security;
alter table public.division_results enable row level security;

create policy draws_select on public.draws for select to authenticated
  using (core.has_permission(org_id, null, 'draws.run') or core.has_permission(org_id, null, 'events.manage'));

create policy matches_select on public.matches for select to authenticated
  using (
    core.has_permission(org_id, null, 'brackets.manage') or core.has_permission(org_id, null, 'events.manage')
    or core.has_permission(org_id, null, 'scores.enter') or core.is_own_member(referee_member_id)
    or exists (
      select 1 from public.division_stages s join public.divisions d on d.id = s.division_id
      where s.id = division_stage_id and d.status in ('drawn', 'in_progress', 'finalized')
    )
  );
create policy match_games_select on public.match_games for select to authenticated
  using (exists (select 1 from public.matches m where m.id = match_id));
create policy score_events_select on public.score_events for select to authenticated
  using (core.has_permission(org_id, null, 'scores.enter') or core.has_permission(org_id, null, 'events.manage'));
create policy division_results_select on public.division_results for select to authenticated
  using (exists (select 1 from public.divisions d where d.id = division_id));

select core.grant_client_dml('public.draws', false, false);
select core.grant_client_dml('public.matches', false, false);
select core.grant_client_dml('public.match_games', false, false);
select core.grant_client_dml('public.score_events', false, false);
select core.grant_client_dml('public.division_results', false, false);

grant select, insert, update on public.draws, public.matches, public.match_games to service_role;
grant select, insert on public.score_events, public.division_results to service_role;
