-- PLAN 8.4b: CPC points storage, assessed starts, and frozen division inputs.
-- This migration intentionally does not call these helpers from the draw or
-- finalization engine. PLAN 8.4c activates them after its correction logic exists.

create table public.member_cpc_ratings (
  id text collate "C" primary key default core.ulid(),
  org_id text not null references public.orgs(id) on delete restrict,
  unit_id text collate "C" references public.org_units(id) on delete restrict,
  member_id text collate "C" not null references public.members(id) on delete restrict,
  points numeric(4,3),
  eligible_match_count integer not null default 0 check (eligible_match_count >= 0),
  source text check (source in ('admin_assessment', 'division_finalization')),
  reason text,
  assessed_at timestamptz,
  assessed_by text collate "C" references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text,
  version integer not null default 1,
  deleted_at timestamptz, deleted_by text, delete_reason text,
  meta jsonb not null default '{}'::jsonb,
  constraint member_cpc_ratings_points_chk check (
    points is null or (points between 2.000 and 8.000 and points = round(points, 3))
  ),
  constraint member_cpc_ratings_state_chk check (
    (points is null and source is null and reason is null and assessed_at is null and assessed_by is null)
    or (points is not null and source is not null and assessed_at is not null and assessed_by is not null
      and (source <> 'admin_assessment' or length(btrim(coalesce(reason, ''))) >= 3))
  )
);
comment on table public.member_cpc_ratings is
  'class: master. Private current CPC points state; NULL points means unrated. Written only by rating RPCs and the future finalization engine.';
create unique index member_cpc_ratings_member_live_uq on public.member_cpc_ratings(member_id) where deleted_at is null;
create index member_cpc_ratings_org_idx on public.member_cpc_ratings(org_id);

create table public.member_cpc_rating_history (
  id text collate "C" primary key default core.ulid(),
  org_id text not null references public.orgs(id) on delete restrict,
  unit_id text collate "C" references public.org_units(id) on delete restrict,
  member_id text collate "C" not null references public.members(id) on delete restrict,
  rating_id text collate "C" not null references public.member_cpc_ratings(id) on delete restrict,
  entry_type text not null check (entry_type in ('admin_assessment', 'division_finalization', 'reversal')),
  division_id text collate "C" references public.divisions(id) on delete restrict,
  reverses_id text collate "C" references public.member_cpc_rating_history(id) on delete restrict,
  points_before numeric(4,3), points_after numeric(4,3) not null,
  match_count_before integer not null check (match_count_before >= 0),
  match_count_after integer not null check (match_count_after >= 0),
  reason text,
  algorithm_version text not null default 'cpc-v1' check (algorithm_version = 'cpc-v1'),
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text,
  version integer not null default 1,
  meta jsonb not null default '{}'::jsonb,
  constraint member_cpc_rating_history_points_chk check (
    (points_before is null or (points_before between 2.000 and 8.000 and points_before = round(points_before, 3)))
    and points_after between 2.000 and 8.000 and points_after = round(points_after, 3)
  )
);
comment on table public.member_cpc_rating_history is
  'class: ledger. Append-only CPC points changes with before/after values; corrections are reversal rows (PLAN 8.4c).';
create index member_cpc_rating_history_member_idx on public.member_cpc_rating_history(member_id, created_at);
create index member_cpc_rating_history_rating_idx on public.member_cpc_rating_history(rating_id);
create index member_cpc_rating_history_division_idx on public.member_cpc_rating_history(division_id) where division_id is not null;
create index member_cpc_rating_history_reverses_idx on public.member_cpc_rating_history(reverses_id) where reverses_id is not null;
create index member_cpc_rating_history_org_idx on public.member_cpc_rating_history(org_id);

create table public.event_participant_cpc_ratings (
  id text collate "C" primary key default core.ulid(),
  org_id text not null references public.orgs(id) on delete restrict,
  unit_id text collate "C" references public.org_units(id) on delete restrict,
  participant_id text collate "C" not null references public.event_participants(id) on delete restrict,
  points numeric(4,3),
  source text check (source = 'admin_assessment'),
  reason text,
  assessed_at timestamptz,
  assessed_by text collate "C" references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text,
  version integer not null default 1,
  deleted_at timestamptz, deleted_by text, delete_reason text,
  meta jsonb not null default '{}'::jsonb,
  constraint event_participant_cpc_ratings_points_chk check (
    points is null or (points between 2.000 and 8.000 and points = round(points, 3))
  ),
  constraint event_participant_cpc_ratings_state_chk check (
    (points is null and source is null and reason is null and assessed_at is null and assessed_by is null)
    or (points is not null and source = 'admin_assessment' and length(btrim(coalesce(reason, ''))) >= 3
      and assessed_at is not null and assessed_by is not null)
  )
);
comment on table public.event_participant_cpc_ratings is
  'class: master. Private, event-participant CPC points assessment for a guest. It never gives a guest a member rank.';
create unique index event_participant_cpc_ratings_participant_live_uq
  on public.event_participant_cpc_ratings(participant_id) where deleted_at is null;
create index event_participant_cpc_ratings_org_idx on public.event_participant_cpc_ratings(org_id);

create table public.division_cpc_rating_snapshots (
  id text collate "C" primary key default core.ulid(),
  org_id text not null references public.orgs(id) on delete restrict,
  unit_id text collate "C" references public.org_units(id) on delete restrict,
  division_id text collate "C" not null references public.divisions(id) on delete restrict,
  entry_id text collate "C" not null references public.entries(id) on delete restrict,
  member_id text collate "C" references public.members(id) on delete restrict,
  participant_id text collate "C" references public.event_participants(id) on delete restrict,
  starting_points numeric(4,3) not null check (starting_points between 2.000 and 8.000 and starting_points = round(starting_points, 3)),
  prior_eligible_match_count integer not null check (prior_eligible_match_count >= 0),
  team_strength numeric(4,3) not null check (team_strength between 2.000 and 8.000 and team_strength = round(team_strength, 3)),
  algorithm_version text not null default 'cpc-v1' check (algorithm_version = 'cpc-v1'),
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text,
  version integer not null default 1,
  meta jsonb not null default '{}'::jsonb,
  constraint division_cpc_rating_snapshots_subject_chk check (
    (member_id is null) <> (participant_id is null)
  )
);
comment on table public.division_cpc_rating_snapshots is
  'class: ledger. Immutable cpc-v1 player and team-strength inputs frozen after a division draw; guests remain non-members.';
create unique index division_cpc_rating_snapshot_member_uq
  on public.division_cpc_rating_snapshots(division_id, member_id) where member_id is not null;
create unique index division_cpc_rating_snapshot_participant_uq
  on public.division_cpc_rating_snapshots(division_id, participant_id) where participant_id is not null;
create index division_cpc_rating_snapshots_entry_idx on public.division_cpc_rating_snapshots(entry_id);
create index division_cpc_rating_snapshots_org_idx on public.division_cpc_rating_snapshots(org_id);

create or replace function core.tg_member_cpc_rating_org() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.members m where m.id = new.member_id and m.org_id = new.org_id and m.deleted_at is null) then
    raise exception 'CPC points must belong to an active member of this club' using errcode = '22023';
  end if;
  return new;
end $$;
revoke all on function core.tg_member_cpc_rating_org() from public, anon, authenticated;
create trigger c3_member_cpc_rating_org before insert or update of org_id, member_id on public.member_cpc_ratings
  for each row execute function core.tg_member_cpc_rating_org();

create or replace function core.tg_event_participant_cpc_rating_org() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.event_participants p where p.id = new.participant_id and p.org_id = new.org_id and p.deleted_at is null) then
    raise exception 'guest CPC points must belong to an active participant of this club' using errcode = '22023';
  end if;
  return new;
end $$;
revoke all on function core.tg_event_participant_cpc_rating_org() from public, anon, authenticated;
create trigger c3_event_participant_cpc_rating_org before insert or update of org_id, participant_id on public.event_participant_cpc_ratings
  for each row execute function core.tg_event_participant_cpc_rating_org();

create or replace function core.tg_division_cpc_rating_snapshot() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.divisions d where d.id = new.division_id and d.org_id = new.org_id)
     or not exists (select 1 from public.entries e where e.id = new.entry_id and e.division_id = new.division_id and e.org_id = new.org_id) then
    raise exception 'CPC rating snapshot entry must belong to its division and club' using errcode = '22023';
  end if;
  if new.member_id is not null and not exists (select 1 from public.entry_members em where em.entry_id = new.entry_id and em.member_id = new.member_id) then
    raise exception 'CPC rating snapshot member must belong to its entry' using errcode = '22023';
  end if;
  if new.participant_id is not null and not exists (select 1 from public.entry_guests eg where eg.entry_id = new.entry_id and eg.participant_id = new.participant_id) then
    raise exception 'CPC rating snapshot guest must belong to its entry' using errcode = '22023';
  end if;
  return new;
end $$;
revoke all on function core.tg_division_cpc_rating_snapshot() from public, anon, authenticated;
create trigger c3_division_cpc_rating_snapshot before insert on public.division_cpc_rating_snapshots
  for each row execute function core.tg_division_cpc_rating_snapshot();

select core.attach_standard('public.member_cpc_ratings', 'master');
select core.attach_standard('public.member_cpc_rating_history', 'ledger');
select core.attach_standard('public.event_participant_cpc_ratings', 'master');
select core.attach_standard('public.division_cpc_rating_snapshots', 'ledger');

alter table public.member_cpc_ratings enable row level security;
alter table public.member_cpc_rating_history enable row level security;
alter table public.event_participant_cpc_ratings enable row level security;
alter table public.division_cpc_rating_snapshots enable row level security;
create policy member_cpc_ratings_select on public.member_cpc_ratings for select to authenticated using (
  core.has_permission(org_id, null, 'members.read')
  or exists (select 1 from public.members m where m.id = member_id and m.profile_id = core.current_profile_id())
);
create policy member_cpc_rating_history_select on public.member_cpc_rating_history for select to authenticated using (
  core.has_permission(org_id, null, 'members.read')
  or exists (select 1 from public.members m where m.id = member_id and m.profile_id = core.current_profile_id())
);
create policy event_participant_cpc_ratings_select on public.event_participant_cpc_ratings for select to authenticated using (
  core.has_permission(org_id, null, 'events.manage') or core.has_permission(org_id, null, 'ranks.override')
);
create policy division_cpc_rating_snapshots_select on public.division_cpc_rating_snapshots for select to authenticated using (
  core.has_permission(org_id, null, 'events.manage') or core.has_permission(org_id, null, 'scores.finalize')
);
select core.grant_client_dml('public.member_cpc_ratings', false, false);
select core.grant_client_dml('public.member_cpc_rating_history', false, false);
select core.grant_client_dml('public.event_participant_cpc_ratings', false, false);
select core.grant_client_dml('public.division_cpc_rating_snapshots', false, false);

create or replace function core.set_member_cpc_rating(
  p_member_id text, p_points numeric, p_expected_version integer, p_key text, p_reason text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  m public.members; rating public.member_cpc_ratings; actor text := core.current_profile_id(); v_before numeric;
  v_reason text := nullif(btrim(p_reason), ''); replay jsonb; response jsonb;
begin
  select * into m from public.members where id = p_member_id and deleted_at is null for share;
  if actor is null or not found or not core.has_permission(m.org_id, null, 'ranks.override') then
    raise exception 'not allowed to assess CPC points' using errcode = '42501';
  end if;
  if p_points is null then raise exception 'an assessed CPC points value is required' using errcode = '22023'; end if;
  perform core.cpc_rating_band_code(p_points);
  if coalesce(length(v_reason), 0) < 3 or length(v_reason) > 500 then
    raise exception 'give an assessment reason from 3 to 500 characters' using errcode = '22023';
  end if;
  replay := core.idem_begin(p_key, m.org_id, 'cpc_rating.member_assessment',
    jsonb_build_object('member', m.id, 'points', p_points, 'version', p_expected_version, 'reason', v_reason));
  if replay is not null then return replay; end if;
  select * into rating from public.member_cpc_ratings where member_id = m.id and deleted_at is null for update;
  if found and p_expected_version is distinct from rating.version then
    raise exception 'CPC points changed; reload before saving' using errcode = 'CP409';
  elsif not found and coalesce(p_expected_version, 0) <> 0 then
    raise exception 'CPC points changed; reload before saving' using errcode = 'CP409';
  end if;
  if found then
    v_before := rating.points;
    update public.member_cpc_ratings set points = p_points, source = 'admin_assessment', reason = v_reason,
      assessed_at = now(), assessed_by = actor where id = rating.id;
  else
    insert into public.member_cpc_ratings(org_id, member_id, points, source, reason, assessed_at, assessed_by)
      values(m.org_id, m.id, p_points, 'admin_assessment', v_reason, now(), actor) returning * into rating;
  end if;
  select * into rating from public.member_cpc_ratings where member_id = m.id and deleted_at is null;
  -- An assessment resets the starting value only; the played-match count is kept.
  insert into public.member_cpc_rating_history(org_id, unit_id, member_id, rating_id, entry_type, points_before, points_after,
    match_count_before, match_count_after, reason)
  values(m.org_id, rating.unit_id, m.id, rating.id, 'admin_assessment', v_before, rating.points,
    rating.eligible_match_count, rating.eligible_match_count, v_reason);
  perform core.write_audit(m.org_id, 'cpc_rating.member_assessment', 'public.member_cpc_ratings', rating.id, null,
    jsonb_build_object('member_id', m.id, 'points', rating.points, 'version', rating.version, 'reason', v_reason));
  response := jsonb_build_object('ok', true, 'member_id', m.id, 'points', rating.points, 'version', rating.version);
  perform core.idem_complete(p_key, response);
  return response;
end $$;

create or replace function core.initialize_member_cpc_ratings(p_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  org text := (select p.org_id from public.profiles p where p.id = core.current_profile_id()); replay jsonb; response jsonb; created integer;
begin
  if core.current_profile_id() is null or org is null or not core.has_permission(org, null, 'ranks.override') then
    raise exception 'not allowed to initialize CPC points' using errcode = '42501';
  end if;
  replay := core.idem_begin(p_key, org, 'cpc_rating.initialize', jsonb_build_object('org', org));
  if replay is not null then return replay; end if;
  -- Unrated (NULL) rows only for members without one; existing points, counts and ranks are untouched.
  insert into public.member_cpc_ratings(org_id, unit_id, member_id)
  select m.org_id, m.unit_id, m.id from public.members m
  where m.org_id = org and m.deleted_at is null and m.status = 'active'
    and not exists (select 1 from public.member_cpc_ratings r where r.member_id = m.id and r.deleted_at is null)
  order by m.id
  on conflict (member_id) where deleted_at is null do nothing;
  get diagnostics created = row_count;
  perform core.write_audit(org, 'cpc_rating.initialize', 'public.member_cpc_ratings', org, null,
    jsonb_build_object('created_unrated', created));
  response := jsonb_build_object('ok', true, 'created_unrated', created);
  perform core.idem_complete(p_key, response);
  return response;
end $$;

create or replace function core.set_event_participant_cpc_rating(
  p_participant_id text, p_points numeric, p_expected_version integer, p_key text, p_reason text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  participant public.event_participants; rating public.event_participant_cpc_ratings;
  actor text := core.current_profile_id(); v_reason text := nullif(btrim(p_reason), ''); replay jsonb; response jsonb;
begin
  select * into participant from public.event_participants where id = p_participant_id and deleted_at is null for share;
  if actor is null or not found or not core.has_permission(participant.org_id, null, 'ranks.override') then
    raise exception 'not allowed to assess guest CPC points' using errcode = '42501';
  end if;
  if p_points is null then raise exception 'an assessed CPC points value is required' using errcode = '22023'; end if;
  perform core.cpc_rating_band_code(p_points);
  if coalesce(length(v_reason), 0) < 3 or length(v_reason) > 500 then
    raise exception 'give an assessment reason from 3 to 500 characters' using errcode = '22023';
  end if;
  replay := core.idem_begin(p_key, participant.org_id, 'cpc_rating.guest_assessment',
    jsonb_build_object('participant', participant.id, 'points', p_points, 'version', p_expected_version, 'reason', v_reason));
  if replay is not null then return replay; end if;
  if exists (select 1 from public.division_cpc_rating_snapshots s where s.participant_id = participant.id) then
    raise exception 'guest CPC points are frozen in a drawn division' using errcode = '22023';
  end if;
  select * into rating from public.event_participant_cpc_ratings where participant_id = participant.id and deleted_at is null for update;
  if found and p_expected_version is distinct from rating.version then
    raise exception 'guest CPC points changed; reload before saving' using errcode = 'CP409';
  elsif not found and coalesce(p_expected_version, 0) <> 0 then
    raise exception 'guest CPC points changed; reload before saving' using errcode = 'CP409';
  end if;
  if found then
    update public.event_participant_cpc_ratings set points = p_points, source = 'admin_assessment', reason = v_reason,
      assessed_at = now(), assessed_by = actor where id = rating.id;
  else
    insert into public.event_participant_cpc_ratings(org_id, unit_id, participant_id, points, source, reason, assessed_at, assessed_by)
      values(participant.org_id, participant.unit_id, participant.id, p_points, 'admin_assessment', v_reason, now(), actor)
      returning * into rating;
  end if;
  select * into rating from public.event_participant_cpc_ratings where participant_id = participant.id and deleted_at is null;
  perform core.write_audit(participant.org_id, 'cpc_rating.guest_assessment', 'public.event_participant_cpc_ratings', rating.id, null,
    jsonb_build_object('participant_id', participant.id, 'points', rating.points, 'version', rating.version, 'reason', v_reason));
  response := jsonb_build_object('ok', true, 'participant_id', participant.id, 'points', rating.points, 'version', rating.version);
  perform core.idem_complete(p_key, response);
  return response;
end $$;

create or replace function core.snapshot_division_cpc_ratings(p_division_id text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  dv public.divisions; actor text := core.current_profile_id(); r record; snapshot_count integer; active_entries integer; player_entries integer;
begin
  select * into dv from public.divisions where id = p_division_id for update;
  if actor is null or not found or not core.has_permission(dv.org_id, null, 'scores.finalize') then
    raise exception 'not allowed to freeze CPC rating inputs' using errcode = '42501';
  end if;
  if dv.status not in ('drawn', 'in_progress', 'finalized') then
    raise exception 'CPC rating inputs can be frozen only after the draw' using errcode = '22023';
  end if;
  select count(*) into snapshot_count from public.division_cpc_rating_snapshots where division_id = dv.id;
  if snapshot_count > 0 then
    return jsonb_build_object('division_id', dv.id, 'snapshots', snapshot_count, 'replayed', true);
  end if;
  select count(*) into active_entries from public.entries where division_id = dv.id and status = 'active';
  select count(distinct x.entry_id) into player_entries from (
    select em.entry_id from public.entry_members em join public.entries e on e.id = em.entry_id
      where e.division_id = dv.id and e.status = 'active'
    union all
    select eg.entry_id from public.entry_guests eg join public.entries e on e.id = eg.entry_id
      where e.division_id = dv.id and e.status = 'active'
  ) x;
  if active_entries = 0 or player_entries <> active_entries then
    raise exception 'every active entry needs a player before the division rating snapshot' using errcode = '22023';
  end if;
  for r in
    select e.id as entry_id, em.member_id, null::text as participant_id, mr.points, mr.eligible_match_count
      from public.entries e join public.entry_members em on em.entry_id = e.id
      left join public.member_cpc_ratings mr on mr.member_id = em.member_id and mr.deleted_at is null
      where e.division_id = dv.id and e.status = 'active'
    union all
    select e.id, null::text, eg.participant_id, gr.points, 0
      from public.entries e join public.entry_guests eg on eg.entry_id = e.id
      left join public.event_participant_cpc_ratings gr on gr.participant_id = eg.participant_id and gr.deleted_at is null
      where e.division_id = dv.id and e.status = 'active'
    order by 1, 2 nulls last, 3 nulls last
  loop
    if r.points is null then
      raise exception 'every player needs assessed CPC points before the division rating snapshot' using errcode = '22023';
    end if;
  end loop;
  -- Insert after validity is proven, retaining the individual point/count inputs.
  with player_inputs as (
    select e.id as entry_id, e.unit_id, em.member_id, null::text as participant_id,
      mr.points as starting_points, mr.eligible_match_count as prior_eligible_match_count
    from public.entries e join public.entry_members em on em.entry_id = e.id
    join public.member_cpc_ratings mr on mr.member_id = em.member_id and mr.deleted_at is null
    where e.division_id = dv.id and e.status = 'active'
    union all
    select e.id, e.unit_id, null::text, eg.participant_id, gr.points, 0
    from public.entries e join public.entry_guests eg on eg.entry_id = e.id
    join public.event_participant_cpc_ratings gr on gr.participant_id = eg.participant_id and gr.deleted_at is null
    where e.division_id = dv.id and e.status = 'active'
  ), strengths as (
    select entry_id, round(avg(starting_points), 3)::numeric(4,3) as team_strength
    from player_inputs group by entry_id
  )
  insert into public.division_cpc_rating_snapshots(org_id, unit_id, division_id, entry_id, member_id, participant_id,
    starting_points, prior_eligible_match_count, team_strength)
  select dv.org_id, p.unit_id, dv.id, p.entry_id, p.member_id, p.participant_id,
    p.starting_points, p.prior_eligible_match_count, s.team_strength
  from player_inputs p join strengths s on s.entry_id = p.entry_id;
  select count(*) into snapshot_count from public.division_cpc_rating_snapshots where division_id = dv.id;
  perform core.write_audit(dv.org_id, 'cpc_rating.snapshot', 'public.division_cpc_rating_snapshots', dv.id, null,
    jsonb_build_object('division_id', dv.id, 'snapshots', snapshot_count, 'algorithm', 'cpc-v1'));
  return jsonb_build_object('division_id', dv.id, 'snapshots', snapshot_count, 'replayed', false);
end $$;

create or replace function public.set_member_cpc_rating(p_member_id text, p_points numeric, p_expected_version integer, p_key text, p_reason text)
returns jsonb language sql security invoker set search_path = '' as $$
  select core.set_member_cpc_rating(p_member_id, p_points, p_expected_version, p_key, p_reason) $$;
create or replace function public.set_event_participant_cpc_rating(p_participant_id text, p_points numeric, p_expected_version integer, p_key text, p_reason text)
returns jsonb language sql security invoker set search_path = '' as $$
  select core.set_event_participant_cpc_rating(p_participant_id, p_points, p_expected_version, p_key, p_reason) $$;
create or replace function public.initialize_member_cpc_ratings(p_key text)
returns jsonb language sql security invoker set search_path = '' as $$ select core.initialize_member_cpc_ratings(p_key) $$;
create or replace function public.snapshot_division_cpc_ratings(p_division_id text)
returns jsonb language sql security invoker set search_path = '' as $$ select core.snapshot_division_cpc_ratings(p_division_id) $$;

revoke all on function core.set_member_cpc_rating(text,numeric,integer,text,text),
  core.set_event_participant_cpc_rating(text,numeric,integer,text,text), core.snapshot_division_cpc_ratings(text),
  core.initialize_member_cpc_ratings(text), public.initialize_member_cpc_ratings(text),
  public.set_member_cpc_rating(text,numeric,integer,text,text), public.set_event_participant_cpc_rating(text,numeric,integer,text,text),
  public.snapshot_division_cpc_ratings(text) from public, anon, authenticated;
grant execute on function public.set_member_cpc_rating(text,numeric,integer,text,text),
  public.set_event_participant_cpc_rating(text,numeric,integer,text,text), public.snapshot_division_cpc_ratings(text),
  public.initialize_member_cpc_ratings(text)
  to authenticated, service_role;

notify pgrst, 'reload schema';
