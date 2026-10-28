-- 1740_rank_movement_switch_restore: the Settings switch "Ranks move up and down after events" (ranks.movement_enabled,
-- added to the rank engine in 1550) was dropped when 1640 and 1650 rewrote core.apply_rank_movement. With the switch
-- off, divisions still finalize and results are kept, but nobody's rank moves. Otherwise the function is as 1650: the
-- per-event opt-out (apply_cpc_rank_changes) and format-template rules are unchanged.

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
