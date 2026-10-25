-- 1460_round_robin (PLAN 7.3): the round robin stage.
--   * rr_schedule: every pair meets exactly once, by the circle method. Entries are numbered by draw position; with an odd
--     number one entry rests each round (a bye, no match is made). n entries give n(n-1)/2 matches over n-1 rounds (n rounds
--     when n is odd).
--   * build_stage_matches (the hook from 1430) now creates a round robin stage's matches from the active draw, once. A redo
--     voids the unplayed matches and builds them again from the new draw.
--   * Progress: the first match to start moves the stage, division and event to "in progress"; when every match of a stage
--     is finished the stage is "completed". (A correction voids a match and replaces it, so voiding never completes a stage.)
--   * stage_matches: the matches of a stage with the names of the entries and the games, for the bracket pages.

create or replace function core.rr_schedule(p_order text[])
returns table (round_no integer, match_no integer, a text, b text)
language plpgsql immutable set search_path = '' as $$
declare
  v text[] := p_order;
  n integer;
  r integer;
  i integer;
  m integer;
  x text;
  y text;
  last_el text;
begin
  if cardinality(v) < 2 then
    return;
  end if;
  if cardinality(v) % 2 = 1 then
    v := array_append(v, null);
  end if;
  n := cardinality(v);
  for r in 1..(n - 1) loop
    m := 0;
    for i in 0..(n / 2 - 1) loop
      x := v[1 + i];
      y := v[n - i];
      if x is not null and y is not null then
        m := m + 1;
        round_no := r;
        match_no := m;
        a := x;
        b := y;
        return next;
      end if;
    end loop;
    -- rotate everything except the first element one place
    last_el := v[n];
    v := array_cat(array_append(v[1:1], last_el), v[2:n - 1]);
  end loop;
end $$;
revoke all on function core.rr_schedule(text[]) from public, anon, authenticated;
grant execute on function core.rr_schedule(text[]) to service_role;

create or replace function core.build_round_robin(p_stage_id text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  st public.division_stages;
  d public.draws;
  v_order text[];
begin
  select * into st from public.division_stages where id = p_stage_id;
  if st.stage_no <> 1 or st.stage_type <> 'round_robin' then
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
  insert into public.matches (org_id, division_stage_id, round_no, match_no, entry_a_id, entry_b_id)
  select st.org_id, st.id, s.round_no, s.match_no, s.a, s.b from core.rr_schedule(v_order) s;
end $$;
revoke all on function core.build_round_robin(text) from public, anon, authenticated;
grant execute on function core.build_round_robin(text) to service_role;

-- The one hook the draw calls: each stage type adds its generator here.
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
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- progress
-- ---------------------------------------------------------------------------
create or replace function core.tg_match_progress() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  st public.division_stages;
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
      update public.division_stages set status = 'completed' where id = st.id and status = 'in_progress';
    end if;
  end if;
  return null;
end $$;
revoke all on function core.tg_match_progress() from public, anon, authenticated;
create trigger z_matches_progress after update of status on public.matches
  for each row execute function core.tg_match_progress();

-- ---------------------------------------------------------------------------
-- matches with names, for the bracket pages
-- ---------------------------------------------------------------------------
create or replace function core.entry_name(p_entry_id text) returns text
language sql stable security definer set search_path = '' as $$
  select string_agg(pe.display_name, ' & ' order by pe.display_name)
  from public.entry_members em join public.members mb on mb.id = em.member_id join public.persons pe on pe.id = mb.person_id
  where em.entry_id = p_entry_id
$$;
revoke all on function core.entry_name(text) from public, anon, authenticated;
grant execute on function core.entry_name(text) to service_role;

create or replace function core.stage_matches(p_stage_id text)
returns table (match_id text, round_no integer, match_no integer, group_label text, status text, status_reason text,
  entry_a_id text, a_name text, entry_b_id text, b_name text, winner_entry_id text, games jsonb, scheduled_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select m.id, m.round_no::integer, m.match_no::integer, m.group_label, m.status, m.status_reason,
    m.entry_a_id, core.entry_name(m.entry_a_id), m.entry_b_id, core.entry_name(m.entry_b_id), m.winner_entry_id,
    coalesce((select jsonb_agg(jsonb_build_object('a', g.score_a, 'b', g.score_b) order by g.game_no)
              from public.match_games g where g.match_id = m.id), '[]'::jsonb),
    m.scheduled_at
  from public.matches m
  where m.division_stage_id = p_stage_id and m.status <> 'void'
  order by m.round_no, m.match_no
$$;
revoke all on function core.stage_matches(text) from public, anon, authenticated;
grant execute on function core.stage_matches(text) to authenticated, service_role;

create or replace function public.stage_matches(p_stage_id text)
returns table (match_id text, round_no integer, match_no integer, group_label text, status text, status_reason text,
  entry_a_id text, a_name text, entry_b_id text, b_name text, winner_entry_id text, games jsonb, scheduled_at timestamptz)
language sql stable security invoker set search_path = '' as $$
  select s.* from core.stage_matches(p_stage_id) s
  where exists (select 1 from public.division_stages ds join public.divisions d on d.id = ds.division_id
                where ds.id = p_stage_id and d.status in ('drawn', 'in_progress', 'finalized')
                  and exists (select 1 from public.events e where e.id = d.event_id))
$$;
revoke all on function public.stage_matches(text) from public, anon, authenticated;
grant execute on function public.stage_matches(text) to authenticated, service_role;
