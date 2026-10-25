-- 1510_rank_corrections (PLAN 8.2): corrections after finalization, and administrator rank overrides.
--   * A result corrected (correct_match) in a FINALIZED division re-evaluates the division: if the placements or brackets
--     changed, every rank move of that division is reversed (a reversing rank_history row per move, restoring the member relative
--     to where they are now, so a later change is kept), the old results are marked superseded (never edited), and the
--     corrected placements are applied by the same rules as a new revision. If nothing changed, nobody moves.
--   * override_member_rank (ranks.override): sets a member's rank with a written reason; recorded in rank_history (no division,
--     no rule), audited, idempotent by key. Members cannot change their own rank.
--   rank_history is unique per division, member and revision; division_results are unique per live (not superseded) entry.

alter table public.division_results
  add column superseded_at timestamptz,
  add column superseded_by text,
  add column revision integer not null default 1 constraint division_results_revision_chk check (revision >= 1);
alter table public.division_results drop constraint division_results_uq;
create unique index division_results_live_uq on public.division_results (division_id, entry_id) where superseded_at is null;

-- Results stay immutable; the only change allowed is marking a row superseded.
create or replace function core.tg_division_results_frozen() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.superseded_at is null and new.superseded_at is not null
     and (old.division_id, old.entry_id, old.placement, old.bracket_tier, old.bracket_result, old.revision)
         is not distinct from (new.division_id, new.entry_id, new.placement, new.bracket_tier, new.bracket_result, new.revision) then
    return new;
  end if;
  raise exception 'division results are final' using errcode = '42501';
end $$;

alter table public.rank_history add column revision integer not null default 1 constraint rank_history_revision_chk check (revision >= 1);
drop index public.rank_history_division_member_uq;
create unique index rank_history_division_member_uq on public.rank_history (division_id, member_id, revision)
  where reverses_id is null and division_id is not null;

-- ---------------------------------------------------------------------------
-- rank movement for a revision (replaces 1500: live results only, and the revision on every row)
-- ---------------------------------------------------------------------------
drop function core.apply_rank_movement(text);
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

-- ---------------------------------------------------------------------------
-- re-evaluating a finalized division after a correction
-- ---------------------------------------------------------------------------
create or replace function core.reapply_division(p_division_id text, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  dv public.divisions;
  v_rev integer;
  h record;
  v_cur public.member_ranks;
  v_target text;
  v_delta integer;
  v_idx_from integer;
  v_idx_to integer;
  v_reversed integer := 0;
  v_count integer;
  v_moves jsonb;
  v_actor text := coalesce(core.current_profile_id(), 'system');
begin
  select * into dv from public.divisions where id = p_division_id for update;
  if dv.status <> 'finalized' then
    return null;
  end if;
  -- nothing changed: nobody moves
  if not exists (
    select 1 from core.compute_placements(dv.id) p
    full join (select * from public.division_results x where x.division_id = dv.id and x.superseded_at is null) r on r.entry_id = p.entry_id
    where p.entry_id is null or r.entry_id is null
       or (p.placement, p.bracket_tier, p.bracket_result) is distinct from (r.placement, r.bracket_tier, r.bracket_result)
  ) then
    return jsonb_build_object('changed', false);
  end if;
  select coalesce(max(revision), 1) + 1 into v_rev from public.division_results where division_id = dv.id;

  -- reverse every move of this division, relative to where the member is now
  for h in
    select x.* from public.rank_history x
    where x.division_id = dv.id and x.reverses_id is null
      and not exists (select 1 from public.rank_history y where y.reverses_id = x.id)
    order by x.id
  loop
    select * into v_cur from public.member_ranks mr where mr.member_id = h.member_id and mr.deleted_at is null;
    if not found then
      continue;
    end if;
    select c.idx into v_idx_from from core.rank_chain(dv.org_id) c where c.rank_id = h.from_rank_id;
    select c.idx into v_idx_to from core.rank_chain(dv.org_id) c where c.rank_id = h.to_rank_id;
    v_delta := coalesce(v_idx_from, 0) - coalesce(v_idx_to, 0);
    v_target := case when v_delta = 0 then v_cur.rank_id else core.rank_move(v_cur.rank_id, v_delta) end;
    insert into public.rank_history (org_id, member_id, from_rank_id, to_rank_id, rule_id, division_id, event_id, reason, reverses_id, revision)
    values (dv.org_id, h.member_id, v_cur.rank_id, v_target, h.rule_id, dv.id, dv.event_id,
      'Reversed after a correction: ' || coalesce(p_reason, ''), h.id, h.revision);
    if v_target <> v_cur.rank_id then
      update public.member_ranks set rank_id = v_target where id = v_cur.id;
    end if;
    v_reversed := v_reversed + 1;
  end loop;

  update public.division_results set superseded_at = now(), superseded_by = v_actor where division_id = dv.id and superseded_at is null;
  insert into public.division_results (org_id, division_id, entry_id, placement, bracket_tier, bracket_result, revision)
  select dv.org_id, dv.id, p.entry_id, p.placement, p.bracket_tier, p.bracket_result, v_rev from core.compute_placements(dv.id) p;
  get diagnostics v_count = row_count;
  v_moves := core.apply_rank_movement(dv.id, v_rev);
  perform core.write_audit(dv.org_id, 'division.reapply', 'public.divisions', dv.id, null,
    jsonb_build_object('revision', v_rev, 'reversed', v_reversed, 'results', v_count, 'reason', p_reason) || v_moves);
  return jsonb_build_object('changed', true, 'revision', v_rev, 'reversed', v_reversed) || v_moves;
end $$;
revoke all on function core.reapply_division(text, text) from public, anon, authenticated;
grant execute on function core.reapply_division(text, text) to service_role;

-- finalize_division passes the first revision
create or replace function core.finalize_division(p_division_id text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  dv public.divisions;
  v_moves jsonb;
  v_count integer;
begin
  select * into dv from public.divisions x where x.id = p_division_id for update;
  if not found then
    raise exception 'division not found' using errcode = '22023';
  end if;
  if not core.has_permission(dv.org_id, null, 'scores.finalize') then
    raise exception 'you do not have permission to finalize a division' using errcode = '42501';
  end if;
  if dv.status = 'finalized' then
    return jsonb_build_object('division_id', dv.id, 'status', 'finalized', 'unchanged', true);
  end if;
  if dv.status <> 'in_progress' then
    raise exception 'only a division that is under way can be finalized (this one is %)', dv.status using errcode = '22023';
  end if;
  if exists (select 1 from public.division_stages s where s.division_id = dv.id and s.status not in ('completed', 'cancelled')) then
    raise exception 'every stage must be completed first' using errcode = '22023';
  end if;
  insert into public.division_results (org_id, division_id, entry_id, placement, bracket_tier, bracket_result)
  select dv.org_id, dv.id, p.entry_id, p.placement, p.bracket_tier, p.bracket_result from core.compute_placements(dv.id) p;
  get diagnostics v_count = row_count;
  if v_count = 0 then
    raise exception 'there are no results to finalize' using errcode = '22023';
  end if;
  update public.divisions set status = 'finalized', finalized_at = now(), finalized_by = coalesce(core.current_profile_id(), 'system')
  where id = dv.id;
  v_moves := core.apply_rank_movement(dv.id, 1);
  if not exists (select 1 from public.divisions x where x.event_id = dv.event_id and x.status not in ('finalized', 'cancelled')) then
    update public.events set status = 'completed' where id = dv.event_id and status = 'in_progress';
  end if;
  perform core.write_audit(dv.org_id, 'division.finalize', 'public.divisions', dv.id, null,
    jsonb_build_object('results', v_count) || v_moves);
  return jsonb_build_object('division_id', dv.id, 'status', 'finalized', 'results', v_count) || v_moves;
end $$;

-- correct_match (1410) with the re-evaluation step
create or replace function core.correct_match(p_match_id text, p_reason text, p_games jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  m public.matches;
  v_new public.matches;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_final public.score_events;
  v_feed public.matches;
  v_i integer;
  v_n integer;
  v_result jsonb;
  v_winner text;
  v_old_slot_entry text;
  v_reapply jsonb;
  v_division text;
begin
  select * into m from public.matches x where x.id = p_match_id for update;
  if not found then
    raise exception 'match not found' using errcode = '22023';
  end if;
  if not core.has_permission(m.org_id, null, 'scores.correct') then
    raise exception 'you do not have permission to correct scores' using errcode = '42501';
  end if;
  if m.status not in ('completed', 'forfeited') then
    raise exception 'only a finished match can be corrected' using errcode = '22023';
  end if;
  if v_reason is null or char_length(v_reason) < 3 or char_length(v_reason) > 500 then
    raise exception 'a reason of 3 to 500 characters is required' using errcode = '22023';
  end if;
  if jsonb_typeof(p_games) <> 'array' or jsonb_array_length(p_games) < 1 then
    raise exception 'send the corrected games as a list' using errcode = '22023';
  end if;
  select e.* into v_final from public.score_events e
  where e.match_id = m.id and e.kind = 'finalized' and not exists (select 1 from public.score_events r where r.reverses_id = e.id)
  order by e.occurred_at desc, e.id desc limit 1;
  if not found then
    raise exception 'the match has no final result to correct' using errcode = '22023';
  end if;

  v_n := jsonb_array_length(p_games);
  -- Replacement match at the same position; the old one is voided first so the position is free.
  update public.matches set status = 'void', status_reason = 'Corrected: ' || v_reason where id = m.id;
  insert into public.score_events (org_id, match_id, kind, payload, reverses_id)
  values (m.org_id, m.id, 'corrected', jsonb_build_object('reason', v_reason), v_final.id);
  insert into public.matches (org_id, division_stage_id, round_no, match_no, group_label, entry_a_id, entry_b_id, feeds_match_id,
    slot, court_id, scheduled_at, referee_member_id)
  values (m.org_id, m.division_stage_id, m.round_no, m.match_no, m.group_label, m.entry_a_id, m.entry_b_id, m.feeds_match_id,
    m.slot, m.court_id, m.scheduled_at, m.referee_member_id)
  returning * into v_new;
  for v_i in 1..v_n loop
    insert into public.match_games (org_id, match_id, game_no, score_a, score_b)
    values (v_new.org_id, v_new.id, v_i, (p_games -> (v_i - 1) ->> 'a')::integer, (p_games -> (v_i - 1) ->> 'b')::integer);
  end loop;
  -- If the winner changed and the next match already holds the old winner, this raises and everything above rolls back.
  v_result := core.apply_final(v_new.id);
  -- A correction in a finalized division re-evaluates its placements and rank movement.
  select s.division_id into v_division from public.division_stages s where s.id = m.division_stage_id;
  if exists (select 1 from public.divisions d where d.id = v_division and d.status = 'finalized') then
    v_reapply := core.reapply_division(v_division, v_reason);
  end if;
  perform core.write_audit(m.org_id, 'match.correct', 'public.matches', m.id,
    jsonb_build_object('winner_entry_id', m.winner_entry_id), jsonb_build_object('new_match_id', v_new.id, 'reason', v_reason,
      'winner_entry_id', v_result ->> 'winner_entry_id'));
  return v_result || jsonb_build_object('old_match_id', m.id, 'new_match_id', v_new.id)
    || case when v_reapply is null then '{}'::jsonb else jsonb_build_object('ranks', v_reapply) end;
end $$;

-- results for the screens: live results, and the rank change that is still in force (not reversed)
create or replace function core.division_results_view(p_division_id text)
returns table (placement integer, entry_id text, entry_name text, bracket_tier text, bracket_result text,
  rank_from text, rank_to text, rule_name text)
language sql stable security definer set search_path = '' as $$
  with live as (
    select h.* from public.rank_history h
    where h.division_id = p_division_id and h.reverses_id is null
      and not exists (select 1 from public.rank_history y where y.reverses_id = h.id)
  )
  select r.placement, r.entry_id, core.entry_name(r.entry_id), r.bracket_tier, r.bracket_result,
    case when core.has_permission(r.org_id, null, 'members.read') then
      (select string_agg(rf.name, ' / ' order by h.member_id) from public.entry_members em
         join live h on h.member_id = em.member_id join public.ranks rf on rf.id = h.from_rank_id where em.entry_id = r.entry_id) end,
    case when core.has_permission(r.org_id, null, 'members.read') then
      (select string_agg(rt.name, ' / ' order by h.member_id) from public.entry_members em
         join live h on h.member_id = em.member_id join public.ranks rt on rt.id = h.to_rank_id where em.entry_id = r.entry_id) end,
    case when core.has_permission(r.org_id, null, 'members.read') then
      (select max(ru.name) from public.entry_members em
         join live h on h.member_id = em.member_id join public.rank_rules ru on ru.id = h.rule_id where em.entry_id = r.entry_id) end
  from public.division_results r
  where r.division_id = p_division_id and r.superseded_at is null
  order by r.placement, core.entry_name(r.entry_id)
$$;

-- ---------------------------------------------------------------------------
-- administrator override
-- ---------------------------------------------------------------------------
create or replace function core.override_member_rank(p_member_id text, p_rank_id text, p_reason text, p_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  m public.members;
  v_cur public.member_ranks;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_replay jsonb;
  v_response jsonb;
begin
  select * into m from public.members x where x.id = p_member_id and x.deleted_at is null;
  if not found then
    raise exception 'member not found' using errcode = '22023';
  end if;
  if not core.has_permission(m.org_id, null, 'ranks.override') then
    raise exception 'you do not have permission to override a rank' using errcode = '42501';
  end if;
  if m.profile_id is not null and m.profile_id = core.current_profile_id() then
    raise exception 'you cannot change your own rank' using errcode = '42501';
  end if;
  if v_reason is null or char_length(v_reason) < 3 or char_length(v_reason) > 500 then
    raise exception 'a reason of 3 to 500 characters is required' using errcode = '22023';
  end if;
  v_replay := core.idem_begin(p_key, m.org_id, 'rank.override', jsonb_build_object('member', p_member_id, 'rank', p_rank_id, 'reason', v_reason));
  if v_replay is not null then
    return v_replay;
  end if;
  if not exists (select 1 from core.rank_chain(m.org_id) c where c.rank_id = p_rank_id) then
    raise exception 'choose a rank from the club''s ladders' using errcode = '22023';
  end if;
  select * into v_cur from public.member_ranks mr where mr.member_id = m.id and mr.deleted_at is null for update;
  if found and v_cur.rank_id = p_rank_id then
    raise exception 'the member is already at that rank' using errcode = '22023';
  end if;
  insert into public.rank_history (org_id, member_id, from_rank_id, to_rank_id, reason)
  values (m.org_id, m.id, case when found then v_cur.rank_id end, p_rank_id, 'Override: ' || v_reason);
  if found then
    update public.member_ranks set rank_id = p_rank_id, set_by_rule_id = null, source_division_id = null where id = v_cur.id;
  else
    insert into public.member_ranks (org_id, member_id, rank_id) values (m.org_id, m.id, p_rank_id);
  end if;
  perform core.write_audit(m.org_id, 'rank.override', 'public.member_ranks', m.id,
    jsonb_build_object('rank_id', case when found then v_cur.rank_id end), jsonb_build_object('rank_id', p_rank_id, 'reason', v_reason));
  v_response := jsonb_build_object('member_id', m.id, 'rank_id', p_rank_id);
  perform core.idem_complete(p_key, v_response);
  return v_response;
end $$;
create or replace function public.override_member_rank(p_member_id text, p_rank_id text, p_reason text, p_key text) returns jsonb
language sql security invoker set search_path = '' as $$ select core.override_member_rank(p_member_id, p_rank_id, p_reason, p_key) $$;
revoke all on function core.override_member_rank(text, text, text, text), public.override_member_rank(text, text, text, text) from public, anon, authenticated;
grant execute on function core.override_member_rank(text, text, text, text), public.override_member_rank(text, text, text, text) to authenticated, service_role;
