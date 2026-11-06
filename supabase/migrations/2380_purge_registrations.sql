-- Explicit user override: permanently empty registrations and their linked test
-- records across all events. Approved after the table scope and linked-history
-- impact were disclosed. Keep players, events, current ratings and audit logs.
-- Use the existing maintenance role; no triggers or RLS are disabled.
do $$
declare
  ev public.events;
  tbl text;
  privilege_name text;
  grants_to_revoke text[] := '{}';
  revoke_sql text;
  schema_granted boolean := false;
  original_role text := current_user;
  expected_counts integer[] := array[64,64,4,16,34,36];
  tables text[] := array['division_cpc_rating_snapshots','entry_guests','entry_members','matches','entries','registrations'];
  row_total integer;
  removed integer;
  i integer;
begin
  perform set_config('lock_timeout', '10s', true);
  if exists (select 1 from core.audit_log where action = 'registrations.permanent_purge'
      and new_values ->> 'migration' = '2380') then return; end if;
  select e.* into strict ev from public.events e join public.orgs o on o.id = e.org_id
    where o.code = 'cpc' and o.deleted_at is null and e.doc_no = 'EV-2026-00002' for update of e;
  -- Prevent new records while validating the reviewed purge scope.
  lock table public.registrations, public.entries, public.entry_members, public.entry_guests,
    public.matches, public.match_games, public.score_events, public.division_results,
    public.division_cpc_rating_snapshots, public.event_roster_changes,
    public.payment_submissions, public.ledger_entries in share row exclusive mode;
  for i in 1..array_length(tables, 1) loop
    execute format('select count(*) from public.%I', tables[i]) into row_total;
    if row_total <> expected_counts[i] then
      raise exception 'Purge scope changed: % expected %, found %', tables[i], expected_counts[i], row_total;
    end if;
  end loop;
  if ev.status not in ('registration_open','registration_closed')
    or exists (select 1 from public.registrations where event_id <> ev.id
      or status not in ('withdrawn','requested') or fee_snapshot <> 0)
    or exists (select 1 from public.divisions where event_id = ev.id and status <> 'open')
    or exists (select 1 from public.matches m join public.division_stages s on s.id = m.division_stage_id
      join public.divisions d on d.id = s.division_id where d.event_id <> ev.id or m.status <> 'void')
    or exists (select 1 from public.division_cpc_rating_snapshots s join public.divisions d on d.id = s.division_id
      where d.event_id <> ev.id)
    or exists (select 1 from public.match_games)
    or exists (select 1 from public.score_events)
    or exists (select 1 from public.division_results)
    or exists (select 1 from public.event_roster_changes)
    or exists (select 1 from public.payment_submissions where source_type = 'event_registration')
    or exists (select 1 from public.ledger_entries where source_type = 'event_registration') then
    raise exception 'Purge requires the reviewed withdrawn roster, void matches and no scores or payments';
  end if;
  if not has_schema_privilege('cpc_maintenance', 'public', 'USAGE') then
    grant usage on schema public to cpc_maintenance;
    schema_granted := true;
  end if;
  foreach tbl in array tables loop
    foreach privilege_name in array array['SELECT','DELETE'] loop
      if not has_table_privilege('cpc_maintenance', 'public.' || tbl, privilege_name) then
        execute format('grant %s on public.%I to cpc_maintenance', privilege_name, tbl);
        grants_to_revoke := array_append(grants_to_revoke,
          format('revoke %s on public.%I from cpc_maintenance', privilege_name, tbl));
      end if;
    end loop;
    -- Transaction-only policy for a NOLOGIN maintenance role. Table privileges
    -- permit reads/deletes only. The policy and extra grants are removed below.
    execute format('create policy purge_2380_maintenance on public.%I to cpc_maintenance using (true)', tbl);
  end loop;
  -- The existing membership deliberately has SET FALSE. Add a transaction-only
  -- grant from this administrator, then remove that exact grant after deletion.
  if exists (select 1 from pg_auth_members a join pg_roles r on r.oid = a.roleid
      join pg_roles g on g.oid = a.grantor join pg_roles m on m.oid = a.member
      where r.rolname = 'cpc_maintenance' and g.rolname = original_role and m.rolname = original_role) then
    raise exception 'Unexpected existing self-granted maintenance membership';
  end if;
  execute format('grant cpc_maintenance to %I with admin false, inherit false, set true granted by %I', original_role, original_role);
  execute 'set local role cpc_maintenance';
  delete from public.division_cpc_rating_snapshots;
  delete from public.entry_guests;
  delete from public.entry_members;
  -- Respect restrictive self-FKs rather than disabling them or using CASCADE.
  loop
    delete from public.matches m where not exists (
      select 1 from public.matches feeder where feeder.feeds_match_id = m.id);
    get diagnostics removed = row_count;
    exit when removed = 0;
  end loop;
  if exists (select 1 from public.matches) then raise exception 'Match feed cycle prevents the purge'; end if;
  delete from public.entries;
  delete from public.registrations;
  execute format('set local role %I', original_role);
  execute format('revoke cpc_maintenance from %I granted by %I', original_role, original_role);
  foreach tbl in array tables loop
    execute format('drop policy purge_2380_maintenance on public.%I', tbl);
  end loop;
  foreach revoke_sql in array grants_to_revoke loop execute revoke_sql; end loop;
  if schema_granted then revoke usage on schema public from cpc_maintenance; end if;
  perform core.write_audit(ev.org_id, 'registrations.permanent_purge', 'public.events', ev.id,
    jsonb_build_object('registrations',36,'entries',34,'entry_guests',64,'entry_members',4,'void_matches',16,'draw_rating_snapshots',64),
    jsonb_build_object('migration','2380','registrations',0,
      'reason','User explicitly approved permanent deletion of every registration and linked records',
      'player_profiles_preserved',true,'event_settings_preserved',true));
end $$;

