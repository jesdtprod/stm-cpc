-- Club-requested reset for testing a new registration workflow.
-- Withdraw only EV-2026-00002's active registrations; retain profiles and history.
do $$
declare ev public.events; reg public.registrations; released integer := 0;
begin
  perform set_config('lock_timeout', '10s', true);
  select e.* into strict ev from public.events e join public.orgs o on o.id = e.org_id
    where o.code = 'cpc' and o.deleted_at is null and e.doc_no = 'EV-2026-00002' for update of e;
  if exists (select 1 from core.audit_log where record_id = ev.id
      and action = 'event.registration_reset' and new_values ->> 'migration' = '2340') then return; end if;
  perform 1 from public.divisions where event_id = ev.id order by id for update;
  if ev.status not in ('registration_open','registration_closed') or exists (
      select 1 from public.divisions where event_id = ev.id and status <> 'open')
    or exists (select 1 from public.matches m join public.division_stages s on s.id = m.division_stage_id
      join public.divisions d on d.id = s.division_id where d.event_id = ev.id and m.status not in ('void','cancelled'))
    or exists (select 1 from public.draws dr join public.division_stages s on s.id = dr.division_stage_id
      join public.divisions d on d.id = s.division_id where d.event_id = ev.id and dr.status = 'active') then
    raise exception 'Registration reset requires undrawn divisions with no live matches';
  end if;
  if exists (select 1 from public.registrations r where r.event_id = ev.id
      and r.status in ('requested','confirmed','waitlisted') and r.fee_snapshot <> 0)
    or exists (select 1 from public.payment_submissions p join public.registrations r
      on p.source_type = 'event_registration' and p.source_id = r.id where r.event_id = ev.id) then
    raise exception 'Inspect fees and payments before resetting this event';
  end if;
  -- Waitlisted rows first, so withdrawing confirmed rows cannot promote them.
  for reg in select * from public.registrations where event_id = ev.id
      and status in ('requested','confirmed','waitlisted')
      order by (status = 'waitlisted') desc, id for update loop
    perform core.release_registration(reg.id, 'Club-requested registration reset for a new workflow (2340)');
    perform core.write_audit(ev.org_id, 'registration.withdraw', 'public.registrations', reg.id,
      jsonb_build_object('status', reg.status),
      jsonb_build_object('status', 'withdrawn', 'reason', 'Club-requested workflow reset', 'migration', '2340'));
    released := released + 1;
  end loop;
  if exists (select 1 from public.entries en join public.divisions d on d.id = en.division_id
      where d.event_id = ev.id and en.status = 'active') then
    raise exception 'Active entries remain after registration reset';
  end if;
  perform core.write_audit(ev.org_id, 'event.registration_reset', 'public.events', ev.id, null,
    jsonb_build_object('migration', '2340', 'withdrawn_registrations', released));
end $$;
