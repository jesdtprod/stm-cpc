-- PLAN 8.5: Split Single Elimination can score its knockout rounds differently. After Round 1 the winners play the H bracket
-- and the losers the L bracket; each bracket has its own scoring rule for the Quarterfinals, Semifinals and Finals (rounds
-- are counted back from the final). Anything not set uses the division's scoring rule, and Round 1 always does. The rules
-- are copied into the stage when they are set (like the division's own rule), set by event managers, and locked once a
-- bracket match has started.

alter table public.division_stages
  add column round_scoring jsonb not null default '{}'::jsonb
  constraint division_stages_round_scoring_chk check (jsonb_typeof(round_scoring) = 'object');
comment on column public.division_stages.round_scoring is
  'Split single elimination only: {"H": {"quarterfinal": rule, "semifinal": rule, "final": rule}, "L": {...}}; each rule is a snapshot like scoring_rule_snapshot.';

-- The rule that decides a match: the bracket round override if there is one, otherwise the stage rule.
create or replace function core.match_scoring_rule(p_match_id text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  m public.matches; st public.division_stages; v_last integer; v_label text; v_rule jsonb;
begin
  select * into m from public.matches where id = p_match_id;
  select * into st from public.division_stages where id = m.division_stage_id;
  if st.stage_type = 'split_single_elimination' and m.group_label in ('H', 'L') and m.round_no > 1 then
    select max(x.round_no) into v_last from public.matches x where x.division_stage_id = st.id and x.group_label = m.group_label;
    v_label := case v_last - m.round_no when 0 then 'final' when 1 then 'semifinal' when 2 then 'quarterfinal' end;
    v_rule := st.round_scoring -> m.group_label -> v_label;
    if v_rule is not null and jsonb_typeof(v_rule) = 'object' then
      return v_rule;
    end if;
  end if;
  return st.scoring_rule_snapshot;
end $$;
revoke all on function core.match_scoring_rule(text) from public, anon, authenticated;
grant execute on function core.match_scoring_rule(text) to authenticated, service_role;

-- Set the bracket round rules. p_rules: {"H": {"quarterfinal": "<rule id>", ...}, "L": {...}}; an omitted or null round uses
-- the division's rule. The whole setting is replaced each time.
create or replace function core.set_stage_round_scoring(p_stage_id text, p_rules jsonb, p_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  st public.division_stages; g text; r text; v_id text; v_rule public.scoring_rules; v_out jsonb := '{}'::jsonb;
  v_bracket jsonb; replay jsonb; response jsonb;
begin
  select * into st from public.division_stages x where x.id = p_stage_id for update;
  if not found or core.current_profile_id() is null or not core.has_permission(st.org_id, null, 'events.manage') then
    raise exception 'you do not have permission to set the round scoring' using errcode = '42501';
  end if;
  if st.stage_type <> 'split_single_elimination' then
    raise exception 'round scoring applies to Split Single Elimination only' using errcode = '22023';
  end if;
  if p_rules is null or jsonb_typeof(p_rules) <> 'object' then
    raise exception 'send the round rules as an object' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_object_keys(p_rules) k where k not in ('H', 'L')) then
    raise exception 'round rules are set for the H and L brackets only' using errcode = '22023';
  end if;
  if exists (select 1 from public.matches m where m.division_stage_id = st.id and m.group_label in ('H', 'L')
             and m.status not in ('scheduled', 'void')) then
    raise exception 'the bracket rounds have started; the round scoring is locked' using errcode = '22023';
  end if;
  replay := core.idem_begin(p_key, st.org_id, 'stage.round_scoring', jsonb_build_object('stage', st.id, 'rules', p_rules));
  if replay is not null then return replay; end if;
  foreach g in array array['H', 'L'] loop
    v_bracket := '{}'::jsonb;
    if p_rules ? g then
      if jsonb_typeof(p_rules -> g) <> 'object' then
        raise exception 'round rules for the % bracket must be an object', g using errcode = '22023';
      end if;
      if exists (select 1 from jsonb_object_keys(p_rules -> g) k where k not in ('quarterfinal', 'semifinal', 'final')) then
        raise exception 'rounds are quarterfinal, semifinal and final' using errcode = '22023';
      end if;
      foreach r in array array['quarterfinal', 'semifinal', 'final'] loop
        v_id := nullif(p_rules -> g ->> r, '');
        continue when v_id is null;
        select * into v_rule from public.scoring_rules x
        where x.id = v_id and x.org_id = st.org_id and x.deleted_at is null and x.is_active;
        if not found then
          raise exception 'choose an existing scoring rule for the % %', g, r using errcode = '22023';
        end if;
        v_bracket := v_bracket || jsonb_build_object(r, jsonb_build_object('name', v_rule.name, 'games_to_win', v_rule.games_to_win,
          'points_per_game', v_rule.points_per_game, 'win_by', v_rule.win_by, 'point_cap', v_rule.point_cap,
          'forfeit_score', v_rule.forfeit_score, 'tiebreak_order', to_jsonb(v_rule.tiebreak_order)));
      end loop;
    end if;
    if v_bracket <> '{}'::jsonb then v_out := v_out || jsonb_build_object(g, v_bracket); end if;
  end loop;
  update public.division_stages set round_scoring = v_out where id = st.id;
  perform core.write_audit(st.org_id, 'stage.round_scoring', 'public.division_stages', st.id, null, jsonb_build_object('rules', v_out));
  response := jsonb_build_object('ok', true, 'stage_id', st.id, 'round_scoring', v_out);
  perform core.idem_complete(p_key, response);
  return response;
end $$;
create or replace function public.set_stage_round_scoring(p_stage_id text, p_rules jsonb, p_key text)
returns jsonb language sql security invoker set search_path = '' as $$ select core.set_stage_round_scoring(p_stage_id, p_rules, p_key) $$;
revoke all on function core.set_stage_round_scoring(text, jsonb, text), public.set_stage_round_scoring(text, jsonb, text) from public, anon, authenticated;
grant execute on function core.set_stage_round_scoring(text, jsonb, text), public.set_stage_round_scoring(text, jsonb, text) to authenticated, service_role;

-- The scoring functions (1410) now read the rule of the match instead of the stage.
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
  v_gtw := (core.match_scoring_rule(m.id) ->> 'games_to_win')::integer;
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
  v_rule := core.match_scoring_rule(m.id);
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
  v_gtw := (core.match_scoring_rule(m.id) ->> 'games_to_win')::integer;
  v_fs := (core.match_scoring_rule(m.id) ->> 'forfeit_score')::integer;
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

notify pgrst, 'reload schema';
