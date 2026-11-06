-- Archive the four unused initial seed guests; preserve any guest now in use.
do $$
declare ev public.events; guest record; archived integer := 0;
  previous_rpc text := coalesce(current_setting('core.rpc',true),'off');
begin
  perform set_config('lock_timeout','10s',true);
  select e.* into strict ev from public.events e join public.orgs o on o.id=e.org_id
    where o.code='cpc' and o.deleted_at is null and e.doc_no='EV-2026-00002' for update of e;
  if exists (select 1 from core.audit_log where record_id=ev.id
      and action='event.unused_test_guests_archived' and new_values->>'migration'='2420') then return; end if;
  perform 1 from public.divisions where event_id=ev.id order by id for update;
  perform set_config('core.rpc','on',true);
  for guest in select ep.id,ep.person_id from public.event_participants ep
      join public.persons p on p.id=ep.person_id
      where ep.event_id=ev.id and ep.member_id is null and ep.deleted_at is null
        and p.kind='guest' and p.deleted_at is null
        and p.display_name in ('TEST ONLY - Beginner TADNY3 Player A','TEST ONLY - Beginner TADNY3 Player B',
          'TEST ONLY - Novice YA22ZC Player A','TEST ONLY - Novice YA22ZC Player B')
      order by ep.id for update of ep,p loop
    if exists (select 1 from public.registrations where guest_participant_id=guest.id or guest_partner_participant_id=guest.id)
      or exists (select 1 from public.entry_guests where participant_id=guest.id)
      or exists (select 1 from public.division_cpc_rating_snapshots where participant_id=guest.id)
      or exists (select 1 from public.payment_submissions where payer_person_id=guest.person_id) then continue; end if;
    update public.event_participants set deleted_at=now(),delete_reason='Unused initial test guest cleanup (2420)'
      where id=guest.id;
    if not exists (select 1 from public.event_participants where person_id=guest.person_id and deleted_at is null)
      and not exists (select 1 from public.members where person_id=guest.person_id) then
      update public.persons set deleted_at=now(),delete_reason='Unused initial test guest cleanup (2420)'
        where id=guest.person_id;
    end if;
    archived := archived+1;
  end loop;
  perform set_config('core.rpc',previous_rpc,true);
  perform core.write_audit(ev.org_id,'event.unused_test_guests_archived','public.events',ev.id,null,
    jsonb_build_object('migration','2420','archived',archived,'used_profiles_preserved',true));
end $$;
