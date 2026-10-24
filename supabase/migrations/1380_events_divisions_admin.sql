-- 1380_events_divisions_admin (PLAN 6.1): what the admin events screens need from the database.
--   * create_event / update_event / set_event_status: events are documents, so they are written only here
--   * create_division / update_division / cancel_division: a division copies (snapshots) the chosen format template and
--     scoring rule and gets one stage row per stage of that format
--   Moves to "drawn" and "in_progress" belong to the draw and match engine (stage 7); here an event can open and close
--   registration, be cancelled, or be completed once every division is finalized or cancelled.
--   Same event or division ID with the same content returns the same row (replayed); different content is refused.

create or replace function core.hash_of(p jsonb) returns text
language sql immutable set search_path = '' as $$
  select encode(extensions.digest(convert_to(p::text, 'utf8'), 'sha256'), 'hex')
$$;
revoke all on function core.hash_of(jsonb) from public, anon, authenticated;

-- A rank band must sit on the category's ladder, low not above high (the same rule the insert trigger applies).
create or replace function core.check_rank_band(p_category text, p_min text, p_max text) returns void
language plpgsql stable set search_path = '' as $$
declare
  lo public.ranks;
  hi public.ranks;
begin
  if p_min is not null then select * into lo from public.ranks where id = p_min; end if;
  if p_max is not null then select * into hi from public.ranks where id = p_max; end if;
  if p_min is null and p_max is null then return; end if;
  if not exists (select 1 from public.rank_ladders l where l.category_id = p_category and l.deleted_at is null
                 and (lo.id is null or lo.ladder_id = l.id) and (hi.id is null or hi.ladder_id = l.id)) then
    raise exception 'the rank band must belong to the category''s ladder' using errcode = '22023';
  end if;
  if lo.id is not null and hi.id is not null and lo.sort_order > hi.sort_order then
    raise exception 'the minimum rank cannot be above the maximum rank' using errcode = '22023';
  end if;
end $$;
revoke all on function core.check_rank_band(text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- events
-- ---------------------------------------------------------------------------
create or replace function core.create_event(p_id text, p_name text, p_starts_on date, p_ends_on date, p_location text,
  p_fee numeric, p_opens_at timestamptz, p_closes_at timestamptz) returns jsonb
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
  v_hash := core.hash_of(jsonb_build_object('name', v_name, 'starts', p_starts_on, 'ends', p_ends_on, 'location', v_loc,
    'fee', coalesce(p_fee, 0), 'opens', p_opens_at, 'closes', p_closes_at));
  select * into v_existing from public.events e where e.id = p_id;
  if found then
    if v_existing.org_id = v_org and v_existing.payload_hash = v_hash then
      return jsonb_build_object('id', v_existing.id, 'doc_no', v_existing.doc_no, 'status', v_existing.status, 'replayed', true);
    end if;
    raise exception 'this event ID was already used for a different request' using errcode = 'CP422';
  end if;
  insert into public.events (id, org_id, doc_no, name, starts_on, ends_on, location, fee, registration_opens_at,
    registration_closes_at, payload_hash)
  values (p_id, v_org, '', v_name, p_starts_on, p_ends_on, v_loc, coalesce(p_fee, 0), p_opens_at, p_closes_at, v_hash)
  returning * into v_event;
  perform core.write_audit(v_org, 'event.create', 'public.events', v_event.id, null,
    jsonb_build_object('name', v_name, 'starts_on', p_starts_on, 'fee', coalesce(p_fee, 0)));
  return jsonb_build_object('id', v_event.id, 'doc_no', v_event.doc_no, 'status', v_event.status);
end $$;

create or replace function core.update_event(p_id text, p_name text, p_starts_on date, p_ends_on date, p_location text,
  p_fee numeric, p_opens_at timestamptz, p_closes_at timestamptz) returns jsonb
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
  update public.events set name = v_name, starts_on = p_starts_on, ends_on = p_ends_on, location = v_loc,
    fee = coalesce(p_fee, 0), registration_opens_at = p_opens_at, registration_closes_at = p_closes_at
  where id = p_id;
  perform core.write_audit(e.org_id, 'event.update', 'public.events', e.id,
    jsonb_build_object('name', e.name, 'fee', e.fee), jsonb_build_object('name', v_name, 'fee', coalesce(p_fee, 0)));
  return jsonb_build_object('id', e.id, 'ok', true);
end $$;

-- p_to: registration_open | registration_closed | completed | cancelled. The state machine itself is the table trigger.
create or replace function core.set_event_status(p_id text, p_to text, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  e public.events;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_live integer;
begin
  select * into e from public.events x where x.id = p_id for update;
  if not found then
    raise exception 'event not found' using errcode = '22023';
  end if;
  if not core.has_permission(e.org_id, null, 'events.manage') then
    raise exception 'you do not have permission to manage events' using errcode = '42501';
  end if;
  if p_to not in ('registration_open', 'registration_closed', 'completed', 'cancelled') then
    raise exception 'that status is set by the draw and the matches, not by hand' using errcode = '22023';
  end if;
  if e.status = p_to then
    return jsonb_build_object('id', e.id, 'status', e.status, 'replayed', true);
  end if;
  if v_reason is not null and char_length(v_reason) > 500 then
    raise exception 'the reason is too long' using errcode = '22023';
  end if;
  if p_to = 'cancelled' then
    if v_reason is null or char_length(v_reason) < 3 then
      raise exception 'a reason is required' using errcode = '22023';
    end if;
    -- Divisions that have not finished go down with the event.
    update public.divisions set status = 'cancelled', cancelled_at = now(), cancelled_by = core.current_profile_id(),
      cancel_reason = 'Event cancelled: ' || v_reason, status_reason = 'Event cancelled'
    where event_id = e.id and status in ('open', 'drawn', 'in_progress');
    update public.events set status = 'cancelled', cancelled_at = now(), cancelled_by = core.current_profile_id(),
      cancel_reason = v_reason, status_reason = v_reason where id = e.id;
  else
    if p_to = 'registration_open' then
      select count(*) into v_live from public.divisions d where d.event_id = e.id and d.status = 'open';
      if v_live = 0 then
        raise exception 'add at least one division before opening registration' using errcode = '22023';
      end if;
    elsif p_to = 'completed' then
      if exists (select 1 from public.divisions d where d.event_id = e.id and d.status in ('open', 'drawn', 'in_progress')) then
        raise exception 'every division must be finalized or cancelled first' using errcode = '22023';
      end if;
    end if;
    update public.events set status = p_to, status_reason = v_reason where id = e.id;
  end if;
  perform core.write_audit(e.org_id, 'event.status', 'public.events', e.id,
    jsonb_build_object('status', e.status), jsonb_build_object('status', p_to, 'reason', v_reason));
  return jsonb_build_object('id', e.id, 'status', p_to);
end $$;

-- ---------------------------------------------------------------------------
-- divisions
-- ---------------------------------------------------------------------------
create or replace function core.create_division(p_id text, p_event_id text, p_name text, p_category_id text, p_format text,
  p_gender text, p_age_group text, p_min_rank_id text, p_max_rank_id text, p_max_entries integer,
  p_template_id text, p_scoring_rule_id text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_org text;
  v_event public.events;
  v_name text := btrim(coalesce(p_name, ''));
  v_age text := nullif(btrim(coalesce(p_age_group, '')), '');
  v_tpl public.format_templates;
  v_rule public.scoring_rules;
  v_rule_name text;
  v_rule_snap jsonb;
  v_hash text;
  v_existing public.divisions;
  v_div public.divisions;
  v_stage jsonb;
  v_no integer := 0;
begin
  select * into v_event from public.events x where x.id = p_event_id;
  if not found then
    raise exception 'event not found' using errcode = '22023';
  end if;
  v_org := v_event.org_id;
  if not core.has_permission(v_org, null, 'divisions.manage') then
    raise exception 'you do not have permission to manage divisions' using errcode = '42501';
  end if;
  if p_id is null or not core.is_ulid(p_id) then
    raise exception 'the division needs an ID made when the form opened' using errcode = '22023';
  end if;
  if v_name = '' or char_length(v_name) > 120 then
    raise exception 'the division name is required (up to 120 characters)' using errcode = '22023';
  end if;
  if p_format not in ('singles', 'doubles') then
    raise exception 'choose singles or doubles' using errcode = '22023';
  end if;
  if p_gender is not null and p_gender not in ('male', 'female', 'mixed') then
    raise exception 'unknown gender setting' using errcode = '22023';
  end if;
  if v_age is not null and char_length(v_age) > 40 then
    raise exception 'the age group is too long' using errcode = '22023';
  end if;
  if p_max_entries is not null and (p_max_entries < 2 or p_max_entries > 512) then
    raise exception 'the entry limit must be between 2 and 512' using errcode = '22023';
  end if;
  if not exists (select 1 from public.categories c where c.id = p_category_id and c.org_id = v_org and c.deleted_at is null) then
    raise exception 'choose a category' using errcode = '22023';
  end if;
  select * into v_tpl from public.format_templates t where t.id = p_template_id and t.org_id = v_org and t.deleted_at is null and t.is_active;
  if not found then
    raise exception 'choose a format' using errcode = '22023';
  end if;
  if p_scoring_rule_id is not null then
    select * into v_rule from public.scoring_rules r where r.id = p_scoring_rule_id and r.org_id = v_org and r.deleted_at is null and r.is_active;
  else
    select (value #>> '{}') into v_rule_name from public.settings s
    where s.org_id = v_org and s.key = 'events.default_scoring_rule' and s.unit_id is null and s.deleted_at is null;
    select * into v_rule from public.scoring_rules r
    where r.org_id = v_org and r.deleted_at is null and r.is_active and lower(r.name) = lower(coalesce(v_rule_name, ''));
  end if;
  if not found then
    raise exception 'choose a scoring rule' using errcode = '22023';
  end if;
  v_rule_snap := jsonb_build_object('name', v_rule.name, 'games_to_win', v_rule.games_to_win,
    'points_per_game', v_rule.points_per_game, 'win_by', v_rule.win_by, 'point_cap', v_rule.point_cap,
    'forfeit_score', v_rule.forfeit_score, 'tiebreak_order', to_jsonb(v_rule.tiebreak_order));

  v_hash := core.hash_of(jsonb_build_object('event', p_event_id, 'name', v_name, 'category', p_category_id, 'format', p_format,
    'gender', p_gender, 'age', v_age, 'min', p_min_rank_id, 'max', p_max_rank_id, 'entries', p_max_entries,
    'template', p_template_id, 'rule', v_rule.id));
  select * into v_existing from public.divisions d where d.id = p_id;
  if found then
    if v_existing.payload_hash = v_hash then
      return jsonb_build_object('id', v_existing.id, 'status', v_existing.status, 'replayed', true);
    end if;
    raise exception 'this division ID was already used for a different request' using errcode = 'CP422';
  end if;

  if v_event.status in ('completed', 'cancelled') then
    raise exception 'divisions can be added only to a live event' using errcode = '22023';
  end if;
  perform core.check_rank_band(p_category_id, p_min_rank_id, p_max_rank_id);
  if exists (select 1 from public.divisions d where d.event_id = p_event_id and lower(d.name) = lower(v_name) and d.status <> 'cancelled') then
    raise exception 'this event already has a division named %', v_name using errcode = '23505';
  end if;

  insert into public.divisions (id, org_id, event_id, name, category_id, format, gender, age_group, min_rank_id, max_rank_id,
    max_entries, format_snapshot, scoring_snapshot, payload_hash)
  values (p_id, v_org, p_event_id, v_name, p_category_id, p_format, p_gender, v_age, p_min_rank_id, p_max_rank_id,
    p_max_entries, v_tpl.stages, v_rule_snap, v_hash)
  returning * into v_div;
  for v_stage in select * from jsonb_array_elements(v_tpl.stages) loop
    v_no := v_no + 1;
    insert into public.division_stages (org_id, division_id, stage_no, stage_type, config, scoring_rule_snapshot)
    values (v_org, v_div.id, v_no, v_stage ->> 'stage_type', coalesce(v_stage -> 'config', '{}'::jsonb), v_rule_snap);
  end loop;
  perform core.write_audit(v_org, 'division.create', 'public.divisions', v_div.id, null,
    jsonb_build_object('event', v_event.name, 'name', v_name, 'format', p_format, 'template', v_tpl.name));
  return jsonb_build_object('id', v_div.id, 'status', v_div.status, 'stages', v_no);
end $$;

-- Name, entry limit, gender, age group and rank band can change while the division is open; the category, singles or
-- doubles, format and scoring are fixed at creation (add another division instead).
create or replace function core.update_division(p_id text, p_name text, p_gender text, p_age_group text,
  p_min_rank_id text, p_max_rank_id text, p_max_entries integer) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  d public.divisions;
  v_name text := btrim(coalesce(p_name, ''));
  v_age text := nullif(btrim(coalesce(p_age_group, '')), '');
  v_taken integer;
begin
  select * into d from public.divisions x where x.id = p_id for update;
  if not found then
    raise exception 'division not found' using errcode = '22023';
  end if;
  if not core.has_permission(d.org_id, null, 'divisions.manage') then
    raise exception 'you do not have permission to manage divisions' using errcode = '42501';
  end if;
  if d.status <> 'open' then
    raise exception 'a division can be edited only before its draw' using errcode = '22023';
  end if;
  if v_name = '' or char_length(v_name) > 120 then
    raise exception 'the division name is required (up to 120 characters)' using errcode = '22023';
  end if;
  if p_gender is not null and p_gender not in ('male', 'female', 'mixed') then
    raise exception 'unknown gender setting' using errcode = '22023';
  end if;
  if v_age is not null and char_length(v_age) > 40 then
    raise exception 'the age group is too long' using errcode = '22023';
  end if;
  if p_max_entries is not null and (p_max_entries < 2 or p_max_entries > 512) then
    raise exception 'the entry limit must be between 2 and 512' using errcode = '22023';
  end if;
  if p_max_entries is not null then
    select count(*) into v_taken from public.registrations r where r.division_id = d.id and r.status in ('requested', 'confirmed');
    if p_max_entries < v_taken then
      raise exception 'the limit is below the % registrations already held', v_taken using errcode = '22023';
    end if;
  end if;
  perform core.check_rank_band(d.category_id, p_min_rank_id, p_max_rank_id);
  if exists (select 1 from public.divisions o where o.event_id = d.event_id and o.id <> d.id and lower(o.name) = lower(v_name) and o.status <> 'cancelled') then
    raise exception 'this event already has a division named %', v_name using errcode = '23505';
  end if;
  update public.divisions set name = v_name, gender = p_gender, age_group = v_age, min_rank_id = p_min_rank_id,
    max_rank_id = p_max_rank_id, max_entries = p_max_entries where id = d.id;
  perform core.write_audit(d.org_id, 'division.update', 'public.divisions', d.id,
    jsonb_build_object('name', d.name, 'max_entries', d.max_entries), jsonb_build_object('name', v_name, 'max_entries', p_max_entries));
  return jsonb_build_object('id', d.id, 'ok', true);
end $$;

create or replace function core.cancel_division(p_id text, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  d public.divisions;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  select * into d from public.divisions x where x.id = p_id for update;
  if not found then
    raise exception 'division not found' using errcode = '22023';
  end if;
  if not core.has_permission(d.org_id, null, 'divisions.manage') then
    raise exception 'you do not have permission to manage divisions' using errcode = '42501';
  end if;
  if d.status = 'cancelled' then
    return jsonb_build_object('id', d.id, 'status', 'cancelled', 'replayed', true);
  end if;
  if v_reason is null or char_length(v_reason) < 3 or char_length(v_reason) > 500 then
    raise exception 'a reason of 3 to 500 characters is required' using errcode = '22023';
  end if;
  update public.division_stages set status = 'cancelled' where division_id = d.id and status in ('pending', 'drawn', 'in_progress');
  update public.divisions set status = 'cancelled', cancelled_at = now(), cancelled_by = core.current_profile_id(),
    cancel_reason = v_reason, status_reason = v_reason where id = d.id;
  perform core.write_audit(d.org_id, 'division.cancel', 'public.divisions', d.id,
    jsonb_build_object('status', d.status), jsonb_build_object('status', 'cancelled', 'reason', v_reason));
  return jsonb_build_object('id', d.id, 'status', 'cancelled');
end $$;

-- ---- public wrappers (security invoker; the core function checks the caller)
create or replace function public.create_event(p_id text, p_name text, p_starts_on date, p_ends_on date, p_location text,
  p_fee numeric, p_opens_at timestamptz, p_closes_at timestamptz) returns jsonb
language sql security invoker set search_path = '' as $$ select core.create_event(p_id, p_name, p_starts_on, p_ends_on, p_location, p_fee, p_opens_at, p_closes_at) $$;
create or replace function public.update_event(p_id text, p_name text, p_starts_on date, p_ends_on date, p_location text,
  p_fee numeric, p_opens_at timestamptz, p_closes_at timestamptz) returns jsonb
language sql security invoker set search_path = '' as $$ select core.update_event(p_id, p_name, p_starts_on, p_ends_on, p_location, p_fee, p_opens_at, p_closes_at) $$;
create or replace function public.set_event_status(p_id text, p_to text, p_reason text) returns jsonb
language sql security invoker set search_path = '' as $$ select core.set_event_status(p_id, p_to, p_reason) $$;
create or replace function public.create_division(p_id text, p_event_id text, p_name text, p_category_id text, p_format text,
  p_gender text, p_age_group text, p_min_rank_id text, p_max_rank_id text, p_max_entries integer,
  p_template_id text, p_scoring_rule_id text) returns jsonb
language sql security invoker set search_path = '' as $$
  select core.create_division(p_id, p_event_id, p_name, p_category_id, p_format, p_gender, p_age_group, p_min_rank_id, p_max_rank_id, p_max_entries, p_template_id, p_scoring_rule_id) $$;
create or replace function public.update_division(p_id text, p_name text, p_gender text, p_age_group text,
  p_min_rank_id text, p_max_rank_id text, p_max_entries integer) returns jsonb
language sql security invoker set search_path = '' as $$ select core.update_division(p_id, p_name, p_gender, p_age_group, p_min_rank_id, p_max_rank_id, p_max_entries) $$;
create or replace function public.cancel_division(p_id text, p_reason text) returns jsonb
language sql security invoker set search_path = '' as $$ select core.cancel_division(p_id, p_reason) $$;

revoke all on function
  core.create_event(text, text, date, date, text, numeric, timestamptz, timestamptz),
  core.update_event(text, text, date, date, text, numeric, timestamptz, timestamptz),
  core.set_event_status(text, text, text),
  core.create_division(text, text, text, text, text, text, text, text, text, integer, text, text),
  core.update_division(text, text, text, text, text, text, integer),
  core.cancel_division(text, text),
  public.create_event(text, text, date, date, text, numeric, timestamptz, timestamptz),
  public.update_event(text, text, date, date, text, numeric, timestamptz, timestamptz),
  public.set_event_status(text, text, text),
  public.create_division(text, text, text, text, text, text, text, text, text, integer, text, text),
  public.update_division(text, text, text, text, text, text, integer),
  public.cancel_division(text, text)
from public, anon, authenticated;
grant execute on function
  core.create_event(text, text, date, date, text, numeric, timestamptz, timestamptz),
  core.update_event(text, text, date, date, text, numeric, timestamptz, timestamptz),
  core.set_event_status(text, text, text),
  core.create_division(text, text, text, text, text, text, text, text, text, integer, text, text),
  core.update_division(text, text, text, text, text, text, integer),
  core.cancel_division(text, text),
  public.create_event(text, text, date, date, text, numeric, timestamptz, timestamptz),
  public.update_event(text, text, date, date, text, numeric, timestamptz, timestamptz),
  public.set_event_status(text, text, text),
  public.create_division(text, text, text, text, text, text, text, text, text, integer, text, text),
  public.update_division(text, text, text, text, text, text, integer),
  public.cancel_division(text, text)
to authenticated, service_role;
