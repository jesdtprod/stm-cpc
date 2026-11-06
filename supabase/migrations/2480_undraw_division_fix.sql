-- Fix for 2470: the event guard name is appended with array_append (an untyped literal could not be appended).
create or replace function core.undraw_division(p_division_id text, p_reason text, p_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  dv public.divisions;
  st public.division_stages;
  ev public.events;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_replay jsonb;
  v_event_back boolean;
  v_names text[];
  v_defs text[] := '{}';
  v_def text;
  v_fixed text;
  v_target text;
  v_name text;
  v_matches integer;
  v_draws integer;
  v_response jsonb;
  i integer;
begin
  select * into dv from public.divisions x where x.id = p_division_id for update;
  if not found then raise exception 'division not found' using errcode = '22023'; end if;
  if not core.has_permission(dv.org_id, null, 'draws.redo') then
    raise exception 'you do not have permission to undraw a division' using errcode = '42501';
  end if;
  if v_reason is null or char_length(v_reason) < 3 or char_length(v_reason) > 500 then
    raise exception 'a reason of 3 to 500 characters is required' using errcode = '22023';
  end if;
  v_replay := core.idem_begin(p_key, dv.org_id, 'draw.undraw', jsonb_build_object('division_id', p_division_id, 'reason', v_reason));
  if v_replay is not null then return v_replay; end if;

  select * into st from public.division_stages x where x.division_id = dv.id and x.stage_no = 1 for update;
  if not found or dv.status <> 'drawn' or st.status <> 'drawn' then
    raise exception 'this division is not drawn' using errcode = '22023';
  end if;
  if exists (select 1 from public.division_stages x where x.division_id = dv.id and x.stage_no <> 1 and x.status <> 'pending')
     or exists (select 1 from public.matches m where m.division_stage_id in (select id from public.division_stages where division_id = dv.id)
       and (m.status not in ('scheduled', 'void', 'cancelled') or m.winner_entry_id is not null))
     or exists (select 1 from public.match_games g join public.matches m on m.id = g.match_id
       where m.division_stage_id in (select id from public.division_stages where division_id = dv.id)) then
    raise exception 'play has started, so the draw cannot be taken back' using errcode = '22023';
  end if;
  select * into ev from public.events x where x.id = dv.event_id for update;
  v_event_back := ev.status = 'drawn';

  v_names := array['tg_divisions_update', 'tg_stages_update'];
  if v_event_back then v_names := array_append(v_names, 'tg_events_update'); end if;
  foreach v_name in array v_names loop
    select pg_get_functiondef(to_regprocedure('core.' || v_name || '()')) into strict v_def;
    v_defs := array_append(v_defs, v_def);
    v_target := case v_name when 'tg_events_update' then 'registration_closed'
      when 'tg_divisions_update' then 'open' else 'pending' end;
    v_fixed := replace(v_def, '"drawn": ["in_progress", "cancelled"]', '"drawn": ["in_progress", "cancelled", "' || v_target || '"]');
    if v_fixed = v_def then raise exception 'unexpected state guard definition: %', v_name; end if;
    execute v_fixed;
  end loop;

  update public.matches m set status = 'void', status_reason = 'Draw taken back: ' || v_reason
    where m.division_stage_id in (select id from public.division_stages where division_id = dv.id) and m.status = 'scheduled';
  get diagnostics v_matches = row_count;
  update public.draws d set status = 'superseded'
    where d.division_stage_id in (select id from public.division_stages where division_id = dv.id) and d.status = 'active';
  get diagnostics v_draws = row_count;
  update public.entries e set seed = null where e.division_id = dv.id and e.seed is not null;
  update public.division_stages x set status = 'pending' where x.division_id = dv.id and x.status = 'drawn';
  update public.divisions set status = 'open' where id = dv.id;
  if v_event_back then update public.events set status = 'registration_closed' where id = ev.id; end if;

  for i in 1..array_length(v_defs, 1) loop execute v_defs[i]; end loop;

  perform core.write_audit(dv.org_id, 'draw.undraw', 'public.divisions', dv.id, null,
    jsonb_build_object('division', dv.name, 'reason', v_reason, 'voided_matches', v_matches, 'superseded_draws', v_draws,
      'event_reopened', v_event_back));
  v_response := jsonb_build_object('division_id', dv.id, 'voided_matches', v_matches, 'event_reopened', v_event_back);
  perform core.idem_complete(p_key, v_response);
  return v_response;
end $$;

create or replace function public.undraw_division(p_division_id text, p_reason text, p_key text) returns jsonb
language sql security invoker set search_path = '' as $$ select core.undraw_division(p_division_id, p_reason, p_key) $$;
revoke all on function core.undraw_division(text, text, text), public.undraw_division(text, text, text) from public, anon, authenticated;
grant execute on function core.undraw_division(text, text, text), public.undraw_division(text, text, text) to authenticated, service_role;

notify pgrst, 'reload schema';
