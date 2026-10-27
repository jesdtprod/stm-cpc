-- 1640_event_rating_settings (PLAN 6.1a): event setup; DUPR account checks are a later step.
-- Existing events retain CPC rank movement; no existing divisions or registrations are changed.
alter table public.events
  add column dupr_rated boolean not null default false,
  add column default_format_template_id text collate "C" references public.format_templates(id) on delete restrict,
  add column apply_cpc_rank_changes boolean not null default true;
create index events_default_format_template_idx on public.events(default_format_template_id)
  where default_format_template_id is not null;
comment on column public.events.dupr_rated is 'Intent to submit match results to DUPR; not confirmation of submission or account verification.';
comment on column public.events.default_format_template_id is 'Preferred template for new divisions; existing division snapshots remain unchanged.';
comment on column public.events.apply_cpc_rank_changes is 'Whether division finalization and corrections apply CPC rank movement for this event.';

-- New mandatory-argument overloads preserve the legacy RPC signatures for existing callers.
create or replace function core.create_event(p_id text, p_name text, p_starts_on date, p_ends_on date, p_location text,
  p_fee numeric, p_opens_at timestamptz, p_closes_at timestamptz,
  p_dupr_rated boolean, p_default_format_template_id text, p_apply_cpc_rank_changes boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_org text;
  v_name text := btrim(coalesce(p_name, ''));
  v_loc text := nullif(btrim(coalesce(p_location, '')), '');
  v_hash text;
  v_existing public.events;
  v_event public.events;
begin
  select org_id into v_org from core.my_profile();
  if v_org is null or not core.has_permission(v_org, null, 'events.manage') then
    raise exception 'you do not have permission to manage events' using errcode = '42501';
  end if;
  if p_id is null or not core.is_ulid(p_id) then
    raise exception 'the event needs an ID made when the form opened' using errcode = '22023';
  end if;
  if v_name = '' or char_length(v_name) > 120 then
    raise exception 'the event name is required (up to 120 characters)' using errcode = '22023';
  end if;
  if p_starts_on is null or p_ends_on is null or p_ends_on < p_starts_on then
    raise exception 'the end date cannot be before the start date' using errcode = '22023';
  end if;
  if coalesce(p_fee, 0) < 0 or coalesce(p_fee, 0) > 1000000 then
    raise exception 'the fee must be zero or more' using errcode = '22023';
  end if;
  if p_opens_at is not null and p_closes_at is not null and p_closes_at <= p_opens_at then
    raise exception 'registration must close after it opens' using errcode = '22023';
  end if;
  if p_dupr_rated is null or p_apply_cpc_rank_changes is null then
    raise exception 'choose the DUPR and CPC ranking settings' using errcode = '22023';
  end if;
  if p_default_format_template_id is not null and not exists (
    select 1 from public.format_templates t where t.id = p_default_format_template_id
      and t.org_id = v_org and t.deleted_at is null and t.is_active
  ) then
    raise exception 'choose an active format template from this club' using errcode = '22023';
  end if;
  v_hash := core.hash_of(jsonb_build_object('name', v_name, 'starts', p_starts_on, 'ends', p_ends_on, 'location', v_loc,
    'fee', coalesce(p_fee, 0), 'opens', p_opens_at, 'closes', p_closes_at,
    'dupr_rated', p_dupr_rated, 'default_format_template_id', p_default_format_template_id,
    'apply_cpc_rank_changes', p_apply_cpc_rank_changes));
  select * into v_existing from public.events e where e.id = p_id;
  if found then
    if v_existing.org_id = v_org and v_existing.payload_hash = v_hash then
      return jsonb_build_object('id', v_existing.id, 'doc_no', v_existing.doc_no, 'status', v_existing.status, 'replayed', true);
    end if;
    raise exception 'this event ID was already used for a different request' using errcode = 'CP422';
  end if;
  insert into public.events (id, org_id, doc_no, name, starts_on, ends_on, location, fee, registration_opens_at,
    registration_closes_at, payload_hash, dupr_rated, default_format_template_id, apply_cpc_rank_changes)
  values (p_id, v_org, '', v_name, p_starts_on, p_ends_on, v_loc, coalesce(p_fee, 0), p_opens_at, p_closes_at, v_hash, p_dupr_rated, p_default_format_template_id, p_apply_cpc_rank_changes)
  on conflict (id) do nothing returning * into v_event;
  if not found then
    select * into v_existing from public.events e where e.id = p_id;
    if v_existing.org_id = v_org and v_existing.payload_hash = v_hash then
      return jsonb_build_object('id', v_existing.id, 'doc_no', v_existing.doc_no, 'status', v_existing.status, 'replayed', true);
    end if;
    raise exception 'this event ID was already used for a different request' using errcode = 'CP422';
  end if;
  perform core.write_audit(v_org, 'event.create', 'public.events', v_event.id, null,
    jsonb_build_object('name', v_name, 'starts_on', p_starts_on, 'fee', coalesce(p_fee, 0), 'dupr_rated', p_dupr_rated,
      'default_format_template_id', p_default_format_template_id, 'apply_cpc_rank_changes', p_apply_cpc_rank_changes));
  return jsonb_build_object('id', v_event.id, 'doc_no', v_event.doc_no, 'status', v_event.status);
end $$;

create or replace function core.update_event(p_id text, p_name text, p_starts_on date, p_ends_on date, p_location text,
  p_fee numeric, p_opens_at timestamptz, p_closes_at timestamptz,
  p_dupr_rated boolean, p_default_format_template_id text, p_apply_cpc_rank_changes boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  e public.events;
  v_name text := btrim(coalesce(p_name, ''));
  v_loc text := nullif(btrim(coalesce(p_location, '')), '');
begin
  select * into e from public.events x where x.id = p_id for update;
  if not found then
    raise exception 'event not found' using errcode = '22023';
  end if;
  if not core.has_permission(e.org_id, null, 'events.manage') then
    raise exception 'you do not have permission to manage events' using errcode = '42501';
  end if;
  if e.status not in ('draft', 'registration_open', 'registration_closed') then
    raise exception 'an event can be edited only before its draw' using errcode = '22023';
  end if;
  if v_name = '' or char_length(v_name) > 120 then
    raise exception 'the event name is required (up to 120 characters)' using errcode = '22023';
  end if;
  if p_starts_on is null or p_ends_on is null or p_ends_on < p_starts_on then
    raise exception 'the end date cannot be before the start date' using errcode = '22023';
  end if;
  if coalesce(p_fee, 0) < 0 or coalesce(p_fee, 0) > 1000000 then
    raise exception 'the fee must be zero or more' using errcode = '22023';
  end if;
  if p_opens_at is not null and p_closes_at is not null and p_closes_at <= p_opens_at then
    raise exception 'registration must close after it opens' using errcode = '22023';
  end if;
  if p_dupr_rated is null or p_apply_cpc_rank_changes is null then
    raise exception 'choose the DUPR and CPC ranking settings' using errcode = '22023';
  end if;
  if p_default_format_template_id is distinct from e.default_format_template_id
    and p_default_format_template_id is not null and not exists (
    select 1 from public.format_templates t where t.id = p_default_format_template_id
      and t.org_id = e.org_id and t.deleted_at is null and t.is_active
  ) then
    raise exception 'choose an active format template from this club' using errcode = '22023';
  end if;
  if row(p_dupr_rated, p_default_format_template_id, p_apply_cpc_rank_changes)
    is distinct from row(e.dupr_rated, e.default_format_template_id, e.apply_cpc_rank_changes)
    and e.status <> 'draft' then
    raise exception 'event ranking and format settings are locked after draft' using errcode = '22023';
  end if;
  if row(v_name, p_starts_on, p_ends_on, v_loc, coalesce(p_fee, 0), p_opens_at, p_closes_at,
      p_dupr_rated, p_default_format_template_id, p_apply_cpc_rank_changes)
    is not distinct from row(e.name, e.starts_on, e.ends_on, e.location, e.fee,
      e.registration_opens_at, e.registration_closes_at, e.dupr_rated,
      e.default_format_template_id, e.apply_cpc_rank_changes) then
    return jsonb_build_object('id', e.id, 'ok', true, 'unchanged', true);
  end if;
  update public.events set name = v_name, starts_on = p_starts_on, ends_on = p_ends_on, location = v_loc,
    fee = coalesce(p_fee, 0), registration_opens_at = p_opens_at, registration_closes_at = p_closes_at,
    dupr_rated = p_dupr_rated, default_format_template_id = p_default_format_template_id,
    apply_cpc_rank_changes = p_apply_cpc_rank_changes
  where id = p_id;
  perform core.write_audit(e.org_id, 'event.update', 'public.events', e.id,
    jsonb_build_object('name', e.name, 'fee', e.fee, 'dupr_rated', e.dupr_rated,
      'default_format_template_id', e.default_format_template_id, 'apply_cpc_rank_changes', e.apply_cpc_rank_changes),
    jsonb_build_object('name', v_name, 'fee', coalesce(p_fee, 0), 'dupr_rated', p_dupr_rated,
      'default_format_template_id', p_default_format_template_id, 'apply_cpc_rank_changes', p_apply_cpc_rank_changes));
  return jsonb_build_object('id', e.id, 'ok', true);
end $$;

create or replace function public.create_event(p_id text, p_name text, p_starts_on date, p_ends_on date, p_location text,
  p_fee numeric, p_opens_at timestamptz, p_closes_at timestamptz,
  p_dupr_rated boolean, p_default_format_template_id text, p_apply_cpc_rank_changes boolean) returns jsonb
language sql security invoker set search_path = '' as $$
  select core.create_event(p_id, p_name, p_starts_on, p_ends_on, p_location, p_fee, p_opens_at, p_closes_at,
    p_dupr_rated, p_default_format_template_id, p_apply_cpc_rank_changes)
$$;
create or replace function public.update_event(p_id text, p_name text, p_starts_on date, p_ends_on date, p_location text,
  p_fee numeric, p_opens_at timestamptz, p_closes_at timestamptz,
  p_dupr_rated boolean, p_default_format_template_id text, p_apply_cpc_rank_changes boolean) returns jsonb
language sql security invoker set search_path = '' as $$
  select core.update_event(p_id, p_name, p_starts_on, p_ends_on, p_location, p_fee, p_opens_at, p_closes_at,
    p_dupr_rated, p_default_format_template_id, p_apply_cpc_rank_changes)
$$;

revoke all on function core.create_event(text,text,date,date,text,numeric,timestamptz,timestamptz,boolean,text,boolean),
  core.update_event(text,text,date,date,text,numeric,timestamptz,timestamptz,boolean,text,boolean),
  public.create_event(text,text,date,date,text,numeric,timestamptz,timestamptz,boolean,text,boolean),
  public.update_event(text,text,date,date,text,numeric,timestamptz,timestamptz,boolean,text,boolean) from public, anon, authenticated;
grant execute on function core.create_event(text,text,date,date,text,numeric,timestamptz,timestamptz,boolean,text,boolean),
  core.update_event(text,text,date,date,text,numeric,timestamptz,timestamptz,boolean,text,boolean),
  public.create_event(text,text,date,date,text,numeric,timestamptz,timestamptz,boolean,text,boolean),
  public.update_event(text,text,date,date,text,numeric,timestamptz,timestamptz,boolean,text,boolean) to authenticated, service_role;

-- Until verified account eligibility is implemented, a DUPR event can be configured but cannot accept entries.
-- Guard the table transition so the legacy status RPC cannot bypass this rule.
create or replace function core.tg_event_dupr_registration_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.dupr_rated and new.status = 'registration_open' then
    raise exception 'DUPR registration is not available yet; account verification must be enabled first' using errcode = '22023';
  end if;
  return new;
end $$;
revoke all on function core.tg_event_dupr_registration_guard() from public, anon, authenticated;
create trigger c1_event_dupr_registration_guard before update of status on public.events
  for each row execute function core.tg_event_dupr_registration_guard();

-- The same gate applies to original finalization and later score corrections.
create or replace function core.apply_rank_movement(p_division_id text, p_revision integer default 1) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  dv public.divisions;
  res record;
  mem record;
  rule public.rank_rules;
  v_cur public.member_ranks;
  v_played integer;
  v_forfeited boolean;
  v_new text;
  v_idx_cur integer;
  v_idx_new integer;
  v_idx_lim integer;
  v_reason text;
  v_up integer := 0;
  v_down integer := 0;
  v_same integer := 0;
begin
  select * into dv from public.divisions where id = p_division_id;
  if not exists (select 1 from public.events e where e.id = dv.event_id and e.apply_cpc_rank_changes) then
    return jsonb_build_object('up', 0, 'down', 0, 'same', 0, 'skipped', true);
  end if;
  for res in select r.* from public.division_results r where r.division_id = dv.id and r.superseded_at is null loop
    select count(*)::integer into v_played from public.matches m
    where m.status in ('completed', 'forfeited') and res.entry_id in (m.entry_a_id, m.entry_b_id)
      and m.division_stage_id in (select s.id from public.division_stages s where s.division_id = dv.id);
    select exists (
      select 1 from public.score_events e join public.matches m on m.id = e.match_id
      where e.kind = 'forfeit' and e.payload ->> 'forfeiting_entry_id' = res.entry_id
        and m.division_stage_id in (select s.id from public.division_stages s where s.division_id = dv.id)) into v_forfeited;
    select * into rule from public.rank_rules r
    where r.org_id = dv.org_id and r.is_active and r.deleted_at is null
      and (not r.conditions ? 'placement' or (r.conditions ->> 'placement')::integer = res.placement)
      and (not r.conditions ? 'bracket_tier' or r.conditions ->> 'bracket_tier' = res.bracket_tier)
      and (not r.conditions ? 'bracket_result' or r.conditions ->> 'bracket_result' = res.bracket_result)
      and (not r.conditions ? 'min_matches' or (r.conditions ->> 'min_matches')::integer <= v_played)
    order by r.priority, r.id limit 1;
    if not found then
      continue;
    end if;
    for mem in select em.member_id from public.entry_members em where em.entry_id = res.entry_id loop
      select * into v_cur from public.member_ranks mr where mr.member_id = mem.member_id and mr.deleted_at is null;
      if not found then
        continue;
      end if;
      v_new := v_cur.rank_id;
      v_reason := format('%s (placement %s)', rule.name, res.placement);
      if rule.exclude_forfeits and v_forfeited then
        v_reason := 'Not moved: the entry forfeited a match';
      elsif rule.cooldown_days > 0 and exists (
        select 1 from public.rank_history h where h.member_id = mem.member_id and h.reverses_id is null and h.from_rank_id <> h.to_rank_id
          and h.division_id is distinct from dv.id and h.occurred_at > now() - rule.cooldown_days * interval '1 day') then
        v_reason := 'Not moved: still in the cooldown after the last change';
      elsif rule.action <> 'retain' then
        v_new := core.rank_move(v_cur.rank_id, case when rule.action = 'up' then rule.levels else -rule.levels end);
        select c.idx into v_idx_cur from core.rank_chain(dv.org_id) c where c.rank_id = v_cur.rank_id;
        select c.idx into v_idx_new from core.rank_chain(dv.org_id) c where c.rank_id = v_new;
        if rule.action = 'up' and rule.max_rank_id is not null then
          select c.idx into v_idx_lim from core.rank_chain(dv.org_id) c where c.rank_id = rule.max_rank_id;
          if v_idx_new > greatest(v_idx_cur, v_idx_lim) then
            select c.rank_id into v_new from core.rank_chain(dv.org_id) c where c.idx = greatest(v_idx_cur, v_idx_lim);
          end if;
        elsif rule.action = 'down' and rule.min_rank_id is not null then
          select c.idx into v_idx_lim from core.rank_chain(dv.org_id) c where c.rank_id = rule.min_rank_id;
          if v_idx_new < least(v_idx_cur, v_idx_lim) then
            select c.rank_id into v_new from core.rank_chain(dv.org_id) c where c.idx = least(v_idx_cur, v_idx_lim);
          end if;
        end if;
      end if;
      insert into public.rank_history (org_id, member_id, from_rank_id, to_rank_id, rule_id, division_id, event_id, reason, revision)
      values (dv.org_id, mem.member_id, v_cur.rank_id, v_new, rule.id, dv.id, dv.event_id, v_reason, p_revision);
      if v_new <> v_cur.rank_id then
        update public.member_ranks set rank_id = v_new, set_by_rule_id = rule.id, source_division_id = dv.id where id = v_cur.id;
        select c.idx into v_idx_cur from core.rank_chain(dv.org_id) c where c.rank_id = v_cur.rank_id;
        select c.idx into v_idx_new from core.rank_chain(dv.org_id) c where c.rank_id = v_new;
        if v_idx_new > v_idx_cur then v_up := v_up + 1; else v_down := v_down + 1; end if;
      else
        v_same := v_same + 1;
      end if;
    end loop;
  end loop;
  return jsonb_build_object('up', v_up, 'down', v_down, 'same', v_same);
end $$;
revoke all on function core.apply_rank_movement(text, integer) from public, anon, authenticated;
grant execute on function core.apply_rank_movement(text, integer) to service_role;

