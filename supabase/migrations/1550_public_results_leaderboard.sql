-- 1550_public_results_leaderboard (PLAN 9.2): what anonymous visitors may see, only once the club has decided.
--   Two switches in Settings (Public pages), both OFF until an administrator turns them on:
--     public.results_enabled      the podium (placements 1 to 3, display names) of recently finished divisions
--     public.leaderboard_enabled  the ranking list: display name, category and rank
--   Nothing else is exposed: no member ID, contact, birth date, rank history, scores of individual matches or payment data.
--   While a switch is off the function answers {"enabled": false} and no names leave the database.
--   Also: the landing information says which of the two pages are public, and rank movement now honours the existing
--   Settings switch "Ranks move up and down after events" (ranks.movement_enabled), which the rank engine had not read yet.

create or replace function core.setting_valid(p_key text, p_value jsonb) returns boolean
language plpgsql stable set search_path = '' as $$
declare
  t text;
  n numeric;
  item text;
begin
  if p_value is null or p_value = 'null'::jsonb then
    return false;
  end if;
  t := jsonb_typeof(p_value);

  if p_key = 'timezone' then
    return t = 'string' and exists (select 1 from pg_catalog.pg_timezone_names z where z.name = p_value #>> '{}');
  end if;

  if p_key in ('members.signup_enabled', 'members.auto_approve_imported', 'booking.approval_required',
               'payments.required.court_booking', 'payments.required.event_registration',
               'payments.proof_required_non_cash', 'events.registration_approval_required',
               'events.waitlist_enabled', 'ranks.movement_enabled', 'public.results_enabled', 'public.leaderboard_enabled') then
    return t = 'boolean';
  end if;

  if p_key in ('club.name', 'events.default_scoring_rule') then
    return t = 'string' and char_length(btrim(p_value #>> '{}')) between 1 and 80;
  end if;
  if p_key = 'members.id_prefix' then
    return t = 'string' and (p_value #>> '{}') ~ '^[A-Z]{2,6}$';
  end if;
  if p_key = 'members.id_pattern' then
    return t = 'string' and char_length(p_value #>> '{}') between 1 and 200;
  end if;
  if p_key = 'payments.instructions' then
    return t = 'string' and char_length(p_value #>> '{}') <= 1000;
  end if;

  if p_key = 'payments.methods' then
    if t <> 'array' or jsonb_array_length(p_value) not between 1 and 4 then
      return false;
    end if;
    for item in select jsonb_array_elements_text(p_value) loop
      if item not in ('cash', 'gcash', 'maya', 'bank_transfer') then
        return false;
      end if;
    end loop;
    return (select count(distinct e) = jsonb_array_length(p_value) from jsonb_array_elements_text(p_value) e);
  end if;

  -- whole numbers within a range
  if p_key in ('members.temp_password_days', 'session.idle_minutes', 'booking.slot_minutes', 'booking.advance_days',
               'booking.max_participants', 'booking.request_expiry_hours', 'booking.cancel_cutoff_hours') then
    if t <> 'number' then
      return false;
    end if;
    n := (p_value #>> '{}')::numeric;
    if n <> trunc(n) then
      return false;
    end if;
    return case p_key
      when 'members.temp_password_days' then n between 0 and 365
      when 'session.idle_minutes' then n between 5 and 120
      when 'booking.slot_minutes' then n between 15 and 240
      when 'booking.advance_days' then n between 1 and 365
      when 'booking.max_participants' then n between 1 and 20
      when 'booking.request_expiry_hours' then n between 1 and 168
      else n between 0 and 168
    end;
  end if;

  -- money
  if p_key in ('booking.cancel_fee', 'booking.no_show_fee') then
    if t <> 'number' then
      return false;
    end if;
    n := (p_value #>> '{}')::numeric;
    return n >= 0 and n <= 100000 and n = round(n, 2);
  end if;

  return true;
end $$;

insert into public.settings (org_id, key, value)
select o.id, v.key, v.value
from public.orgs o
cross join (values ('public.results_enabled', 'false'::jsonb), ('public.leaderboard_enabled', 'false'::jsonb)) as v(key, value)
where o.code = 'cpc' and o.deleted_at is null
  and not exists (select 1 from public.settings s where s.org_id = o.id and s.key = v.key and s.unit_id is null and s.deleted_at is null);

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
  -- the club can switch rank movement off (Settings > Ranks); results are still recorded
  if not core.setting_bool(dv.org_id, 'ranks.movement_enabled', true) then
    return jsonb_build_object('up', 0, 'down', 0, 'same', 0, 'disabled', true);
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

create or replace function public.public_results() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_org text;
begin
  select o.id into v_org from public.orgs o where o.code = 'cpc' and o.deleted_at is null;
  if v_org is null or not core.setting_bool(v_org, 'public.results_enabled', false) then
    return jsonb_build_object('enabled', false);
  end if;
  return jsonb_build_object('enabled', true, 'divisions', coalesce((
    select jsonb_agg(jsonb_build_object('event', x.event_name, 'division', x.division_name, 'category', x.category_name,
      'format', x.format, 'finished_on', x.finished_on, 'podium', x.podium) order by x.finalized_at desc, x.division_name)
    from (
      select d.id, d.name as division_name, d.format, d.finalized_at, (d.finalized_at at time zone 'Asia/Manila')::date as finished_on,
        e.name as event_name, c.name as category_name,
        (select jsonb_agg(jsonb_build_object('placement', r.placement, 'name', core.entry_name(r.entry_id)) order by r.placement, core.entry_name(r.entry_id))
         from public.division_results r where r.division_id = d.id and r.superseded_at is null and r.placement <= 3) as podium
      from public.divisions d
      join public.events e on e.id = d.event_id
      join public.categories c on c.id = d.category_id
      where d.org_id = v_org and d.status = 'finalized' and d.finalized_at > now() - interval '12 months'
      order by d.finalized_at desc limit 12) x), '[]'::jsonb));
end $$;

create or replace function public.public_leaderboard(p_category_id text default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_org text;
begin
  select o.id into v_org from public.orgs o where o.code = 'cpc' and o.deleted_at is null;
  if v_org is null or not core.setting_bool(v_org, 'public.leaderboard_enabled', false) then
    return jsonb_build_object('enabled', false);
  end if;
  return jsonb_build_object('enabled', true,
    'categories', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.sort_order, c.name)
                            from public.categories c where c.org_id = v_org and c.deleted_at is null and c.is_active), '[]'::jsonb),
    'players', coalesce((
      select jsonb_agg(jsonb_build_object('name', q.display_name, 'category', q.category_name, 'rank', q.rank_name) order by q.idx desc, q.display_name)
      from (
        select pe.display_name, c.name as category_name, r.name as rank_name, ch.idx
        from public.member_ranks mr
        join public.members m on m.id = mr.member_id and m.deleted_at is null and m.status = 'active'
        join public.persons pe on pe.id = m.person_id
        join public.ranks r on r.id = mr.rank_id
        join public.rank_ladders l on l.id = r.ladder_id
        join public.categories c on c.id = l.category_id
        join core.rank_chain(v_org) ch on ch.rank_id = r.id
        where mr.deleted_at is null and m.org_id = v_org and (p_category_id is null or c.id = p_category_id)
        order by ch.idx desc, pe.display_name limit 200) q), '[]'::jsonb));
end $$;

revoke all on function public.public_results(), public.public_leaderboard(text) from public, anon, authenticated;
grant execute on function public.public_results(), public.public_leaderboard(text) to anon, authenticated, service_role;

-- the landing information also says which public pages exist
create or replace function public.public_landing_info() returns jsonb
language sql stable security definer set search_path = '' as $$
  with club as (
    select o.id from public.orgs o where o.code = 'cpc' and o.deleted_at is null
  ), today as (
    select (now() at time zone 'Asia/Manila')::date as d
  )
  select jsonb_build_object(
    'events', coalesce((
      select jsonb_agg(jsonb_build_object('name', e.name, 'starts_on', e.starts_on, 'ends_on', e.ends_on,
        'location', e.location, 'status', e.status, 'fee', e.fee) order by e.starts_on, e.name)
      from (
        select x.* from public.events x, today t
        where x.org_id in (select id from club)
          and x.status in ('registration_open', 'registration_closed', 'drawn', 'in_progress')
          and x.ends_on >= t.d
        order by x.starts_on, x.name limit 6) e), '[]'::jsonb),
    'courts', coalesce((
      select jsonb_agg(jsonb_build_object('name', c.name, 'indoor', c.indoor, 'surface', c.surface,
        'hours', (
          select jsonb_build_object('opens', to_char(min(h.opens_at), 'HH24:MI'), 'closes', to_char(max(h.closes_at), 'HH24:MI'),
            'days', count(distinct h.weekday))
          from public.court_hours h, today t
          where (h.court_id is null or h.court_id = c.id) and h.org_id = c.org_id and h.deleted_at is null
            and h.valid_from <= t.d and (h.valid_to is null or h.valid_to >= t.d))
        ) order by c.sort_order, c.name)
      from public.courts c
      where c.org_id in (select id from club) and c.deleted_at is null and c.status = 'available'), '[]'::jsonb),
    'results_public', (select coalesce(bool_or(core.setting_bool(id, 'public.results_enabled', false)), false) from club),
    'leaderboard_public', (select coalesce(bool_or(core.setting_bool(id, 'public.leaderboard_enabled', false)), false) from club)
  )
$$;
