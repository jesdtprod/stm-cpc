-- 1480_pool_play (PLAN 7.5): "Regular (Bracketing)": pool play into a crossover knockout (FEATURES 9.2.2).
--   * Stage 1 (pool_play): the drawn entries are split into Brackets A, B, C ... (the number is dynamic: a set count, or a
--     target size, default 5, so 20 entries make 4 brackets of 5; sizes differ by at most 1). Each bracket plays a round robin.
--   * When the last pool match is finished, stage 2 is built from the standings: the best N of each bracket (default 2) enter
--     a knockout. With an even number of brackets and a power-of-two number of advancers the club's rule applies: brackets are
--     paired outside in (A with D, B with C ...) and the same finish meets the same finish (A1 v D1, A2 v D2, B1 v C1, B2 v C2),
--     and the quarterfinal winners meet in the standard order. Any other count falls back to a seeded bracket with byes (best
--     finish first) and says so on the stage. A tie for the last advancing place is settled by a reproducible hash and audited.
--   * set_stage_config: the admin sets the number of brackets, the target size, how many advance and how entries are assigned,
--     before the draw.
--   * stage_matches now also returns where each side came from ("A1"), for the crossover table.

-- ---------------------------------------------------------------------------
-- settings
-- ---------------------------------------------------------------------------
create or replace function core.set_stage_config(p_stage_id text, p_config jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  st public.division_stages;
  dv public.divisions;
  v_clean jsonb := '{}'::jsonb;
  k text;
  v jsonb;
begin
  select * into st from public.division_stages x where x.id = p_stage_id for update;
  if not found then
    raise exception 'stage not found' using errcode = '22023';
  end if;
  if not core.has_permission(st.org_id, null, 'divisions.manage') then
    raise exception 'you do not have permission to change a format' using errcode = '42501';
  end if;
  select * into dv from public.divisions where id = st.division_id;
  if dv.status <> 'open' or st.status <> 'pending' then
    raise exception 'format settings can change only before the draw' using errcode = '22023';
  end if;
  if st.stage_type <> 'pool_play' then
    raise exception 'only a pool play stage has these settings' using errcode = '22023';
  end if;
  if jsonb_typeof(p_config) <> 'object' then
    raise exception 'send the settings as an object' using errcode = '22023';
  end if;
  for k, v in select * from jsonb_each(p_config) loop
    if k = 'group_count' then
      if jsonb_typeof(v) = 'null' then
        v_clean := v_clean || jsonb_build_object(k, null);
      elsif jsonb_typeof(v) <> 'number' or (v #>> '{}')::numeric <> trunc((v #>> '{}')::numeric) or (v #>> '{}')::integer not between 1 and 26 then
        raise exception 'the number of brackets is a whole number from 1 to 26' using errcode = '22023';
      else
        v_clean := v_clean || jsonb_build_object(k, v);
      end if;
    elsif k = 'target_group_size' then
      if jsonb_typeof(v) <> 'number' or (v #>> '{}')::numeric <> trunc((v #>> '{}')::numeric) or (v #>> '{}')::integer not between 3 and 12 then
        raise exception 'the players per bracket is a whole number from 3 to 12' using errcode = '22023';
      end if;
      v_clean := v_clean || jsonb_build_object(k, v);
    elsif k = 'advance_per_group' then
      if jsonb_typeof(v) <> 'number' or (v #>> '{}')::numeric <> trunc((v #>> '{}')::numeric) or (v #>> '{}')::integer not between 1 and 4 then
        raise exception 'the number that advance from each bracket is a whole number from 1 to 4' using errcode = '22023';
      end if;
      v_clean := v_clean || jsonb_build_object(k, v);
    elsif k = 'group_assignment' then
      if v #>> '{}' not in ('random', 'snake_by_rank') then
        raise exception 'brackets are filled randomly or by rank (snake)' using errcode = '22023';
      end if;
      v_clean := v_clean || jsonb_build_object(k, v);
    else
      raise exception 'unknown setting: %', k using errcode = '22023';
    end if;
  end loop;
  update public.division_stages set config = config || v_clean where id = st.id;
  perform core.write_audit(st.org_id, 'stage.config', 'public.division_stages', st.id, null, v_clean);
  return jsonb_build_object('id', st.id, 'config', (select config from public.division_stages where id = st.id));
end $$;
create or replace function public.set_stage_config(p_stage_id text, p_config jsonb) returns jsonb
language sql security invoker set search_path = '' as $$ select core.set_stage_config(p_stage_id, p_config) $$;
revoke all on function core.set_stage_config(text, jsonb), public.set_stage_config(text, jsonb) from public, anon, authenticated;
grant execute on function core.set_stage_config(text, jsonb), public.set_stage_config(text, jsonb) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- the brackets (pools)
-- ---------------------------------------------------------------------------
-- entry -> bracket letter, from the draw order (or from rank order when assigned by rank, then dealt out in a snake)
create or replace function core.pool_assign(p_stage_id text, p_order text[], p_config jsonb)
returns table (entry_id text, group_label text, pos integer)
language plpgsql stable security definer set search_path = '' as $$
declare
  n integer := cardinality(p_order);
  g integer;
  v_size integer := coalesce((p_config ->> 'target_group_size')::integer, 5);
  v_sorted text[];
  i integer;
  v_row integer;
  v_col integer;
begin
  if n < 2 then
    return;
  end if;
  g := coalesce((p_config ->> 'group_count')::integer, ceil(n::numeric / v_size)::integer);
  g := greatest(1, least(g, n / 2, 26));
  if coalesce(p_config ->> 'group_assignment', 'random') = 'snake_by_rank' then
    select array_agg(x.id order by x.rk desc nulls last, x.ord) into v_sorted from (
      select o.id, o.ord, (
        select max(r.sort_order) from public.entry_members em
        join public.member_ranks mr on mr.member_id = em.member_id and mr.deleted_at is null
        join public.ranks r on r.id = mr.rank_id where em.entry_id = o.id) rk
      from unnest(p_order) with ordinality as o(id, ord)) x;
  else
    v_sorted := p_order;
  end if;
  for i in 1..n loop
    v_row := (i - 1) / g;
    v_col := (i - 1) % g;
    if coalesce(p_config ->> 'group_assignment', 'random') = 'snake_by_rank' and v_row % 2 = 1 then
      v_col := g - 1 - v_col;
    end if;
    entry_id := v_sorted[i];
    group_label := chr(65 + v_col);
    pos := i;
    return next;
  end loop;
end $$;
revoke all on function core.pool_assign(text, text[], jsonb) from public, anon, authenticated;
grant execute on function core.pool_assign(text, text[], jsonb) to service_role;

create or replace function core.build_pool_play(p_stage_id text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  st public.division_stages;
  d public.draws;
  v_order text[];
  v_group record;
  v_members text[];
  v_counters jsonb := '{}'::jsonb;
  m record;
  v_no integer;
begin
  select * into st from public.division_stages where id = p_stage_id;
  if st.stage_no <> 1 or st.stage_type <> 'pool_play' then
    return;
  end if;
  if exists (select 1 from public.matches x where x.division_stage_id = st.id and x.status <> 'void') then
    return;
  end if;
  select * into d from public.draws x where x.division_stage_id = st.id and x.status = 'active';
  if not found then
    return;
  end if;
  select array_agg(v order by ord) into v_order from jsonb_array_elements_text(d.result -> 'order') with ordinality as t(v, ord);
  for v_group in select distinct a.group_label from core.pool_assign(st.id, v_order, st.config) a order by 1 loop
    select array_agg(a.entry_id order by a.pos) into v_members
    from core.pool_assign(st.id, v_order, st.config) a where a.group_label = v_group.group_label;
    for m in select * from core.rr_schedule(v_members) loop
      -- match numbers are unique per round across all brackets
      v_no := coalesce((v_counters ->> m.round_no::text)::integer, 0) + 1;
      v_counters := v_counters || jsonb_build_object(m.round_no::text, v_no);
      insert into public.matches (org_id, division_stage_id, round_no, match_no, group_label, entry_a_id, entry_b_id)
      values (st.org_id, st.id, m.round_no, v_no, v_group.group_label, m.a, m.b);
    end loop;
  end loop;
end $$;
revoke all on function core.build_pool_play(text) from public, anon, authenticated;
grant execute on function core.build_pool_play(text) to service_role;

-- ---------------------------------------------------------------------------
-- knockout builders shared by single elimination and the crossover
-- ---------------------------------------------------------------------------
-- p_pairs: [{"a": entry, "b": entry, "a_label": "A1", "b_label": "D1"}, ...] in bracket order; the count must be a power of two.
create or replace function core.insert_pair_matches(p_stage_id text, p_pairs jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  st public.division_stages;
  v_m integer := jsonb_array_length(p_pairs);
  v_rounds integer := 1;
  v_ids jsonb := '{}'::jsonb;
  r integer;
  k integer;
  c integer;
  v_id text;
  v_feed text;
begin
  select * into st from public.division_stages where id = p_stage_id;
  while (2 ^ (v_rounds - 1))::integer < v_m loop
    v_rounds := v_rounds + 1;
  end loop;
  for r in reverse v_rounds..1 loop
    c := (v_m / (2 ^ (r - 1)))::integer;
    for k in 1..c loop
      v_feed := case when r < v_rounds then v_ids ->> ((r + 1) || '-' || ((k + 1) / 2)) end;
      insert into public.matches (org_id, division_stage_id, round_no, match_no, entry_a_id, entry_b_id, feeds_match_id, slot, meta)
      values (st.org_id, st.id, r, k,
        case when r = 1 then p_pairs -> (k - 1) ->> 'a' end,
        case when r = 1 then p_pairs -> (k - 1) ->> 'b' end,
        v_feed,
        case when r < v_rounds then (case when k % 2 = 1 then 'a' else 'b' end) end,
        case when r = 1 then jsonb_build_object('a_label', p_pairs -> (k - 1) ->> 'a_label', 'b_label', p_pairs -> (k - 1) ->> 'b_label')
             else '{}'::jsonb end)
      returning id into v_id;
      v_ids := v_ids || jsonb_build_object(r || '-' || k, v_id);
    end loop;
  end loop;
end $$;
revoke all on function core.insert_pair_matches(text, jsonb) from public, anon, authenticated;
grant execute on function core.insert_pair_matches(text, jsonb) to service_role;

-- A seeded bracket (seed 1 first) for any number of entries, with byes for the best seeds.
create or replace function core.insert_seeded_matches(p_stage_id text, p_order text[], p_labels text[] default null) returns void
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
    insert into public.matches (org_id, division_stage_id, round_no, match_no, entry_a_id, entry_b_id, feeds_match_id, slot, meta)
    values (st.org_id, st.id, row.round_no, row.match_no,
      case when row.seed_a is null then null else p_order[row.seed_a] end,
      case when row.seed_b is null then null else p_order[row.seed_b] end,
      v_feed, row.slot,
      case when p_labels is null or row.seed_a is null then '{}'::jsonb
           else jsonb_build_object('a_label', p_labels[row.seed_a], 'b_label', case when row.seed_b is null then null else p_labels[row.seed_b] end) end)
    returning id into v_id;
    v_ids := v_ids || jsonb_build_object(row.round_no || '-' || row.match_no, v_id);
  end loop;
end $$;
revoke all on function core.insert_seeded_matches(text, text[], text[]) from public, anon, authenticated;
grant execute on function core.insert_seeded_matches(text, text[], text[]) to service_role;

create or replace function core.build_single_elimination(p_stage_id text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  st public.division_stages;
  d public.draws;
  v_order text[];
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
  perform core.insert_seeded_matches(st.id, v_order);
end $$;

-- ---------------------------------------------------------------------------
-- the crossover knockout, built when the pools are finished
-- ---------------------------------------------------------------------------
create or replace function core.build_crossover(p_pool_stage_id text, p_ko_stage_id text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  pool public.division_stages;
  ko public.division_stages;
  v_n integer;
  v_adv jsonb;
  v_cut_tie boolean;
  v_groups text[];
  v_g integer;
  v_m integer;
  v_finishes integer;
  v_pairs jsonb := '[]'::jsonb;
  i integer;
  f integer;
  gi text;
  gj text;
  v_order text[];
  v_labels text[];
begin
  select * into pool from public.division_stages where id = p_pool_stage_id;
  select * into ko from public.division_stages where id = p_ko_stage_id;
  v_n := coalesce((pool.config ->> 'advance_per_group')::integer, 2);
  -- The advancers of each bracket, best first. A tie across the cut is settled by a reproducible hash and audited.
  select jsonb_agg(jsonb_build_object('group_label', q.group_label, 'finish', q.finish, 'entry_id', q.entry_id,
           'label', q.group_label || q.finish, 'pdiff', q.pdiff) order by q.group_label, q.finish),
         coalesce(bool_or(q.finish = v_n and q.tied_next), false)
    into v_adv, v_cut_tie
  from (
    select s.group_label, s.entry_id, s.points_for - s.points_against as pdiff,
      row_number() over (partition by s.group_label order by s.place, md5(s.entry_id || pool.id)) as finish,
      coalesce(lead(s.place) over (partition by s.group_label order by s.place, md5(s.entry_id || pool.id)) = s.place, false) as tied_next,
      count(*) over (partition by s.group_label) as size
    from core.stage_standings(pool.id) s) q
  where q.finish <= least(v_n, q.size - 1);
  if v_adv is null then
    return;
  end if;
  select array_agg(distinct x.group_label order by x.group_label), count(*), count(distinct x.finish)
    into v_groups, v_m, v_finishes from jsonb_to_recordset(v_adv) as x(group_label text, finish integer);
  v_g := cardinality(v_groups);
  if v_m < 2 then
    return;
  end if;
  if v_g % 2 = 0 and (v_m & (v_m - 1)) = 0 and v_finishes * v_g = v_m then
    -- the club's rule: first with last bracket, the same finish meets the same finish
    for i in 1..(v_g / 2) loop
      gi := v_groups[i];
      gj := v_groups[v_g + 1 - i];
      for f in 1..v_finishes loop
        v_pairs := v_pairs || jsonb_build_object(
          'a', (select x.entry_id from jsonb_to_recordset(v_adv) as x(group_label text, finish integer, entry_id text) where x.group_label = gi and x.finish = f),
          'b', (select x.entry_id from jsonb_to_recordset(v_adv) as x(group_label text, finish integer, entry_id text) where x.group_label = gj and x.finish = f),
          'a_label', gi || f, 'b_label', gj || f);
      end loop;
    end loop;
    perform core.insert_pair_matches(ko.id, v_pairs);
    update public.division_stages set meta = meta || jsonb_build_object('crossover', 'paired_groups_same_rank') where id = ko.id;
  else
    -- another count: a seeded bracket, best finish first, then point difference; byes go to the best seeds
    select array_agg(x.entry_id order by x.finish, x.pdiff desc, md5(x.entry_id || ko.id)),
           array_agg(x.label order by x.finish, x.pdiff desc, md5(x.entry_id || ko.id))
      into v_order, v_labels
    from jsonb_to_recordset(v_adv) as x(entry_id text, finish integer, pdiff integer, label text);
    perform core.insert_seeded_matches(ko.id, v_order, v_labels);
    update public.division_stages set meta = meta || jsonb_build_object('crossover', 'seeded_fallback',
      'reason', 'the number of brackets or advancers does not fit the club crossover rule') where id = ko.id;
  end if;
  perform core.write_audit(ko.org_id, 'stage.crossover', 'public.division_stages', ko.id, null,
    jsonb_build_object('advancers', v_m, 'brackets', v_g, 'tie_settled_by_draw', v_cut_tie));
end $$;
revoke all on function core.build_crossover(text, text) from public, anon, authenticated;
grant execute on function core.build_crossover(text, text) to service_role;

-- When a stage is completed, the next one is built from its results.
create or replace function core.start_next_stage(p_stage_id text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  st public.division_stages;
  nx public.division_stages;
begin
  select * into st from public.division_stages where id = p_stage_id;
  select * into nx from public.division_stages x where x.division_id = st.division_id and x.stage_no = st.stage_no + 1 and x.status = 'pending';
  if not found then
    return;
  end if;
  if st.stage_type = 'pool_play' and nx.stage_type = 'single_elimination' then
    perform core.build_crossover(st.id, nx.id);
    if exists (select 1 from public.matches m where m.division_stage_id = nx.id) then
      update public.division_stages set status = 'drawn' where id = nx.id;
    end if;
  end if;
end $$;
revoke all on function core.start_next_stage(text) from public, anon, authenticated;
grant execute on function core.start_next_stage(text) to service_role;

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
      update public.division_stages set status = 'completed' where id = st.id and status = 'in_progress' returning true into v_done;
      if v_done then
        perform core.start_next_stage(st.id);
      end if;
    end if;
  end if;
  return null;
end $$;

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
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- stage_matches: where each side came from
-- ---------------------------------------------------------------------------
drop function public.stage_matches(text);
drop function core.stage_matches(text);
create or replace function core.stage_matches(p_stage_id text)
returns table (match_id text, round_no integer, match_no integer, group_label text, status text, status_reason text,
  entry_a_id text, a_name text, entry_b_id text, b_name text, winner_entry_id text, games jsonb, scheduled_at timestamptz,
  a_label text, b_label text)
language sql stable security definer set search_path = '' as $$
  select m.id, m.round_no::integer, m.match_no::integer, m.group_label, m.status, m.status_reason,
    m.entry_a_id, core.entry_name(m.entry_a_id), m.entry_b_id, core.entry_name(m.entry_b_id), m.winner_entry_id,
    coalesce((select jsonb_agg(jsonb_build_object('a', g.score_a, 'b', g.score_b) order by g.game_no)
              from public.match_games g where g.match_id = m.id), '[]'::jsonb),
    m.scheduled_at, m.meta ->> 'a_label', m.meta ->> 'b_label'
  from public.matches m
  where m.division_stage_id = p_stage_id and m.status <> 'void'
  order by m.round_no, m.match_no
$$;
revoke all on function core.stage_matches(text) from public, anon, authenticated;
grant execute on function core.stage_matches(text) to authenticated, service_role;

create or replace function public.stage_matches(p_stage_id text)
returns table (match_id text, round_no integer, match_no integer, group_label text, status text, status_reason text,
  entry_a_id text, a_name text, entry_b_id text, b_name text, winner_entry_id text, games jsonb, scheduled_at timestamptz,
  a_label text, b_label text)
language sql stable security invoker set search_path = '' as $$
  select s.* from core.stage_matches(p_stage_id) s
  where exists (select 1 from public.division_stages ds join public.divisions d on d.id = ds.division_id
                where ds.id = p_stage_id and d.status in ('drawn', 'in_progress', 'finalized')
                  and exists (select 1 from public.events e where e.id = d.event_id))
$$;
revoke all on function public.stage_matches(text) from public, anon, authenticated;
grant execute on function public.stage_matches(text) to authenticated, service_role;
