-- 1650_rank_rule_format_template (PLAN 4.3a).
-- All Formats is null, preserving existing rule behavior. Older division source IDs are unknown;
-- keep them null rather than inferring identity from editable template contents or names.
alter table public.rank_rules add column format_template_id text collate "C"
  references public.format_templates(id) on delete restrict;
alter table public.divisions add column format_template_id text collate "C"
  references public.format_templates(id) on delete restrict;
create index rank_rules_format_template_idx on public.rank_rules(format_template_id) where format_template_id is not null;
create index divisions_format_template_idx on public.divisions(format_template_id) where format_template_id is not null;
comment on column public.rank_rules.format_template_id is 'Optional template restriction. Null means All Formats, including older divisions with unknown source template.';
comment on column public.divisions.format_template_id is 'Immutable source template ID captured at division creation. Unknown for divisions created before migration 1650.';
select core.grant_client_dml('public.rank_rules', true, true);
create or replace function core.tg_rank_rule_format_template() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and new.format_template_id is not distinct from old.format_template_id then
    return new;
  end if;
  if new.format_template_id is not null and not exists (
    select 1 from public.format_templates t where t.id = new.format_template_id
      and t.org_id = new.org_id and t.is_active and t.deleted_at is null
  ) then
    raise exception 'choose an active format template from this club' using errcode = '22023';
  end if;
  return new;
end $$;
revoke all on function core.tg_rank_rule_format_template() from public, anon, authenticated;
create trigger c3_rank_rule_format_template before insert or update of format_template_id on public.rank_rules
  for each row execute function core.tg_rank_rule_format_template();

create or replace function core.tg_division_format_template() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    if new.format_template_id is distinct from old.format_template_id then
      raise exception 'the division format template is fixed at creation' using errcode = '22023';
    end if;
  elsif new.format_template_id is not null and not exists (
    select 1 from public.format_templates t where t.id = new.format_template_id and t.org_id = new.org_id
      and t.stages = new.format_snapshot
  ) then
    raise exception 'the division template must match its club and saved format' using errcode = '22023';
  end if;
  return new;
end $$;
revoke all on function core.tg_division_format_template() from public, anon, authenticated;
create trigger c3_division_format_template before insert or update of format_template_id on public.divisions
  for each row execute function core.tg_division_format_template();

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
    max_entries, format_snapshot, scoring_snapshot, payload_hash, format_template_id)
  values (p_id, v_org, p_event_id, v_name, p_category_id, p_format, p_gender, v_age, p_min_rank_id, p_max_rank_id,
    p_max_entries, v_tpl.stages, v_rule_snap, v_hash, v_tpl.id)
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
      and (r.format_template_id is null or r.format_template_id = dv.format_template_id)
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

