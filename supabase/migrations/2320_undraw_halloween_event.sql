-- One-time, club-requested undraw of EV-2026-00002 before any play.
-- Preserve registrations, entries, draw snapshots and voided match history.
-- Restore the original state guards inside the same atomic DO statement;
-- no expanded transitions or permissions remain after this correction.
do $$
declare
  ev public.events;
  fn_name text;
  original_defs text[] := '{}';
  original_def text;
  correction_def text;
  target_status text;
  i integer;
  division_count integer;
  match_count integer;
  draw_count integer;
begin
  select e.* into strict ev from public.events e
    join public.orgs o on o.id = e.org_id
    where o.code = 'cpc' and o.deleted_at is null and e.doc_no = 'EV-2026-00002'
    for update of e;
  if exists (select 1 from core.audit_log a where a.record_id = ev.id
      and a.action = 'event.undraw_correction'
      and a.new_values ->> 'migration' = '2320') then
    return;
  end if;
  perform 1 from public.divisions where event_id = ev.id order by id for update;
  perform 1 from public.division_stages s join public.divisions d on d.id = s.division_id
    where d.event_id = ev.id order by s.id for update of s;
  perform 1 from public.draws dr join public.division_stages s on s.id = dr.division_stage_id
    join public.divisions d on d.id = s.division_id
    where d.event_id = ev.id order by dr.id for update of dr;
  perform 1 from public.matches m join public.division_stages s on s.id = m.division_stage_id
    join public.divisions d on d.id = s.division_id
    where d.event_id = ev.id order by m.id for update of m;
  select count(*) into division_count from public.divisions where event_id = ev.id;
  if ev.status <> 'drawn' or division_count <> 2 or exists (
      select 1 from public.divisions where event_id = ev.id and status <> 'drawn') then
    raise exception 'Expected exactly two drawn divisions in the drawn event';
  end if;
  if exists (select 1 from public.division_stages s join public.divisions d on d.id = s.division_id
      where d.event_id = ev.id and (s.status not in ('pending', 'drawn') or (s.stage_no <> 1 and s.status <> 'pending')))
    or exists (select 1 from public.matches m join public.division_stages s on s.id = m.division_stage_id
      join public.divisions d on d.id = s.division_id where d.event_id = ev.id
      and (m.status not in ('scheduled', 'void') or m.winner_entry_id is not null))
    or exists (select 1 from public.match_games g join public.matches m on m.id = g.match_id
      join public.division_stages s on s.id = m.division_stage_id
      join public.divisions d on d.id = s.division_id where d.event_id = ev.id) then
    raise exception 'Cannot undraw: play, scores or a later stage already exists';
  end if;

  -- The state machine has no undraw edge. Permit only the three required
  -- reversals during this transaction, keeping all immutable-field guards.
  foreach fn_name in array array['tg_events_update', 'tg_divisions_update', 'tg_stages_update'] loop
    select pg_get_functiondef(to_regprocedure('core.' || fn_name || '()')) into strict original_def;
    original_defs := array_append(original_defs, original_def);
    target_status := case fn_name when 'tg_events_update' then 'registration_closed'
      when 'tg_divisions_update' then 'open' else 'pending' end;
    correction_def := replace(original_def, '"drawn": ["in_progress", "cancelled"]',
      '"drawn": ["in_progress", "cancelled", "' || target_status || '"]');
    if correction_def = original_def then
      raise exception 'Unexpected state guard definition: %', fn_name;
    end if;
    execute correction_def;
  end loop;

  update public.matches m set status = 'void', status_reason = 'Club-requested undraw before play (2320)'
    from public.division_stages s, public.divisions d
    where m.division_stage_id = s.id and s.division_id = d.id and d.event_id = ev.id and m.status = 'scheduled';
  get diagnostics match_count = row_count;
  update public.draws dr set status = 'superseded'
    from public.division_stages s, public.divisions d
    where dr.division_stage_id = s.id and s.division_id = d.id and d.event_id = ev.id and dr.status = 'active';
  get diagnostics draw_count = row_count;
  update public.entries en set seed = null from public.divisions d
    where en.division_id = d.id and d.event_id = ev.id and en.seed is not null;
  update public.division_stages s set status = 'pending' from public.divisions d
    where s.division_id = d.id and d.event_id = ev.id and s.status = 'drawn';
  update public.divisions set status = 'open' where event_id = ev.id and status = 'drawn';
  update public.events set status = 'registration_closed' where id = ev.id;

  for i in 1..array_length(original_defs, 1) loop
    execute original_defs[i];
  end loop;
  perform core.write_audit(ev.org_id, 'event.undraw_correction', 'public.events', ev.id,
    jsonb_build_object('status', ev.status, 'draws', draw_count, 'scheduled_matches', match_count),
    jsonb_build_object('migration', '2320', 'status', 'registration_closed',
      'divisions', division_count, 'voided_matches', match_count, 'superseded_draws', draw_count,
      'reason', 'Club requested both divisions undrawn before play; registrations and history preserved'));
end $$;
