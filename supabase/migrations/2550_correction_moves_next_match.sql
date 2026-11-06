-- Correcting a result can change the winner. The next match (for a split stage: the H and L bracket matches) used to refuse
-- ("the next match already has a different opponent; void it first"). Now the new winner (and, in a split stage, the new loser)
-- simply takes the old one's place, as long as that next match has not started. If it has started or finished, the message says
-- to correct that match first.

create or replace function core.tg_matches_update() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  st public.division_stages;
begin
  if (old.division_stage_id, old.round_no, old.match_no, old.group_label, old.feeds_match_id, old.slot)
     is distinct from
     (new.division_stage_id, new.round_no, new.match_no, new.group_label, new.feeds_match_id, new.slot) then
    raise exception 'a match''s stage, position and feed cannot change' using errcode = '42501';
  end if;
  -- An opponent can be filled in once a feeder match finishes; a known opponent changes only when a correction moves the
  -- feeder's result (core.set_match_slot) and the match has not started.
  if ((old.entry_a_id is not null and new.entry_a_id is distinct from old.entry_a_id)
      or (old.entry_b_id is not null and new.entry_b_id is distinct from old.entry_b_id))
     and not (coalesce(current_setting('core.opponent_swap', true), 'off') = 'on' and old.status = 'scheduled') then
    raise exception 'a match''s opponents cannot change once set; void the match instead' using errcode = '42501';
  end if;
  if old.winner_entry_id is not null and new.winner_entry_id is distinct from old.winner_entry_id then
    raise exception 'a recorded winner cannot change; void the match instead' using errcode = '42501';
  end if;
  if new.winner_entry_id is not null and new.status not in ('completed', 'forfeited', 'void') then
    raise exception 'a winner is recorded only when the match is completed or forfeited' using errcode = '22023';
  end if;
  if (new.entry_a_id is distinct from old.entry_a_id or new.entry_b_id is distinct from old.entry_b_id) then
    select * into st from public.division_stages where id = new.division_stage_id;
    if exists (
      select 1 from (values (new.entry_a_id), (new.entry_b_id)) v(eid)
      where v.eid is not null and not exists (
        select 1 from public.entries en where en.id = v.eid and en.division_id = st.division_id and en.status = 'active')
    ) then
      raise exception 'a match entry must be an active entry of the same division' using errcode = '22023';
    end if;
  end if;
  perform core.check_transition('match', old.status, new.status, '{
    "scheduled": ["in_progress", "forfeited", "cancelled", "void"],
    "in_progress": ["completed", "forfeited", "void"],
    "completed": ["void"],
    "forfeited": ["void"]
  }'::jsonb);
  return new;
end $$;
revoke all on function core.tg_matches_update() from public, anon, authenticated;

-- Puts an entry in one side of a match: an empty side is filled; a side holding another entry is replaced while the match has
-- not started.
create or replace function core.set_match_slot(p_match_id text, p_slot text, p_entry text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  f public.matches;
  v_current text;
begin
  select * into f from public.matches where id = p_match_id;
  v_current := case when p_slot = 'a' then f.entry_a_id else f.entry_b_id end;
  if v_current is not distinct from p_entry then
    return;
  end if;
  if v_current is not null and (f.status <> 'scheduled' or exists (select 1 from public.match_games g where g.match_id = f.id)) then
    raise exception 'the next match has already started; correct that match first, then this one' using errcode = '22023';
  end if;
  perform set_config('core.opponent_swap', 'on', true);
  if p_slot = 'a' then
    update public.matches set entry_a_id = p_entry where id = f.id;
  else
    update public.matches set entry_b_id = p_entry where id = f.id;
  end if;
  perform set_config('core.opponent_swap', 'off', true);
end $$;
revoke all on function core.set_match_slot(text, text, text) from public, anon, authenticated;
grant execute on function core.set_match_slot(text, text, text) to service_role;

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
  perform core.set_match_slot(f.id, v_slot, p_entry);
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
  perform core.set_match_slot(f.id, m.slot, p_winner);
end $$;
revoke all on function core.advance_winner(text, text) from public, anon, authenticated;
grant execute on function core.advance_winner(text, text) to service_role;

notify pgrst, 'reload schema';
