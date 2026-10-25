-- 1470_single_elimination (PLAN 7.4): the single elimination stage.
--   * se_slots(P): the standard bracket order for a bracket of P places (a power of two), for example 8 gives 1,8,4,5,2,7,3,6,
--     so seed 1 and seed 2 can only meet in the final, and 1 plays 8, 4 plays 5, and so on.
--   * se_layout(n): the matches of a bracket for n entries. The bracket is the next power of two; the best seeds get a bye
--     when n is not a power of two (a bye is no match: the seed goes straight into round 2). Always n-1 matches.
--   * build_single_elimination: creates the matches of a stage from the active draw (the draw position is the seed), each
--     winner feeding the next round's slot. The generator hook from 1460 now also builds this type, from the first stage.
-- The optional third-place game is not built yet (the stage setting is ignored).

create or replace function core.se_slots(p integer) returns integer[]
language plpgsql immutable set search_path = '' as $$
declare
  v integer[] := array[1];
  m integer := 1;
  nxt integer[];
  x integer;
begin
  if p < 1 or (p & (p - 1)) <> 0 then
    raise exception 'a bracket has a power of two places' using errcode = '22023';
  end if;
  while m < p loop
    nxt := '{}';
    foreach x in array v loop
      nxt := nxt || x || (2 * m + 1 - x);
    end loop;
    v := nxt;
    m := m * 2;
  end loop;
  return v;
end $$;
revoke all on function core.se_slots(integer) from public, anon, authenticated;
grant execute on function core.se_slots(integer) to service_role;

-- One row per match. seed_a/seed_b are known only where a bye puts a seed straight into round 2 or where round 1 pairs two seeds.
create or replace function core.se_layout(n integer)
returns table (round_no integer, match_no integer, seed_a integer, seed_b integer, feeds_round integer, feeds_match integer, slot text)
language plpgsql immutable set search_path = '' as $$
declare
  p integer := 1;
  r_total integer := 0;
  slots integer[];
  r integer;
  k integer;
  c integer;
  sa integer;
  sb integer;
  bye_a integer;
  bye_b integer;
begin
  if n < 2 then
    return;
  end if;
  while p < n loop
    p := p * 2;
    r_total := r_total + 1;
  end loop;
  slots := core.se_slots(p);
  for r in 1..r_total loop
    c := p / (2 ^ r)::integer;
    for k in 1..c loop
      seed_a := null;
      seed_b := null;
      if r = 1 then
        sa := slots[2 * k - 1];
        sb := slots[2 * k];
        if sa > n or sb > n then
          continue; -- a bye: no match
        end if;
        seed_a := sa;
        seed_b := sb;
      elsif r = 2 then
        -- the two round-1 pairs that feed this match; a pair with a bye sends its seed straight here
        sa := slots[4 * k - 3];
        sb := slots[4 * k - 2];
        bye_a := case when sa > n then sb when sb > n then sa end;
        sa := slots[4 * k - 1];
        sb := slots[4 * k];
        bye_b := case when sa > n then sb when sb > n then sa end;
        seed_a := bye_a;
        seed_b := bye_b;
      end if;
      round_no := r;
      match_no := k;
      if r < r_total then
        feeds_round := r + 1;
        feeds_match := (k + 1) / 2;
        slot := case when k % 2 = 1 then 'a' else 'b' end;
      else
        feeds_round := null;
        feeds_match := null;
        slot := null;
      end if;
      return next;
    end loop;
  end loop;
end $$;
revoke all on function core.se_layout(integer) from public, anon, authenticated;
grant execute on function core.se_layout(integer) to service_role;

create or replace function core.build_single_elimination(p_stage_id text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  st public.division_stages;
  d public.draws;
  v_order text[];
  v_n integer;
  v_ids jsonb := '{}'::jsonb;
  row record;
  v_id text;
  v_feed text;
begin
  select * into st from public.division_stages where id = p_stage_id;
  if st.stage_no <> 1 or st.stage_type <> 'single_elimination' then
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
  v_n := cardinality(v_order);
  -- last round first, so that every match can name the one it feeds
  for row in select * from core.se_layout(v_n) order by round_no desc, match_no loop
    v_feed := case when row.feeds_round is null then null else v_ids ->> (row.feeds_round || '-' || row.feeds_match) end;
    insert into public.matches (org_id, division_stage_id, round_no, match_no, entry_a_id, entry_b_id, feeds_match_id, slot)
    values (st.org_id, st.id, row.round_no, row.match_no,
      case when row.seed_a is null then null else v_order[row.seed_a] end,
      case when row.seed_b is null then null else v_order[row.seed_b] end,
      v_feed, row.slot)
    returning id into v_id;
    v_ids := v_ids || jsonb_build_object(row.round_no || '-' || row.match_no, v_id);
  end loop;
end $$;
revoke all on function core.build_single_elimination(text) from public, anon, authenticated;
grant execute on function core.build_single_elimination(text) to service_role;

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
  end if;
end $$;
