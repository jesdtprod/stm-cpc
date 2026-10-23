-- 1010_categories_ranks (PLAN 2.2, part 3 of 3; design: docs/CLUB_SCHEMA.md 4.2)
-- categories (skill levels), rank_ladders, ranks, rank_rules, member_ranks, rank_history.
-- Admins edit categories, ladders, ranks and rules directly (permissions categories.manage / ranks.manage).
-- member_ranks and rank_history are written only by the rank-engine and override RPCs (stage 4):
-- clients get SELECT only. rank_history.division_id / event_id and member_ranks.source_division_id
-- are plain ULID columns for now; step 2.4 adds their foreign keys when divisions and events exist.

-- Validates rank_rules.conditions: an object with only the keys below, each of the right type.
create or replace function core.rank_conditions_valid(c jsonb) returns boolean
language sql immutable parallel safe set search_path = '' as $$
  select coalesce(
    jsonb_typeof(c) = 'object'
    and not exists (
      select 1 from jsonb_object_keys(c) k
      where k not in ('placement', 'bracket_tier', 'bracket_result', 'min_matches')
    )
    and (not c ? 'placement' or (jsonb_typeof(c -> 'placement') = 'number'
         and (c ->> 'placement') ~ '^[1-9][0-9]{0,3}$'))
    and (not c ? 'bracket_tier' or c -> 'bracket_tier' in ('"H"'::jsonb, '"L"'::jsonb))
    and (not c ? 'bracket_result' or c -> 'bracket_result' in ('"won"'::jsonb, '"lost"'::jsonb))
    and (not c ? 'min_matches' or (jsonb_typeof(c -> 'min_matches') = 'number'
         and (c ->> 'min_matches') ~ '^[0-9]{1,3}$')),
    false)
$$;
revoke all on function core.rank_conditions_valid(jsonb) from public, anon;
grant execute on function core.rank_conditions_valid(jsonb) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- categories: skill levels. class: master. permissions: categories.manage
-- ---------------------------------------------------------------------------
create table public.categories (
  id                text collate "C" primary key default core.ulid(),
  org_id            text not null references public.orgs (id) on delete restrict,
  unit_id           text collate "C" references public.org_units (id) on delete restrict,
  code              text not null constraint categories_code_chk check (code ~ '^[a-z0-9][a-z0-9_-]{0,31}$'),
  name              text not null constraint categories_name_chk check (length(btrim(name)) > 0),
  description       text,
  sort_order        integer not null default 0,
  is_active         boolean not null default true,
  eligibility_notes text,
  created_at        timestamptz not null default now(),
  created_by        text,
  updated_at        timestamptz not null default now(),
  updated_by        text,
  version           integer not null default 1,
  deleted_at        timestamptz,
  deleted_by        text,
  delete_reason     text,
  meta              jsonb not null default '{}'::jsonb
);
comment on table public.categories is 'class: master. permissions: categories.manage. Retire with is_active = false while in use; soft delete only when nothing refers to it.';
create index categories_org_idx on public.categories (org_id);
create index categories_unit_idx on public.categories (unit_id);
create unique index categories_code_active_uq on public.categories (org_id, code) where deleted_at is null;

-- ---------------------------------------------------------------------------
-- rank_ladders: one ladder per category. overflow says what happens at the top and bottom rank.
-- ---------------------------------------------------------------------------
create table public.rank_ladders (
  id            text collate "C" primary key default core.ulid(),
  org_id        text not null references public.orgs (id) on delete restrict,
  unit_id       text collate "C" references public.org_units (id) on delete restrict,
  category_id   text collate "C" not null references public.categories (id) on delete restrict,
  overflow      text not null default 'stop' constraint rank_ladders_overflow_chk check (overflow in ('chain', 'stop')),
  is_active     boolean not null default true,
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
comment on table public.rank_ladders is 'class: master. permissions: ranks.manage. One active ladder per category.';
create index rank_ladders_org_idx on public.rank_ladders (org_id);
create index rank_ladders_unit_idx on public.rank_ladders (unit_id);
create unique index rank_ladders_category_active_uq on public.rank_ladders (category_id) where deleted_at is null;

-- ---------------------------------------------------------------------------
-- ranks: ordered steps in a ladder (for example Novice Low, Novice High).
-- ---------------------------------------------------------------------------
create table public.ranks (
  id            text collate "C" primary key default core.ulid(),
  org_id        text not null references public.orgs (id) on delete restrict,
  unit_id       text collate "C" references public.org_units (id) on delete restrict,
  ladder_id     text collate "C" not null references public.rank_ladders (id) on delete restrict,
  code          text not null constraint ranks_code_chk check (code ~ '^[a-z0-9][a-z0-9_-]{0,31}$'),
  name          text not null constraint ranks_name_chk check (length(btrim(name)) > 0),
  sort_order    integer not null constraint ranks_sort_chk check (sort_order >= 0),
  is_starting   boolean not null default false,
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
comment on table public.ranks is 'class: master. permissions: ranks.manage. sort_order 0 is the lowest rank.';
create index ranks_org_idx on public.ranks (org_id);
create index ranks_unit_idx on public.ranks (unit_id);
create index ranks_ladder_idx on public.ranks (ladder_id);
create unique index ranks_ladder_order_active_uq on public.ranks (ladder_id, sort_order) where deleted_at is null;
create unique index ranks_ladder_code_active_uq on public.ranks (ladder_id, code) where deleted_at is null;
create unique index ranks_one_starting_uq on public.ranks (ladder_id) where is_starting and deleted_at is null;

-- ---------------------------------------------------------------------------
-- rank_rules: movement rules as data, evaluated by the rank engine after a division is finalized.
-- ---------------------------------------------------------------------------
create table public.rank_rules (
  id              text collate "C" primary key default core.ulid(),
  org_id          text not null references public.orgs (id) on delete restrict,
  unit_id         text collate "C" references public.org_units (id) on delete restrict,
  name            text not null constraint rank_rules_name_chk check (length(btrim(name)) > 0),
  conditions      jsonb not null default '{}'::jsonb
                  constraint rank_rules_conditions_chk check (core.rank_conditions_valid(conditions)),
  action          text not null constraint rank_rules_action_chk check (action in ('up', 'down', 'retain')),
  levels          integer not null default 1 constraint rank_rules_levels_chk check (levels between 0 and 10),
  min_rank_id     text collate "C" references public.ranks (id) on delete restrict,
  max_rank_id     text collate "C" references public.ranks (id) on delete restrict,
  cooldown_days   integer not null default 0 constraint rank_rules_cooldown_chk check (cooldown_days >= 0),
  exclude_forfeits boolean not null default true,
  priority        integer not null default 100,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  created_by      text,
  updated_at      timestamptz not null default now(),
  updated_by      text,
  version         integer not null default 1,
  deleted_at      timestamptz,
  deleted_by      text,
  delete_reason   text,
  meta            jsonb not null default '{}'::jsonb,
  constraint rank_rules_retain_chk check ((action = 'retain') = (levels = 0))
);
comment on table public.rank_rules is 'class: master. permissions: ranks.manage. conditions keys: placement, bracket_tier (H/L), bracket_result (won/lost), min_matches.';
create index rank_rules_org_idx on public.rank_rules (org_id);
create index rank_rules_unit_idx on public.rank_rules (unit_id);
create index rank_rules_min_rank_idx on public.rank_rules (min_rank_id);
create index rank_rules_max_rank_idx on public.rank_rules (max_rank_id);
create index rank_rules_active_idx on public.rank_rules (org_id, priority) where is_active and deleted_at is null;

-- min and max rank, when given, belong to the same ladder and are ordered.
create or replace function core.tg_rank_rules_bounds() returns trigger
language plpgsql set search_path = '' as $$
declare
  lo public.ranks;
  hi public.ranks;
begin
  if new.min_rank_id is not null then select * into lo from public.ranks where id = new.min_rank_id; end if;
  if new.max_rank_id is not null then select * into hi from public.ranks where id = new.max_rank_id; end if;
  if lo.id is not null and hi.id is not null then
    if lo.ladder_id <> hi.ladder_id then
      raise exception 'min and max rank must be in the same ladder' using errcode = '22023';
    end if;
    if lo.sort_order > hi.sort_order then
      raise exception 'min rank cannot be above max rank' using errcode = '22023';
    end if;
  end if;
  return new;
end $$;
create trigger c2_rank_rules_bounds before insert or update on public.rank_rules
  for each row execute function core.tg_rank_rules_bounds();

-- ---------------------------------------------------------------------------
-- member_ranks: the current rank of a member. Written only by the rank engine / override RPCs.
-- ---------------------------------------------------------------------------
create table public.member_ranks (
  id                 text collate "C" primary key default core.ulid(),
  org_id             text not null references public.orgs (id) on delete restrict,
  unit_id            text collate "C" references public.org_units (id) on delete restrict,
  member_id          text collate "C" not null references public.members (id) on delete restrict,
  rank_id            text collate "C" not null references public.ranks (id) on delete restrict,
  set_by_rule_id     text collate "C" references public.rank_rules (id) on delete restrict,
  source_division_id text collate "C",
  created_at         timestamptz not null default now(),
  created_by         text,
  updated_at         timestamptz not null default now(),
  updated_by         text,
  version            integer not null default 1,
  deleted_at         timestamptz,
  deleted_by         text,
  delete_reason      text,
  meta               jsonb not null default '{}'::jsonb
);
comment on table public.member_ranks is 'class: master. One current rank per member. Written only by the rank-engine and override RPCs (stage 4); readable by the member and by members.read.';
create index member_ranks_org_idx on public.member_ranks (org_id);
create index member_ranks_unit_idx on public.member_ranks (unit_id);
create index member_ranks_rank_idx on public.member_ranks (rank_id);
create index member_ranks_rule_idx on public.member_ranks (set_by_rule_id);
create unique index member_ranks_member_active_uq on public.member_ranks (member_id) where deleted_at is null;

-- A member's current rank must be a live rank on a live ladder.
create or replace function core.tg_member_ranks_rank() returns trigger
language plpgsql set search_path = '' as $$
begin
  if not exists (
    select 1 from public.ranks r
    join public.rank_ladders l on l.id = r.ladder_id
    where r.id = new.rank_id and r.deleted_at is null and l.deleted_at is null
  ) then
    raise exception 'the rank is retired or does not exist' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger c2_member_ranks_rank before insert or update of rank_id on public.member_ranks
  for each row execute function core.tg_member_ranks_rank();

-- ---------------------------------------------------------------------------
-- rank_history: append-only record of every rank change. class: ledger.
-- A correction is a new row with reverses_id pointing at the row it undoes.
-- ---------------------------------------------------------------------------
create table public.rank_history (
  id           text collate "C" primary key default core.ulid(),
  org_id       text not null references public.orgs (id) on delete restrict,
  unit_id      text collate "C" references public.org_units (id) on delete restrict,
  member_id    text collate "C" not null references public.members (id) on delete restrict,
  from_rank_id text collate "C" references public.ranks (id) on delete restrict,
  to_rank_id   text collate "C" not null references public.ranks (id) on delete restrict,
  rule_id      text collate "C" references public.rank_rules (id) on delete restrict,
  division_id  text collate "C",
  event_id     text collate "C",
  reason       text,
  reverses_id  text collate "C" references public.rank_history (id) on delete restrict,
  occurred_at  timestamptz not null default now(),
  created_at   timestamptz not null default now(),
  created_by   text,
  updated_at   timestamptz not null default now(),
  updated_by   text,
  version      integer not null default 1,
  meta         jsonb not null default '{}'::jsonb,
  constraint rank_history_not_self_reverse_chk check (reverses_id is distinct from id)
);
comment on table public.rank_history is 'class: ledger (append-only). A division moves a member at most once: unique (division_id, member_id) among non-reversal rows.';
create index rank_history_org_idx on public.rank_history (org_id);
create index rank_history_unit_idx on public.rank_history (unit_id);
create index rank_history_member_idx on public.rank_history (member_id, occurred_at desc);
create index rank_history_from_idx on public.rank_history (from_rank_id);
create index rank_history_to_idx on public.rank_history (to_rank_id);
create index rank_history_rule_idx on public.rank_history (rule_id);
create index rank_history_division_idx on public.rank_history (division_id);
create index rank_history_event_idx on public.rank_history (event_id);
create unique index rank_history_division_member_uq on public.rank_history (division_id, member_id)
  where reverses_id is null and division_id is not null;
create unique index rank_history_reverses_uq on public.rank_history (reverses_id) where reverses_id is not null;

-- ---------------------------------------------------------------------------
-- Retire-not-delete guards: a row that is still in use cannot be soft-deleted.
-- ---------------------------------------------------------------------------
create or replace function core.tg_categories_in_use() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.deleted_at is not null and old.deleted_at is null
     and exists (select 1 from public.rank_ladders where category_id = new.id and deleted_at is null) then
    raise exception 'category % still has a ladder; retire it (is_active = false) or delete the ladder first', new.code using errcode = '23503';
  end if;
  return new;
end $$;
create trigger c2_categories_in_use before update on public.categories
  for each row execute function core.tg_categories_in_use();

create or replace function core.tg_ladders_in_use() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.deleted_at is not null and old.deleted_at is null
     and exists (select 1 from public.ranks where ladder_id = new.id and deleted_at is null) then
    raise exception 'the ladder still has ranks' using errcode = '23503';
  end if;
  return new;
end $$;
create trigger c2_ladders_in_use before update on public.rank_ladders
  for each row execute function core.tg_ladders_in_use();

create or replace function core.tg_ranks_in_use() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.deleted_at is not null and old.deleted_at is null
     and exists (select 1 from public.member_ranks where rank_id = new.id and deleted_at is null) then
    raise exception 'rank % is held by members', new.code using errcode = '23503';
  end if;
  return new;
end $$;
create trigger c2_ranks_in_use before update on public.ranks
  for each row execute function core.tg_ranks_in_use();

select core.attach_standard('public.categories', 'master');
select core.attach_standard('public.rank_ladders', 'master');
select core.attach_standard('public.ranks', 'master');
select core.attach_standard('public.rank_rules', 'master');
select core.attach_standard('public.member_ranks', 'master');
select core.attach_standard('public.rank_history', 'ledger');

-- ---------------------------------------------------------------------------
-- RLS: every org member reads the structure; managers edit it; ranks of people follow the member.
-- ---------------------------------------------------------------------------
alter table public.categories enable row level security;
alter table public.rank_ladders enable row level security;
alter table public.ranks enable row level security;
alter table public.rank_rules enable row level security;
alter table public.member_ranks enable row level security;
alter table public.rank_history enable row level security;

create policy categories_select on public.categories for select to authenticated using (core.is_org_member(org_id));
create policy categories_insert on public.categories for insert to authenticated with check (core.has_permission(org_id, null, 'categories.manage'));
create policy categories_update on public.categories for update to authenticated
  using (core.has_permission(org_id, null, 'categories.manage')) with check (core.has_permission(org_id, null, 'categories.manage'));

create policy rank_ladders_select on public.rank_ladders for select to authenticated using (core.is_org_member(org_id));
create policy rank_ladders_insert on public.rank_ladders for insert to authenticated with check (core.has_permission(org_id, null, 'ranks.manage'));
create policy rank_ladders_update on public.rank_ladders for update to authenticated
  using (core.has_permission(org_id, null, 'ranks.manage')) with check (core.has_permission(org_id, null, 'ranks.manage'));

create policy ranks_select on public.ranks for select to authenticated using (core.is_org_member(org_id));
create policy ranks_insert on public.ranks for insert to authenticated with check (core.has_permission(org_id, null, 'ranks.manage'));
create policy ranks_update on public.ranks for update to authenticated
  using (core.has_permission(org_id, null, 'ranks.manage')) with check (core.has_permission(org_id, null, 'ranks.manage'));

create policy rank_rules_select on public.rank_rules for select to authenticated using (core.has_permission(org_id, null, 'ranks.manage'));
create policy rank_rules_insert on public.rank_rules for insert to authenticated with check (core.has_permission(org_id, null, 'ranks.manage'));
create policy rank_rules_update on public.rank_rules for update to authenticated
  using (core.has_permission(org_id, null, 'ranks.manage')) with check (core.has_permission(org_id, null, 'ranks.manage'));

create policy member_ranks_select on public.member_ranks for select to authenticated
  using (
    core.has_permission(org_id, null, 'members.read')
    or exists (select 1 from public.members m where m.id = member_id and m.profile_id = core.current_profile_id())
  );
create policy rank_history_select on public.rank_history for select to authenticated
  using (
    core.has_permission(org_id, null, 'members.read')
    or exists (select 1 from public.members m where m.id = member_id and m.profile_id = core.current_profile_id())
  );

select core.grant_client_dml('public.categories', true, true);
select core.grant_client_dml('public.rank_ladders', true, true);
select core.grant_client_dml('public.ranks', true, true);
select core.grant_client_dml('public.rank_rules', true, true);
select core.grant_client_dml('public.member_ranks', false, false);
select core.grant_client_dml('public.rank_history', false, false);

grant select, insert, update on public.categories, public.rank_ladders, public.ranks, public.rank_rules,
  public.member_ranks to service_role;
grant select, insert on public.rank_history to service_role;
