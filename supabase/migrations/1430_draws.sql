-- 1430_draws (PLAN 7.2): the server-side random draw (FEATURES 9.5).
--   * draw_order(seed, entry ids): the order is fixed by the seed and the entry IDs alone (entries sorted by a keyed hash,
--     HMAC-SHA256 of the entry ID under the seed), so the same seed always reproduces the same draw.
--   * run_draw (draws.run): the server makes a random 256-bit seed, stores it with the entrant list and the order, numbers
--     the entries by draw position (entries.seed) and moves the stage, division and (when all divisions are drawn) event to
--     "drawn". Running it again returns the existing draw. The browser cannot pick, rerun or reorder.
--   * redo_draw (draws.redo): a reason is required. The old draw is kept as superseded, the new one points back at it,
--     scheduled matches are voided for the generators to rebuild, and the action is audited and idempotent by key.
--     A stage with a match already started cannot be redrawn.
--   * verify_draw: recomputes a draw from its stored seed and entrants and says whether it matches the stored order.
--   Only stage 1 is drawn from the entries; later stages are filled from the results of the stage before (7.3 to 7.5).
--   build_stage_matches is the hook the bracket generators of 7.3 to 7.5 replace; for now it creates nothing.

create or replace function core.draw_order(p_seed text, p_ids text[]) returns text[]
language sql immutable set search_path = '' as $$
  select coalesce(array_agg(i order by encode(extensions.hmac(convert_to(i, 'utf8'), decode(p_seed, 'hex'), 'sha256'), 'hex'), i), '{}')
  from unnest(p_ids) i
$$;
revoke all on function core.draw_order(text, text[]) from public, anon, authenticated;
grant execute on function core.draw_order(text, text[]) to service_role;

create or replace function core.build_stage_matches(p_stage_id text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  return;
end $$;
revoke all on function core.build_stage_matches(text) from public, anon, authenticated;
grant execute on function core.build_stage_matches(text) to service_role;

-- The entrants of a division's draw: active entries, in a fixed order.
create or replace function core.draw_entrants(p_division_id text) returns text[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(e.id order by e.id), '{}') from public.entries e where e.division_id = p_division_id and e.status = 'active'
$$;
revoke all on function core.draw_entrants(text) from public, anon, authenticated;
grant execute on function core.draw_entrants(text) to service_role;

create or replace function core.draw_snapshot(p_ids text[]) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('entry_id', i,
    'member_ids', (select coalesce(jsonb_agg(em.member_id order by em.member_id), '[]'::jsonb) from public.entry_members em where em.entry_id = i))
    order by i), '[]'::jsonb)
  from unnest(p_ids) i
$$;
revoke all on function core.draw_snapshot(text[]) from public, anon, authenticated;
grant execute on function core.draw_snapshot(text[]) to service_role;

-- Numbers the entries 1..n in draw order (seeds are cleared first because live seeds are unique per division).
create or replace function core.apply_draw_seeds(p_division_id text, p_order text[]) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.entries set seed = null where division_id = p_division_id and status = 'active' and seed is not null;
  update public.entries e set seed = o.pos
  from unnest(p_order) with ordinality as o(id, pos)
  where e.id = o.id and e.division_id = p_division_id;
end $$;
revoke all on function core.apply_draw_seeds(text, text[]) from public, anon, authenticated;
grant execute on function core.apply_draw_seeds(text, text[]) to service_role;

create or replace function core.run_draw(p_stage_id text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  st public.division_stages;
  dv public.divisions;
  ev public.events;
  d public.draws;
  v_ids text[];
  v_seed text;
  v_order text[];
  v_waiting integer;
begin
  select * into st from public.division_stages x where x.id = p_stage_id for update;
  if not found then
    raise exception 'stage not found' using errcode = '22023';
  end if;
  if not core.has_permission(st.org_id, null, 'draws.run') then
    raise exception 'you do not have permission to run a draw' using errcode = '42501';
  end if;
  select * into d from public.draws x where x.division_stage_id = st.id and x.status = 'active';
  if found then
    return jsonb_build_object('draw_id', d.id, 'order', d.result -> 'order', 'replayed', true);
  end if;
  if st.stage_no <> 1 then
    raise exception 'only the first stage is drawn from the entries; later stages are filled from the results' using errcode = '22023';
  end if;
  select * into dv from public.divisions where id = st.division_id for update;
  select * into ev from public.events where id = dv.event_id for update;
  if ev.status <> 'registration_closed' then
    raise exception 'close registration before the draw' using errcode = '22023';
  end if;
  if dv.status <> 'open' then
    raise exception 'this division cannot be drawn (it is %)', dv.status using errcode = '22023';
  end if;
  select count(*)::integer into v_waiting from public.registrations r where r.division_id = dv.id and r.status = 'requested';
  if v_waiting > 0 then
    raise exception '% registration(s) are still waiting for approval; approve or reject them first', v_waiting using errcode = '22023';
  end if;
  v_ids := core.draw_entrants(dv.id);
  if cardinality(v_ids) < 2 then
    raise exception 'a draw needs at least 2 entries (this division has %)', cardinality(v_ids) using errcode = '22023';
  end if;
  v_seed := encode(extensions.gen_random_bytes(32), 'hex');
  v_order := core.draw_order(v_seed, v_ids);
  insert into public.draws (org_id, division_stage_id, seed, entrant_snapshot, result)
  values (st.org_id, st.id, v_seed, core.draw_snapshot(v_ids),
    jsonb_build_object('method', 'hmac_sha256', 'order', to_jsonb(v_order)))
  returning * into d;
  perform core.apply_draw_seeds(dv.id, v_order);
  update public.division_stages set status = 'drawn' where id = st.id;
  update public.divisions set status = 'drawn' where id = dv.id;
  if not exists (select 1 from public.divisions x where x.event_id = ev.id and x.status = 'open') then
    update public.events set status = 'drawn' where id = ev.id and status = 'registration_closed';
  end if;
  perform core.build_stage_matches(st.id);
  perform core.write_audit(st.org_id, 'draw.run', 'public.draws', d.id, null,
    jsonb_build_object('division', dv.name, 'entries', cardinality(v_ids)));
  return jsonb_build_object('draw_id', d.id, 'order', to_jsonb(v_order));
end $$;

create or replace function core.redo_draw(p_stage_id text, p_reason text, p_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  st public.division_stages;
  dv public.divisions;
  old public.draws;
  d public.draws;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_replay jsonb;
  v_ids text[];
  v_seed text;
  v_order text[];
  v_response jsonb;
begin
  select * into st from public.division_stages x where x.id = p_stage_id for update;
  if not found then
    raise exception 'stage not found' using errcode = '22023';
  end if;
  if not core.has_permission(st.org_id, null, 'draws.redo') then
    raise exception 'you do not have permission to redo a draw' using errcode = '42501';
  end if;
  if v_reason is null or char_length(v_reason) < 3 or char_length(v_reason) > 500 then
    raise exception 'a reason of 3 to 500 characters is required' using errcode = '22023';
  end if;
  v_replay := core.idem_begin(p_key, st.org_id, 'draw.redo', jsonb_build_object('stage_id', p_stage_id, 'reason', v_reason));
  if v_replay is not null then
    return v_replay;
  end if;
  select * into old from public.draws x where x.division_stage_id = st.id and x.status = 'active';
  if not found then
    raise exception 'this stage has not been drawn yet' using errcode = '22023';
  end if;
  if st.status <> 'drawn' then
    raise exception 'the stage is already under way and cannot be redrawn' using errcode = '22023';
  end if;
  if exists (select 1 from public.matches m where m.division_stage_id = st.id and m.status not in ('scheduled', 'void', 'cancelled')) then
    raise exception 'a match has already started; the draw cannot be redone' using errcode = '22023';
  end if;
  select * into dv from public.divisions where id = st.division_id for update;

  update public.matches set status = 'void', status_reason = 'Draw redone' where division_stage_id = st.id and status = 'scheduled';
  update public.draws set status = 'superseded' where id = old.id;
  v_ids := core.draw_entrants(dv.id);
  v_seed := encode(extensions.gen_random_bytes(32), 'hex');
  v_order := core.draw_order(v_seed, v_ids);
  insert into public.draws (org_id, division_stage_id, seed, entrant_snapshot, result, replaces_draw_id, redo_reason)
  values (st.org_id, st.id, v_seed, core.draw_snapshot(v_ids),
    jsonb_build_object('method', 'hmac_sha256', 'order', to_jsonb(v_order)), old.id, v_reason)
  returning * into d;
  perform core.apply_draw_seeds(dv.id, v_order);
  perform core.build_stage_matches(st.id);
  perform core.write_audit(st.org_id, 'draw.redo', 'public.draws', d.id,
    jsonb_build_object('draw_id', old.id), jsonb_build_object('draw_id', d.id, 'reason', v_reason, 'division', dv.name));
  v_response := jsonb_build_object('draw_id', d.id, 'replaces', old.id, 'order', to_jsonb(v_order));
  perform core.idem_complete(p_key, v_response);
  return v_response;
end $$;

create or replace function core.verify_draw(p_draw_id text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  d public.draws;
  v_ids text[];
  v_again text[];
begin
  select * into d from public.draws x where x.id = p_draw_id;
  if not found then
    raise exception 'draw not found' using errcode = '22023';
  end if;
  if not (core.has_permission(d.org_id, null, 'draws.run') or core.has_permission(d.org_id, null, 'events.manage')) then
    raise exception 'you do not have permission to verify a draw' using errcode = '42501';
  end if;
  select array_agg(e ->> 'entry_id' order by e ->> 'entry_id') into v_ids from jsonb_array_elements(d.entrant_snapshot) e;
  v_again := core.draw_order(d.seed, coalesce(v_ids, '{}'));
  return jsonb_build_object('draw_id', d.id, 'matches', to_jsonb(v_again) = (d.result -> 'order'));
end $$;

-- ---- public wrappers
create or replace function public.run_draw(p_stage_id text) returns jsonb
language sql security invoker set search_path = '' as $$ select core.run_draw(p_stage_id) $$;
create or replace function public.redo_draw(p_stage_id text, p_reason text, p_key text) returns jsonb
language sql security invoker set search_path = '' as $$ select core.redo_draw(p_stage_id, p_reason, p_key) $$;
create or replace function public.verify_draw(p_draw_id text) returns jsonb
language sql stable security invoker set search_path = '' as $$ select core.verify_draw(p_draw_id) $$;

revoke all on function core.run_draw(text), core.redo_draw(text, text, text), core.verify_draw(text),
  public.run_draw(text), public.redo_draw(text, text, text), public.verify_draw(text) from public, anon, authenticated;
grant execute on function core.run_draw(text), core.redo_draw(text, text, text), core.verify_draw(text),
  public.run_draw(text), public.redo_draw(text, text, text), public.verify_draw(text) to authenticated, service_role;
