-- Split single elimination stages drawn before 2530 have Round 1 only: their H and L brackets would be built when every Round 1
-- match is final. Build the empty brackets for the ones still in play and place the results already recorded, so that they
-- behave like a stage drawn today.

create or replace function core.build_split_skeleton(p_stage_id text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  st public.division_stages;
  d public.draws;
  v_order text[];
  v_card integer;
  v_nh integer;
  v_nl integer;
  v_seeds integer[];
  v_h text[];
  v_hl text[];
  v_l text[];
  v_ll text[];
  k integer;
begin
  select * into st from public.division_stages where id = p_stage_id;
  if st.stage_type <> 'split_single_elimination' then
    return;
  end if;
  if exists (select 1 from public.matches m where m.division_stage_id = st.id and m.group_label in ('H', 'L') and m.status <> 'void') then
    return;
  end if;
  select * into d from public.draws x where x.division_stage_id = st.id and x.status = 'active';
  if not found then
    return;
  end if;
  select array_agg(v order by ord) into v_order from jsonb_array_elements_text(d.result -> 'order') with ordinality as t(v, ord);
  v_card := cardinality(v_order);
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
        v_h[v_seeds[k]] := v_order[v_card];
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
revoke all on function core.build_split_skeleton(text) from public, anon, authenticated;
grant execute on function core.build_split_skeleton(text) to service_role;

do $$
declare
  s record;
  m record;
begin
  for s in
    select st.id from public.division_stages st
    where st.stage_type = 'split_single_elimination' and st.status in ('drawn', 'in_progress')
      and exists (select 1 from public.matches x where x.division_stage_id = st.id and x.group_label is null and x.status <> 'void')
      and not exists (select 1 from public.matches x where x.division_stage_id = st.id and x.group_label in ('H', 'L') and x.status <> 'void')
  loop
    perform core.build_split_skeleton(s.id);
    for m in
      select x.id, x.winner_entry_id from public.matches x
      where x.division_stage_id = s.id and x.group_label is null and x.round_no = 1
        and x.status in ('completed', 'forfeited') and x.winner_entry_id is not null
    loop
      perform core.advance_winner(m.id, m.winner_entry_id);
    end loop;
  end loop;
end $$;

notify pgrst, 'reload schema';
