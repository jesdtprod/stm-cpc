-- 1500_rank_engine (PLAN 8.1): division finalization and rank movement (FEATURES 8.3, 8.4), and the split single elimination stage
-- that the club's H / L rank rule needs.
--   * Split single elimination: round 1 for everyone (an odd entry gets a bye); when it is over the winners (and the bye)
--     play a single elimination "H bracket" and the losers an "L bracket", both inside the same stage (matches carry the
--     group label H or L; the L matches are numbered from 101 so positions stay unique).
--   * compute_placements: the final placements of a division from its stages (round robin standings; knockout rounds, losers
--     of a round share a place; pool play knockout advancers first, then the bracket players by finish and record; split:
--     H finishers above L finishers, each bracket's champion has bracket_result "won").
--   * finalize_division (scores.finalize): needs every stage completed; writes the immutable division_results, marks the
--     division finalized and applies rank movement once. Finalizing again returns the same outcome and changes nothing.
--   * apply_rank_movement: for each member of each entry the first active rule (by priority) whose conditions fit moves
--     them up or down along the chain of ladders (edges stop; a ladder may stop movement at its own edge), within the rule's
--     own min and max rank. Forfeits (when the rule excludes them) and a cooldown leave the rank as it is. Every result is a
--     rank_history row (unique per division and member), so retrying cannot move anyone twice.

-- ---------------------------------------------------------------------------
-- bracket builder: groups and offsets
-- ---------------------------------------------------------------------------
drop function core.insert_seeded_matches(text, text[], text[]);
create or replace function core.insert_seeded_matches(p_stage_id text, p_order text[], p_labels text[] default null,
  p_group text default null, p_round_offset integer default 0, p_match_offset integer default 0) returns void
language plpgsql security definer set search_path = '' as $$
declare
  st public.division_stages;
  v_ids jsonb := '{}'::jsonb;
  row record;
  v_id text;
  v_feed text;
begin
  select * into st from public.division_stages where id = p_stage_id;
  for row in select * from core.se_layout(cardinality(p_order)) order by round_no desc, match_no loop
    v_feed := case when row.feeds_round is null then null else v_ids ->> (row.feeds_round || '-' || row.feeds_match) end;
    insert into public.matches (org_id, division_stage_id, round_no, match_no, group_label, entry_a_id, entry_b_id, feeds_match_id, slot, meta)
    values (st.org_id, st.id, row.round_no + p_round_offset, row.match_no + p_match_offset, p_group,
      case when row.seed_a is null then null else p_order[row.seed_a] end,
      case when row.seed_b is null then null else p_order[row.seed_b] end,
      v_feed, row.slot,
      case when p_labels is null or row.seed_a is null then '{}'::jsonb
           else jsonb_build_object('a_label', p_labels[row.seed_a], 'b_label', case when row.seed_b is null then null else p_labels[row.seed_b] end) end)
    returning id into v_id;
    v_ids := v_ids || jsonb_build_object(row.round_no || '-' || row.match_no, v_id);
  end loop;
end $$;
revoke all on function core.insert_seeded_matches(text, text[], text[], text, integer, integer) from public, anon, authenticated;
grant execute on function core.insert_seeded_matches(text, text[], text[], text, integer, integer) to service_role;

-- ---------------------------------------------------------------------------
-- split single elimination
-- ---------------------------------------------------------------------------
create or replace function core.build_split_round1(p_stage_id text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  st public.division_stages;
  d public.draws;
  v_order text[];
  k integer;
begin
  select * into st from public.division_stages where id = p_stage_id;
  if st.stage_no <> 1 or st.stage_type <> 'split_single_elimination' then
    return;
  end if;
  if exists (select 1 from public.matches m where m.division_stage_id = st.id and m.status <> 'void') then
    return;
  end if;
  select * into d from public.draws x where x.division_stage_id = st.id and x.status = 'active';
  if not found then
    return;
  end if;
  select array_agg(v order by ord) into v_order from jsonb_array_elements_text(d.result -> 'order') with ordinality as t(v, ord);
  for k in 1..(cardinality(v_order) / 2) loop
    insert into public.matches (org_id, division_stage_id, round_no, match_no, entry_a_id, entry_b_id)
    values (st.org_id, st.id, 1, k, v_order[2 * k - 1], v_order[2 * k]);
  end loop;
end $$;
revoke all on function core.build_split_round1(text) from public, anon, authenticated;
grant execute on function core.build_split_round1(text) to service_role;

-- When round 1 is over: winners (and the bye) into the H bracket, losers into the L bracket, in round-1 order.
create or replace function core.build_split_brackets(p_stage_id text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  st public.division_stages;
  d public.draws;
  v_h text[];
  v_l text[];
  v_bye text;
begin
  select * into st from public.division_stages where id = p_stage_id;
  select array_agg(m.winner_entry_id order by m.match_no),
         array_agg(case when m.winner_entry_id = m.entry_a_id then m.entry_b_id else m.entry_a_id end order by m.match_no)
    into v_h, v_l
  from public.matches m where m.division_stage_id = st.id and m.round_no = 1 and m.group_label is null and m.status in ('completed', 'forfeited');
  select * into d from public.draws x where x.division_stage_id = st.id and x.status = 'active';
  select e into v_bye from jsonb_array_elements_text(d.result -> 'order') e
  where not exists (select 1 from public.matches m where m.division_stage_id = st.id and m.round_no = 1 and m.status <> 'void'
                    and e in (m.entry_a_id, m.entry_b_id));
  if v_bye is not null then
    v_h := coalesce(v_h, '{}') || v_bye; -- an odd entry has a bye and counts as a winner, joining the H bracket
  end if;
  if cardinality(coalesce(v_h, '{}')) >= 2 then
    perform core.insert_seeded_matches(st.id, v_h, null, 'H', 1, 0);
  end if;
  if cardinality(coalesce(v_l, '{}')) >= 2 then
    perform core.insert_seeded_matches(st.id, v_l, null, 'L', 1, 100);
  end if;
end $$;
revoke all on function core.build_split_brackets(text) from public, anon, authenticated;
grant execute on function core.build_split_brackets(text) to service_role;

create or replace function core.build_stage_matches(p_stage_id text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  st public.division_stages;
begin
  select * into st from public.division_stages where id = p_stage_id;
  if not found then
    return;
  end if;
  if st.stage_type = 'round_robin' then
    perform core.build_round_robin(st.id);
  elsif st.stage_type = 'single_elimination' then
    perform core.build_single_elimination(st.id);
  elsif st.stage_type = 'pool_play' then
    perform core.build_pool_play(st.id);
  elsif st.stage_type = 'split_single_elimination' then
    perform core.build_split_round1(st.id);
  end if;
end $$;

create or replace function core.tg_match_progress() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  st public.division_stages;
  v_done boolean := false;
begin
  if new.status is not distinct from old.status then
    return null;
  end if;
  select * into st from public.division_stages where id = new.division_stage_id;
  if new.status in ('in_progress', 'completed', 'forfeited') then
    update public.division_stages set status = 'in_progress' where id = st.id and status = 'drawn';
    update public.divisions set status = 'in_progress' where id = st.division_id and status = 'drawn';
    update public.events set status = 'in_progress'
    where id = (select event_id from public.divisions where id = st.division_id) and status = 'drawn';
  end if;
  if new.status in ('completed', 'forfeited', 'cancelled') then
    if not exists (select 1 from public.matches m where m.division_stage_id = st.id and m.status in ('scheduled', 'in_progress'))
       and exists (select 1 from public.matches m where m.division_stage_id = st.id and m.status in ('completed', 'forfeited')) then
      -- a split stage is not over when round 1 is: the H and L brackets are built now
      if st.stage_type = 'split_single_elimination'
         and not exists (select 1 from public.matches m where m.division_stage_id = st.id and m.group_label in ('H', 'L')) then
        perform core.build_split_brackets(st.id);
      end if;
      if not exists (select 1 from public.matches m where m.division_stage_id = st.id and m.status in ('scheduled', 'in_progress')) then
        update public.division_stages set status = 'completed' where id = st.id and status = 'in_progress' returning true into v_done;
        if v_done then
          perform core.start_next_stage(st.id);
        end if;
      end if;
    end if;
  end if;
  return null;
end $$;

-- ---------------------------------------------------------------------------
-- placements
-- ---------------------------------------------------------------------------
-- Knockout placements inside one bracket: the champion is base+1; the loser of a round with k rounds still to play is
-- base + 2^k + 1 (final loser base+2, semifinal losers base+3, quarterfinal losers base+5 ...).
create or replace function core.elim_placements(p_stage_id text, p_group text, p_base integer)
returns table (entry_id text, placement integer)
language sql stable security definer set search_path = '' as $$
  with ms as (
    select m.round_no, m.winner_entry_id w,
      case when m.winner_entry_id = m.entry_a_id then m.entry_b_id else m.entry_a_id end l
    from public.matches m
    where m.division_stage_id = p_stage_id and m.status in ('completed', 'forfeited') and m.group_label is not distinct from p_group
  ), span as (select min(round_no) mn, max(round_no) mx from ms)
  select ms.l, p_base + (2 ^ ((span.mx - span.mn + 1) - (ms.round_no - span.mn + 1)))::integer + 1
  from ms, span
  union all
  select ms.w, p_base + 1 from ms, span where ms.round_no = span.mx
$$;
revoke all on function core.elim_placements(text, text, integer) from public, anon, authenticated;
grant execute on function core.elim_placements(text, text, integer) to service_role;

create or replace function core.compute_placements(p_division_id text)
returns table (entry_id text, placement integer, bracket_tier text, bracket_result text)
language plpgsql stable security definer set search_path = '' as $$
declare
  lst public.division_stages;
  prv public.division_stages;
  v_m integer;
  v_n integer;
  v_h integer;
  v_l integer;
  v_one text;
begin
  select * into lst from public.division_stages s
  where s.division_id = p_division_id and s.status = 'completed' order by s.stage_no desc limit 1;
  if not found then
    return;
  end if;
  if lst.stage_type = 'round_robin' then
    return query select s.entry_id, s.place, null::text, null::text from core.stage_standings(lst.id) s;
  elsif lst.stage_type = 'single_elimination' and lst.stage_no = 1 then
    return query select p.entry_id, p.placement, null::text, null::text from core.elim_placements(lst.id, null, 0) p;
  elsif lst.stage_type = 'single_elimination' then
    select * into prv from public.division_stages s where s.division_id = p_division_id and s.stage_no = lst.stage_no - 1;
    select count(*) into v_m from core.elim_placements(lst.id, null, 0);
    return query
    select p.entry_id, p.placement, null::text, null::text from core.elim_placements(lst.id, null, 0) p
    union all
    select q.entry_id, v_m + (rank() over (order by q.place, q.wins desc, q.diff desc))::integer, null::text, null::text
    from (select s.entry_id, s.place, s.wins, s.points_for - s.points_against as diff from core.stage_standings(prv.id) s
          where s.entry_id not in (select x.entry_id from core.elim_placements(lst.id, null, 0) x)) q;
  elsif lst.stage_type = 'split_single_elimination' then
    select count(*) into v_n from public.entries e where e.division_id = p_division_id and e.status = 'active';
    v_h := (v_n + 1) / 2;
    v_l := v_n / 2;
    -- H bracket (or a lone H entrant)
    if exists (select 1 from public.matches m where m.division_stage_id = lst.id and m.group_label = 'H') then
      return query select p.entry_id, p.placement, 'H'::text, case when p.placement = 1 then 'won' else 'lost' end
        from core.elim_placements(lst.id, 'H', 0) p;
    else
      select m.winner_entry_id into v_one from public.matches m where m.division_stage_id = lst.id and m.round_no = 1 and m.status in ('completed', 'forfeited') limit 1;
      return query select v_one, 1, 'H'::text, 'won'::text;
    end if;
    if exists (select 1 from public.matches m where m.division_stage_id = lst.id and m.group_label = 'L') then
      return query select p.entry_id, p.placement, 'L'::text, case when p.placement = v_h + 1 then 'won' else 'lost' end
        from core.elim_placements(lst.id, 'L', v_h) p;
    elsif v_l = 1 then
      select case when m.winner_entry_id = m.entry_a_id then m.entry_b_id else m.entry_a_id end into v_one
      from public.matches m where m.division_stage_id = lst.id and m.round_no = 1 and m.status in ('completed', 'forfeited') limit 1;
      return query select v_one, v_h + 1, 'L'::text, 'won'::text;
    end if;
  end if;
end $$;
revoke all on function core.compute_placements(text) from public, anon, authenticated;
grant execute on function core.compute_placements(text) to service_role;

-- ---------------------------------------------------------------------------
-- the chain of ranks
-- ---------------------------------------------------------------------------
create or replace function core.rank_chain(p_org text)
returns table (rank_id text, idx integer, ladder_id text, overflow text)
language sql stable security definer set search_path = '' as $$
  select r.id, (row_number() over (order by c.sort_order, c.code, r.sort_order, r.id))::integer, l.id, l.overflow
  from public.ranks r
  join public.rank_ladders l on l.id = r.ladder_id and l.deleted_at is null and l.is_active
  join public.categories c on c.id = l.category_id and c.deleted_at is null
  where r.org_id = p_org and r.deleted_at is null
$$;
revoke all on function core.rank_chain(text) from public, anon, authenticated;
grant execute on function core.rank_chain(text) to service_role;

-- Moves p_delta places along the chain (negative is down). Edges stop; a ladder set to "stop" does not pass its own edge.
create or replace function core.rank_move(p_rank_id text, p_delta integer) returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  v_org text;
  cur record;
  nxt record;
  v_steps integer := abs(p_delta);
  v_dir integer := case when p_delta >= 0 then 1 else -1 end;
  i integer;
begin
  select org_id into v_org from public.ranks where id = p_rank_id;
  select * into cur from core.rank_chain(v_org) c where c.rank_id = p_rank_id;
  if not found then
    return p_rank_id;
  end if;
  for i in 1..v_steps loop
    select * into nxt from core.rank_chain(v_org) c where c.idx = cur.idx + v_dir;
    exit when not found;
    exit when nxt.ladder_id <> cur.ladder_id and cur.overflow = 'stop';
    cur := nxt;
  end loop;
  return cur.rank_id;
end $$;
revoke all on function core.rank_move(text, integer) from public, anon, authenticated;
grant execute on function core.rank_move(text, integer) to service_role;

-- ---------------------------------------------------------------------------
-- rank movement
-- ---------------------------------------------------------------------------
create or replace function core.apply_rank_movement(p_division_id text) returns jsonb
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
  for res in select r.* from public.division_results r where r.division_id = dv.id loop
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
          and h.occurred_at > now() - rule.cooldown_days * interval '1 day') then
        v_reason := 'Not moved: still in the cooldown after the lst change';
      elsif rule.action <> 'retain' then
        v_new := core.rank_move(v_cur.rank_id, case when rule.action = 'up' then rule.levels else -rule.levels end);
        select c.idx into v_idx_cur from core.rank_chain(dv.org_id) c where c.rank_id = v_cur.rank_id;
        select c.idx into v_idx_new from core.rank_chain(dv.org_id) c where c.rank_id = v_new;
        -- the rule's own limits: never past its maximum rank going up or its minimum going down, and never backwards
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
      insert into public.rank_history (org_id, member_id, from_rank_id, to_rank_id, rule_id, division_id, event_id, reason)
      values (dv.org_id, mem.member_id, v_cur.rank_id, v_new, rule.id, dv.id, dv.event_id, v_reason);
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
revoke all on function core.apply_rank_movement(text) from public, anon, authenticated;
grant execute on function core.apply_rank_movement(text) to service_role;

-- ---------------------------------------------------------------------------
-- finalizing a division
-- ---------------------------------------------------------------------------
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
  v_moves := core.apply_rank_movement(dv.id);
  -- the lst live division finalized completes the event
  if not exists (select 1 from public.divisions x where x.event_id = dv.event_id and x.status not in ('finalized', 'cancelled')) then
    update public.events set status = 'completed' where id = dv.event_id and status = 'in_progress';
  end if;
  perform core.write_audit(dv.org_id, 'division.finalize', 'public.divisions', dv.id, null,
    jsonb_build_object('results', v_count) || v_moves);
  return jsonb_build_object('division_id', dv.id, 'status', 'finalized', 'results', v_count) || v_moves;
end $$;
create or replace function public.finalize_division(p_division_id text) returns jsonb
language sql security invoker set search_path = '' as $$ select core.finalize_division(p_division_id) $$;
revoke all on function core.finalize_division(text), public.finalize_division(text) from public, anon, authenticated;
grant execute on function core.finalize_division(text), public.finalize_division(text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- results for the screens (rank changes only for staff who can read members)
-- ---------------------------------------------------------------------------
create or replace function core.division_results_view(p_division_id text)
returns table (placement integer, entry_id text, entry_name text, bracket_tier text, bracket_result text,
  rank_from text, rank_to text, rule_name text)
language sql stable security definer set search_path = '' as $$
  select r.placement, r.entry_id, core.entry_name(r.entry_id), r.bracket_tier, r.bracket_result,
    case when core.has_permission(r.org_id, null, 'members.read') then
      (select string_agg(rf.name, ' / ' order by h.member_id) from public.entry_members em
         join public.rank_history h on h.member_id = em.member_id and h.division_id = r.division_id and h.reverses_id is null
         join public.ranks rf on rf.id = h.from_rank_id where em.entry_id = r.entry_id) end,
    case when core.has_permission(r.org_id, null, 'members.read') then
      (select string_agg(rt.name, ' / ' order by h.member_id) from public.entry_members em
         join public.rank_history h on h.member_id = em.member_id and h.division_id = r.division_id and h.reverses_id is null
         join public.ranks rt on rt.id = h.to_rank_id where em.entry_id = r.entry_id) end,
    case when core.has_permission(r.org_id, null, 'members.read') then
      (select max(ru.name) from public.entry_members em
         join public.rank_history h on h.member_id = em.member_id and h.division_id = r.division_id and h.reverses_id is null
         join public.rank_rules ru on ru.id = h.rule_id where em.entry_id = r.entry_id) end
  from public.division_results r
  where r.division_id = p_division_id
  order by r.placement, core.entry_name(r.entry_id)
$$;
revoke all on function core.division_results_view(text) from public, anon, authenticated;
grant execute on function core.division_results_view(text) to authenticated, service_role;

create or replace function public.division_results_view(p_division_id text)
returns table (placement integer, entry_id text, entry_name text, bracket_tier text, bracket_result text,
  rank_from text, rank_to text, rule_name text)
language sql stable security invoker set search_path = '' as $$
  select s.* from core.division_results_view(p_division_id) s
  where exists (select 1 from public.divisions d where d.id = p_division_id and d.status = 'finalized'
                and exists (select 1 from public.events e where e.id = d.event_id))
$$;
revoke all on function public.division_results_view(text) from public, anon, authenticated;
grant execute on function public.division_results_view(text) to authenticated, service_role;
