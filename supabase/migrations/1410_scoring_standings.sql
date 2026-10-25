-- 1410_scoring_standings (PLAN 7.1): score entry, one final result per match, corrections, and standings with tiebreaks.
--   * game_ok: is a game score a finished game under a scoring rule (points per game, win by, point cap)?
--   * enter_score (scores.enter, or the match's own referee): records the games of a live match; nothing is final yet.
--   * finalize_match (scores.finalize): checks every game against the stage's scoring rule, decides the winner, moves
--     the match to completed once, and puts the winner into the next match. Finalizing again returns the same result.
--   * forfeit_match (scores.finalize): the other side wins with the rule's forfeit score in every game needed.
--   * correct_match (scores.correct): voids the finished match and records its replacement at the same position, with a
--     reversing score event; refused when it would change a winner who has already been placed in the next match.
--   * stage_standings: wins, game and point totals, then the stage's tiebreak order (head-to-head among the tied only,
--     game difference, point difference, points scored, coin toss). Ties that no rule splits share a place.
--   Standings and results are computed here on the server; the browser only reads them.

create or replace function core.game_ok(p_rule jsonb, p_a integer, p_b integer) returns boolean
language plpgsql immutable set search_path = '' as $$
declare
  w integer := greatest(p_a, p_b);
  l integer := least(p_a, p_b);
  pts integer := (p_rule ->> 'points_per_game')::integer;
  wb integer := (p_rule ->> 'win_by')::integer;
  cap integer := nullif(p_rule ->> 'point_cap', '')::integer;
begin
  if w < pts then return false; end if;
  if cap is not null and w > cap then return false; end if;
  if cap is not null and w = cap then return w - l >= 1; end if;
  if w = pts then return w - l >= wb; end if;
  return w - l = wb;
end $$;
revoke all on function core.game_ok(jsonb, integer, integer) from public, anon, authenticated;
grant execute on function core.game_ok(jsonb, integer, integer) to service_role;

-- The live (not voided) match at the position of the given match; a correction replaces a match, never moves it.
create or replace function core.live_match_of(p_match_id text) returns public.matches
language sql stable security definer set search_path = '' as $$
  select m2.* from public.matches m
  join public.matches m2 on m2.division_stage_id = m.division_stage_id and m2.round_no = m.round_no and m2.match_no = m.match_no
    and m2.status <> 'void'
  where m.id = p_match_id
$$;
revoke all on function core.live_match_of(text) from public, anon, authenticated;
grant execute on function core.live_match_of(text) to service_role;

-- ---------------------------------------------------------------------------
-- recording games
-- ---------------------------------------------------------------------------
create or replace function core.enter_score(p_match_id text, p_games jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  m public.matches;
  st public.division_stages;
  v_me public.members;
  v_gtw integer;
  v_n integer;
  v_i integer;
  v_a integer;
  v_b integer;
  v_extra integer;
begin
  select * into m from public.matches x where x.id = p_match_id for update;
  if not found then
    raise exception 'match not found' using errcode = '22023';
  end if;
  select * into v_me from public.members mm where mm.profile_id = core.current_profile_id() and mm.deleted_at is null;
  if not (core.has_permission(m.org_id, null, 'scores.enter') or (v_me.id is not null and m.referee_member_id = v_me.id)) then
    raise exception 'you do not have permission to enter scores for this match' using errcode = '42501';
  end if;
  if m.status not in ('scheduled', 'in_progress') then
    raise exception 'a match that is % cannot take scores', m.status using errcode = '22023';
  end if;
  if m.entry_a_id is null or m.entry_b_id is null then
    raise exception 'both opponents must be known before a score is entered' using errcode = '22023';
  end if;
  select * into st from public.division_stages where id = m.division_stage_id;
  v_gtw := (st.scoring_rule_snapshot ->> 'games_to_win')::integer;
  if jsonb_typeof(p_games) <> 'array' then
    raise exception 'send the games as a list' using errcode = '22023';
  end if;
  v_n := jsonb_array_length(p_games);
  if v_n > 2 * v_gtw - 1 then
    raise exception 'this match is the best of % games', 2 * v_gtw - 1 using errcode = '22023';
  end if;
  for v_i in 1..v_n loop
    begin
      v_a := (p_games -> (v_i - 1) ->> 'a')::integer;
      v_b := (p_games -> (v_i - 1) ->> 'b')::integer;
    exception when others then
      raise exception 'game % needs two whole-number scores', v_i using errcode = '22023';
    end;
    if v_a is null or v_b is null or v_a < 0 or v_b < 0 or v_a > 99 or v_b > 99 then
      raise exception 'game % needs two scores from 0 to 99', v_i using errcode = '22023';
    end if;
    if v_a = v_b then
      raise exception 'game % cannot end level', v_i using errcode = '22023';
    end if;
  end loop;
  select count(*)::integer into v_extra from public.match_games g where g.match_id = m.id and g.game_no > v_n;
  if v_extra > 0 then
    raise exception 'a game that was entered cannot be removed; ask an admin to void the match' using errcode = '22023';
  end if;
  if m.status = 'scheduled' then
    update public.matches set status = 'in_progress' where id = m.id;
  end if;
  for v_i in 1..v_n loop
    v_a := (p_games -> (v_i - 1) ->> 'a')::integer;
    v_b := (p_games -> (v_i - 1) ->> 'b')::integer;
    insert into public.match_games (org_id, match_id, game_no, score_a, score_b) values (m.org_id, m.id, v_i, v_a, v_b)
    on conflict (match_id, game_no) do update set score_a = excluded.score_a, score_b = excluded.score_b
    where (public.match_games.score_a, public.match_games.score_b) is distinct from (excluded.score_a, excluded.score_b);
  end loop;
  insert into public.score_events (org_id, match_id, kind, payload) values (m.org_id, m.id, 'entered', jsonb_build_object('games', p_games));
  return jsonb_build_object('match_id', m.id, 'status', 'in_progress', 'games', v_n);
end $$;

-- Decides the match from its games and the stage's scoring rule, completes it and advances the winner.
create or replace function core.apply_final(p_match_id text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  m public.matches;
  st public.division_stages;
  g record;
  v_rule jsonb;
  v_gtw integer;
  v_wa integer := 0;
  v_wb integer := 0;
  v_n integer := 0;
  v_winner text;
  v_games jsonb := '[]'::jsonb;
  f public.matches;
begin
  select * into m from public.matches where id = p_match_id for update;
  if m.entry_a_id is null or m.entry_b_id is null then
    raise exception 'both opponents must be known' using errcode = '22023';
  end if;
  select * into st from public.division_stages where id = m.division_stage_id;
  v_rule := st.scoring_rule_snapshot;
  v_gtw := (v_rule ->> 'games_to_win')::integer;
  for g in select * from public.match_games x where x.match_id = m.id order by x.game_no loop
    v_n := v_n + 1;
    if g.game_no <> v_n then
      raise exception 'the games must be numbered 1, 2, 3 ... without gaps' using errcode = '22023';
    end if;
    if v_wa >= v_gtw or v_wb >= v_gtw then
      raise exception 'the match was already decided before game %', g.game_no using errcode = '22023';
    end if;
    if not core.game_ok(v_rule, g.score_a, g.score_b) then
      raise exception 'game % (% to %) is not a finished game: play to %, win by %', g.game_no, g.score_a, g.score_b,
        v_rule ->> 'points_per_game', (v_rule ->> 'win_by') || case when nullif(v_rule ->> 'point_cap', '') is null then '' else ' (cap ' || (v_rule ->> 'point_cap') || ')' end
        using errcode = '22023';
    end if;
    if g.score_a > g.score_b then v_wa := v_wa + 1; else v_wb := v_wb + 1; end if;
    v_games := v_games || jsonb_build_object('a', g.score_a, 'b', g.score_b);
  end loop;
  if v_wa < v_gtw and v_wb < v_gtw then
    raise exception 'the match is not finished: a side needs % game(s) to win', v_gtw using errcode = '22023';
  end if;
  v_winner := case when v_wa > v_wb then m.entry_a_id else m.entry_b_id end;
  if m.status = 'scheduled' then
    update public.matches set status = 'in_progress' where id = m.id;
  end if;
  update public.matches set status = 'completed', winner_entry_id = v_winner, status_reason = null where id = m.id;
  insert into public.score_events (org_id, match_id, kind, payload)
  values (m.org_id, m.id, 'finalized', jsonb_build_object('games', v_games, 'winner_entry_id', v_winner,
    'games_a', v_wa, 'games_b', v_wb));
  perform core.advance_winner(m.id, v_winner);
  return jsonb_build_object('match_id', m.id, 'status', 'completed', 'winner_entry_id', v_winner, 'games_a', v_wa, 'games_b', v_wb);
end $$;
revoke all on function core.apply_final(text) from public, anon, authenticated;
grant execute on function core.apply_final(text) to service_role;

-- Puts the winner into the next match's open slot. A slot that already holds this entry is fine; another entry is an error.
create or replace function core.advance_winner(p_match_id text, p_winner text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  m public.matches;
  f public.matches;
begin
  select * into m from public.matches where id = p_match_id;
  if m.feeds_match_id is null then
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

create or replace function core.finalize_match(p_match_id text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  m public.matches;
  v_result jsonb;
begin
  select * into m from public.matches x where x.id = p_match_id for update;
  if not found then
    raise exception 'match not found' using errcode = '22023';
  end if;
  if not core.has_permission(m.org_id, null, 'scores.finalize') then
    raise exception 'you do not have permission to finalize scores' using errcode = '42501';
  end if;
  if m.status in ('completed', 'forfeited') then
    return jsonb_build_object('match_id', m.id, 'status', m.status, 'winner_entry_id', m.winner_entry_id, 'unchanged', true);
  end if;
  if m.status not in ('scheduled', 'in_progress') then
    raise exception 'a match that is % cannot be finalized', m.status using errcode = '22023';
  end if;
  v_result := core.apply_final(m.id);
  perform core.write_audit(m.org_id, 'match.finalize', 'public.matches', m.id, null, v_result);
  return v_result;
end $$;

create or replace function core.forfeit_match(p_match_id text, p_forfeiting_entry_id text, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  m public.matches;
  st public.division_stages;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_gtw integer;
  v_fs integer;
  v_winner text;
  v_i integer;
  v_existing integer;
begin
  select * into m from public.matches x where x.id = p_match_id for update;
  if not found then
    raise exception 'match not found' using errcode = '22023';
  end if;
  if not core.has_permission(m.org_id, null, 'scores.finalize') then
    raise exception 'you do not have permission to record a forfeit' using errcode = '42501';
  end if;
  if m.status = 'forfeited' then
    return jsonb_build_object('match_id', m.id, 'status', 'forfeited', 'winner_entry_id', m.winner_entry_id, 'unchanged', true);
  end if;
  if m.status not in ('scheduled', 'in_progress') then
    raise exception 'a match that is % cannot be forfeited', m.status using errcode = '22023';
  end if;
  if m.entry_a_id is null or m.entry_b_id is null then
    raise exception 'both opponents must be known' using errcode = '22023';
  end if;
  if p_forfeiting_entry_id is distinct from m.entry_a_id and p_forfeiting_entry_id is distinct from m.entry_b_id then
    raise exception 'the forfeiting side must be one of the two opponents' using errcode = '22023';
  end if;
  if v_reason is null or char_length(v_reason) < 3 or char_length(v_reason) > 500 then
    raise exception 'a reason of 3 to 500 characters is required' using errcode = '22023';
  end if;
  select * into st from public.division_stages where id = m.division_stage_id;
  v_gtw := (st.scoring_rule_snapshot ->> 'games_to_win')::integer;
  v_fs := (st.scoring_rule_snapshot ->> 'forfeit_score')::integer;
  select count(*)::integer into v_existing from public.match_games g where g.match_id = m.id and g.game_no > v_gtw;
  if v_existing > 0 then
    raise exception 'too many games were already entered; void the match instead' using errcode = '22023';
  end if;
  v_winner := case when p_forfeiting_entry_id = m.entry_a_id then m.entry_b_id else m.entry_a_id end;
  for v_i in 1..v_gtw loop
    insert into public.match_games (org_id, match_id, game_no, score_a, score_b)
    values (m.org_id, m.id, v_i, case when v_winner = m.entry_a_id then v_fs else 0 end, case when v_winner = m.entry_b_id then v_fs else 0 end)
    on conflict (match_id, game_no) do update set score_a = excluded.score_a, score_b = excluded.score_b;
  end loop;
  if m.status = 'scheduled' then
    update public.matches set status = 'in_progress' where id = m.id;
  end if;
  update public.matches set status = 'forfeited', winner_entry_id = v_winner, status_reason = v_reason where id = m.id;
  insert into public.score_events (org_id, match_id, kind, payload)
  values (m.org_id, m.id, 'forfeit', jsonb_build_object('forfeiting_entry_id', p_forfeiting_entry_id, 'reason', v_reason));
  insert into public.score_events (org_id, match_id, kind, payload)
  values (m.org_id, m.id, 'finalized', jsonb_build_object('forfeit', true, 'winner_entry_id', v_winner));
  perform core.advance_winner(m.id, v_winner);
  perform core.write_audit(m.org_id, 'match.forfeit', 'public.matches', m.id, null,
    jsonb_build_object('forfeiting_entry_id', p_forfeiting_entry_id, 'reason', v_reason));
  return jsonb_build_object('match_id', m.id, 'status', 'forfeited', 'winner_entry_id', v_winner);
end $$;

-- Replaces a finished match with a corrected one at the same position.
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
  perform core.write_audit(m.org_id, 'match.correct', 'public.matches', m.id,
    jsonb_build_object('winner_entry_id', m.winner_entry_id), jsonb_build_object('new_match_id', v_new.id, 'reason', v_reason,
      'winner_entry_id', v_result ->> 'winner_entry_id'));
  return v_result || jsonb_build_object('old_match_id', m.id, 'new_match_id', v_new.id);
end $$;

-- ---------------------------------------------------------------------------
-- standings
-- ---------------------------------------------------------------------------
-- One row per entry per finished match (voided matches never count).
create or replace function core.stage_rows(p_stage text, p_group text)
returns table (e text, o text, win boolean, gw integer, gl integer, pf integer, pa integer)
language sql stable security definer set search_path = '' as $$
  with mm as (
    select m.entry_a_id a, m.entry_b_id b, m.winner_entry_id w,
      (select count(*)::integer from public.match_games g where g.match_id = m.id and g.score_a > g.score_b) ga,
      (select count(*)::integer from public.match_games g where g.match_id = m.id and g.score_b > g.score_a) gb,
      (select coalesce(sum(g.score_a), 0)::integer from public.match_games g where g.match_id = m.id) sa,
      (select coalesce(sum(g.score_b), 0)::integer from public.match_games g where g.match_id = m.id) sb
    from public.matches m
    where m.division_stage_id = p_stage and m.status in ('completed', 'forfeited') and m.group_label is not distinct from p_group
  )
  select a, b, w = a, ga, gb, sa, sb from mm
  union all
  select b, a, w = b, gb, ga, sb, sa from mm
$$;
revoke all on function core.stage_rows(text, text) from public, anon, authenticated;
grant execute on function core.stage_rows(text, text) to service_role;

-- Splits the entries into ordered groups of entries that stay tied after every criterion. The next criterion is applied
-- only inside a tied group; head_to_head counts wins in matches among the tied entries only.
create or replace function core.tb_split(p_stage text, p_group text, p_entries text[], p_criteria text[]) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  crit text;
  v_rest text[];
  v_out jsonb := '[]'::jsonb;
  rec record;
begin
  if cardinality(p_entries) <= 1 or cardinality(p_criteria) = 0 then
    return jsonb_build_array(to_jsonb(p_entries));
  end if;
  crit := p_criteria[1];
  v_rest := p_criteria[2:cardinality(p_criteria)];
  if crit = 'coin_toss' then
    return (select coalesce(jsonb_agg(jsonb_build_array(x) order by md5(p_stage || x)), '[]'::jsonb) from unnest(p_entries) x);
  end if;
  for rec in
    select q.val, array_agg(q.e order by q.e) as ents
    from (
      select x as e, coalesce((
        select sum(case crit
            when 'match_wins' then sr.win::integer
            when 'head_to_head' then (sr.win and sr.o = any (p_entries))::integer
            when 'game_diff' then sr.gw - sr.gl
            when 'point_diff' then sr.pf - sr.pa
            when 'points_for' then sr.pf
          end)
        from core.stage_rows(p_stage, p_group) sr where sr.e = x), 0)::bigint as val
      from unnest(p_entries) x
    ) q
    group by q.val order by q.val desc
  loop
    v_out := v_out || core.tb_split(p_stage, p_group, rec.ents, v_rest);
  end loop;
  return v_out;
end $$;
revoke all on function core.tb_split(text, text, text[], text[]) from public, anon, authenticated;
grant execute on function core.tb_split(text, text, text[], text[]) to service_role;

create or replace function core.stage_standings(p_stage_id text)
returns table (group_label text, entry_id text, entry_name text, played integer, wins integer, losses integer,
  games_won integer, games_lost integer, points_for integer, points_against integer, place integer, tied boolean)
language plpgsql stable security definer set search_path = '' as $$
declare
  st public.division_stages;
  v_criteria text[];
  v_order text[];
  v_group text;
  v_entries text[];
  v_split jsonb;
  v_tier jsonb;
  v_pos integer;
begin
  select * into st from public.division_stages where id = p_stage_id;
  if not found then
    return;
  end if;
  -- Wins always come first; the rest follow the stage's own order.
  select coalesce(array_agg(x order by ord), '{}') into v_order
  from jsonb_array_elements_text(coalesce(st.scoring_rule_snapshot -> 'tiebreak_order', '["match_wins","head_to_head","point_diff"]'::jsonb))
    with ordinality as t(x, ord)
  where x <> 'match_wins';
  v_criteria := array['match_wins'] || v_order;

  for v_group in
    select distinct m.group_label from public.matches m
    where m.division_stage_id = p_stage_id and m.status <> 'void' and m.group_label is not null
    union
    select null::text where not exists (
      select 1 from public.matches m where m.division_stage_id = p_stage_id and m.status <> 'void' and m.group_label is not null)
    order by 1
  loop
    select coalesce(array_agg(distinct x), '{}') into v_entries from (
      select m.entry_a_id x from public.matches m
      where m.division_stage_id = p_stage_id and m.status <> 'void' and m.group_label is not distinct from v_group
      union
      select m.entry_b_id from public.matches m
      where m.division_stage_id = p_stage_id and m.status <> 'void' and m.group_label is not distinct from v_group) q
    where x is not null;
    if cardinality(v_entries) = 0 then
      continue;
    end if;
    v_split := core.tb_split(p_stage_id, v_group, v_entries, v_criteria);
    v_pos := 1;
    for v_tier in select * from jsonb_array_elements(v_split) loop
      return query
      select v_group, t.eid,
        (select string_agg(pe.display_name, ' & ' order by pe.display_name) from public.entry_members em
          join public.members mb on mb.id = em.member_id join public.persons pe on pe.id = mb.person_id where em.entry_id = t.eid),
        coalesce(s.played, 0), coalesce(s.wins, 0), coalesce(s.played, 0) - coalesce(s.wins, 0),
        coalesce(s.gw, 0), coalesce(s.gl, 0), coalesce(s.pf, 0), coalesce(s.pa, 0),
        v_pos, jsonb_array_length(v_tier) > 1
      from jsonb_array_elements_text(v_tier) as t(eid)
      left join lateral (
        select count(*)::integer played, sum(sr.win::integer)::integer wins, sum(sr.gw)::integer gw, sum(sr.gl)::integer gl,
          sum(sr.pf)::integer pf, sum(sr.pa)::integer pa
        from core.stage_rows(p_stage_id, v_group) sr where sr.e = t.eid) s on true;
      v_pos := v_pos + jsonb_array_length(v_tier);
    end loop;
  end loop;
end $$;
revoke all on function core.stage_standings(text) from public, anon, authenticated;
grant execute on function core.stage_standings(text) to service_role;

-- ---- public wrappers (security invoker). Standings are readable by whoever can see the stage's event.
create or replace function public.enter_score(p_match_id text, p_games jsonb) returns jsonb
language sql security invoker set search_path = '' as $$ select core.enter_score(p_match_id, p_games) $$;
create or replace function public.finalize_match(p_match_id text) returns jsonb
language sql security invoker set search_path = '' as $$ select core.finalize_match(p_match_id) $$;
create or replace function public.forfeit_match(p_match_id text, p_forfeiting_entry_id text, p_reason text) returns jsonb
language sql security invoker set search_path = '' as $$ select core.forfeit_match(p_match_id, p_forfeiting_entry_id, p_reason) $$;
create or replace function public.correct_match(p_match_id text, p_reason text, p_games jsonb) returns jsonb
language sql security invoker set search_path = '' as $$ select core.correct_match(p_match_id, p_reason, p_games) $$;
create or replace function public.stage_standings(p_stage_id text)
returns table (group_label text, entry_id text, entry_name text, played integer, wins integer, losses integer,
  games_won integer, games_lost integer, points_for integer, points_against integer, place integer, tied boolean)
language sql stable security invoker set search_path = '' as $$
  select s.* from core.stage_standings(p_stage_id) s
  where exists (select 1 from public.division_stages ds where ds.id = p_stage_id)
$$;

revoke all on function
  core.enter_score(text, jsonb), core.finalize_match(text), core.forfeit_match(text, text, text), core.correct_match(text, text, jsonb),
  public.enter_score(text, jsonb), public.finalize_match(text), public.forfeit_match(text, text, text), public.correct_match(text, text, jsonb),
  public.stage_standings(text)
from public, anon, authenticated;
grant execute on function
  core.enter_score(text, jsonb), core.finalize_match(text), core.forfeit_match(text, text, text), core.correct_match(text, text, jsonb),
  core.stage_standings(text),
  public.enter_score(text, jsonb), public.finalize_match(text), public.forfeit_match(text, text, text), public.correct_match(text, text, jsonb),
  public.stage_standings(text)
to authenticated, service_role;
