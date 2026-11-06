-- Split single elimination: the H and L brackets exist from the draw, and every Round 1 match feeds them as soon as it is final.
--   * The draw builds Round 1 plus the empty H bracket (the winners) and L bracket (the losers). Slots are named after the
--     Round 1 match they come from ("Winner of Match 3", "Loser of Match 3"), in the order the bracket pairs them
--     (Match 1 and Match 2 meet in the first H match, and so on).
--   * A finished Round 1 match (score, forfeit, disqualification, default or correction) puts its winner in the H bracket and its
--     loser in the L bracket straight away. An odd entry with a bye is already in the H bracket.
--   * Stages drawn before this change have no H and L matches yet: they keep the old rule (built when Round 1 is over).

-- The seed each Round 1 match feeds, in Round 1 order: the k-th value is the bracket seed that Round 1 match k feeds.
create or replace function core.split_seeds(p_n integer) returns integer[]
language plpgsql immutable set search_path = '' as $$
declare
  p integer := 1;
  slots integer[];
  s integer;
  res integer[] := '{}';
begin
  if p_n < 2 then
    return '{}';
  end if;
  while p < p_n loop
    p := p * 2;
  end loop;
  slots := core.se_slots(p);
  foreach s in array slots loop
    if s <= p_n then
      res := array_append(res, s);
    end if;
  end loop;
  return res;
end $$;
revoke all on function core.split_seeds(integer) from public, anon, authenticated;
grant execute on function core.split_seeds(integer) to service_role;

create or replace function core.build_split_round1(p_stage_id text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  st public.division_stages;
  d public.draws;
  v_order text[];
  k integer;
  v_card integer;
  v_nh integer;
  v_nl integer;
  v_seeds integer[];
  v_h text[];
  v_hl text[];
  v_l text[];
  v_ll text[];
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
  v_card := cardinality(v_order);
  for k in 1..(v_card / 2) loop
    insert into public.matches (org_id, division_stage_id, round_no, match_no, entry_a_id, entry_b_id)
    values (st.org_id, st.id, 1, k, v_order[2 * k - 1], v_order[2 * k]);
  end loop;

  -- the empty H and L brackets
  v_nh := (v_card + 1) / 2;
  v_nl := v_card / 2;
  if v_nh >= 2 then
    v_seeds := core.split_seeds(v_nh);
    v_h := array_fill(null::text, array[v_nh]);
    v_hl := array_fill(null::text, array[v_nh]);
    for k in 1..v_nh loop
      if k <= v_card / 2 then
        v_hl[v_seeds[k]] := 'Winner of Match ' || k;
      else
        v_h[v_seeds[k]] := v_order[v_card]; -- an odd entry has a bye and starts in the H bracket
      end if;
    end loop;
    perform core.insert_seeded_matches(st.id, v_h, v_hl, 'H', 1, 0);
  end if;
  if v_nl >= 2 then
    v_seeds := core.split_seeds(v_nl);
    v_l := array_fill(null::text, array[v_nl]);
    v_ll := array_fill(null::text, array[v_nl]);
    for k in 1..v_nl loop
      v_ll[v_seeds[k]] := 'Loser of Match ' || k;
    end loop;
    perform core.insert_seeded_matches(st.id, v_l, v_ll, 'L', 1, 100);
  end if;
end $$;
revoke all on function core.build_split_round1(text) from public, anon, authenticated;
grant execute on function core.build_split_round1(text) to service_role;

-- Puts one entry in the open slot that Round 1 match k feeds. A slot that already holds this entry is fine.
create or replace function core.split_fill(p_stage_id text, p_group text, p_n integer, p_k integer, p_entry text,
  p_round_offset integer, p_match_offset integer) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_seed integer;
  v_round integer;
  v_match integer;
  v_slot text;
  f public.matches;
begin
  if p_n < 2 or p_entry is null then
    return;
  end if;
  v_seed := (core.split_seeds(p_n))[p_k];
  if v_seed is null then
    return;
  end if;
  select l.round_no, l.match_no, case when l.seed_a = v_seed then 'a' else 'b' end
    into v_round, v_match, v_slot
  from core.se_layout(p_n) l where l.seed_a = v_seed or l.seed_b = v_seed limit 1;
  select * into f from public.matches m
  where m.division_stage_id = p_stage_id and m.group_label = p_group
    and m.round_no = v_round + p_round_offset and m.match_no = v_match + p_match_offset and m.status <> 'void';
  if not found then
    return; -- a stage drawn before this rule: the brackets are built when Round 1 is over
  end if;
  if v_slot = 'a' then
    if f.entry_a_id is null then
      update public.matches set entry_a_id = p_entry where id = f.id;
    elsif f.entry_a_id <> p_entry then
      raise exception 'the next match already has a different opponent; void it first' using errcode = '22023';
    end if;
  else
    if f.entry_b_id is null then
      update public.matches set entry_b_id = p_entry where id = f.id;
    elsif f.entry_b_id <> p_entry then
      raise exception 'the next match already has a different opponent; void it first' using errcode = '22023';
    end if;
  end if;
end $$;
revoke all on function core.split_fill(text, text, integer, integer, text, integer, integer) from public, anon, authenticated;
grant execute on function core.split_fill(text, text, integer, integer, text, integer, integer) to service_role;

create or replace function core.advance_winner(p_match_id text, p_winner text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m public.matches;
  f public.matches;
  st public.division_stages;
  v_card integer;
begin
  select * into m from public.matches where id = p_match_id;
  if m.feeds_match_id is null then
    -- Round 1 of a split stage: the winner goes to the H bracket and the loser to the L bracket
    if m.round_no = 1 and m.group_label is null then
      select * into st from public.division_stages where id = m.division_stage_id;
      if st.stage_type = 'split_single_elimination' then
        select jsonb_array_length(d.result -> 'order') into v_card
        from public.draws d where d.division_stage_id = st.id and d.status = 'active';
        if v_card is not null then
          perform core.split_fill(st.id, 'H', (v_card + 1) / 2, m.match_no, p_winner, 1, 0);
          perform core.split_fill(st.id, 'L', v_card / 2, m.match_no,
            case when p_winner = m.entry_a_id then m.entry_b_id else m.entry_a_id end, 1, 100);
        end if;
      end if;
    end if;
    return;
  end if;
  f := core.live_match_of(m.feeds_match_id);
  if m.slot = 'a' then
    if f.entry_a_id is null then
      update public.matches set entry_a_id = p_winner where id = f.id;
    elsif f.entry_a_id <> p_winner then
      raise exception 'the next match already has a different opponent; void it first' using errcode = '22023';
    end if;
  else
    if f.entry_b_id is null then
      update public.matches set entry_b_id = p_winner where id = f.id;
    elsif f.entry_b_id <> p_winner then
      raise exception 'the next match already has a different opponent; void it first' using errcode = '22023';
    end if;
  end if;
end $$;
revoke all on function core.advance_winner(text, text) from public, anon, authenticated;
grant execute on function core.advance_winner(text, text) to service_role;

notify pgrst, 'reload schema';
