-- Score entry requires completed games under the saved per-round scoring rule.
-- Preserve permissions, locking, retries, audit events and finalization behavior.
create or replace function core.enter_score(p_match_id text, p_games jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  m public.matches;
  st public.division_stages;
  v_me public.members;
  v_gtw integer;
  v_rule jsonb;
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
  v_rule := core.match_scoring_rule(m.id);
  v_gtw := (v_rule ->> 'games_to_win')::integer;
  if jsonb_typeof(p_games) is distinct from 'array' then
    raise exception 'send the games as a list' using errcode = '22023';
  end if;
  v_n := jsonb_array_length(p_games);
  if v_n = 0 then
    raise exception 'Enter at least one completed game.' using errcode = '22023';
  end if;
  if v_n > 2 * v_gtw - 1 then
    raise exception 'this match is the best of % games', 2 * v_gtw - 1 using errcode = '22023';
  end if;
  for v_i in 1..v_n loop
    if jsonb_typeof(p_games -> (v_i - 1) -> 'a') is distinct from 'number'
      or jsonb_typeof(p_games -> (v_i - 1) -> 'b') is distinct from 'number' then
      raise exception 'Game %: enter whole-number scores from 0 to 99.', v_i using errcode = '22023';
    end if;
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
    if not core.game_ok(v_rule, v_a, v_b) then
      raise exception 'Game %: enter a completed score. Play to %, win by % (unless the configured point cap is reached).',
        v_i, v_rule ->> 'points_per_game', v_rule ->> 'win_by' using errcode = '22023';
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
revoke all on function core.enter_score(text,jsonb) from public,anon;
grant execute on function core.enter_score(text,jsonb) to authenticated,service_role;
notify pgrst, 'reload schema';
