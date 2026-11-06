-- Requested schedule correction for EV-2026-00002. Preserve draws and match history.
-- Exact old/new dates make retries safe and reject unexpected schedule changes.
do $$
declare ev public.events;
begin
  select e.* into strict ev from public.events e
    join public.orgs o on o.id = e.org_id
    where o.code = 'cpc' and o.deleted_at is null and e.doc_no = 'EV-2026-00002'
    for update of e;
  if ev.starts_on = date '2026-11-06' and ev.ends_on = date '2026-11-07' then
    return;
  end if;
  if ev.starts_on <> date '2026-10-03' or ev.ends_on <> date '2026-10-04' then
    raise exception 'Event schedule differs from the expected correction source';
  end if;
  update public.events set starts_on = date '2026-11-06', ends_on = date '2026-11-07'
    where id = ev.id;
  perform core.write_audit(ev.org_id, 'event.schedule_correction', 'public.events', ev.id,
    jsonb_build_object('starts_on', ev.starts_on, 'ends_on', ev.ends_on),
    jsonb_build_object('starts_on', date '2026-11-06', 'ends_on', date '2026-11-07',
      'reason', 'Club-requested schedule correction to November 6–7, 2026'));
end $$;
