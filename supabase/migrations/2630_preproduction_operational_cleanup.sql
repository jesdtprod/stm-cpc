-- Explicit user authorization: existing bookings/payments are test data; clear
-- all notifications and disposable client diagnostics before production.
-- Keep members/imports, accounts, assessments, club setup, security and audit.
-- Does not drop tables, reset counters, disable RLS or retain elevated grants.
do $$
declare
  org text;
  actor_role text := current_user;
  tables text[] := array['member_notification_reads','member_notifications','notifications',
    'client_errors','booking_events','booking_participants','bookings','payment_submissions','ledger_entries'];
  tbl text;
  priv text;
  undo_grants text[] := '{}';
  statement text;
  schema_granted boolean := false;
  counts jsonb := '{}'::jsonb;
  n bigint;
begin
  perform set_config('lock_timeout','10s',true);
  select id into strict org from public.orgs where code='cpc' and deleted_at is null;
  if exists(select 1 from core.audit_log where org_id=org and action='preproduction.operational_cleanup'
    and new_values->>'migration'='2630') then return; end if;
  if not exists(select 1 from core.audit_log where org_id=org and action='event.test_data_purged'
    and new_values->>'migration'='2620') then raise exception 'Apply reviewed event cleanup 2620 first'; end if;
  lock table public.member_notification_reads,public.member_notifications,public.notifications,
    public.client_errors,public.booking_events,public.booking_participants,public.bookings,
    public.payment_submissions,public.ledger_entries in share row exclusive mode;
  -- The inspected financial tables are empty. Do not silently purge new money.
  if exists(select 1 from public.payment_submissions) or exists(select 1 from public.ledger_entries)
    or (select count(*) from public.bookings)<>6 then
    raise exception 'Booking/payment scope changed; review new records before cleanup';
  end if;
  foreach tbl in array tables loop
    execute format('select count(*) from public.%I where org_id is distinct from %L',tbl,org) into n;
    -- Client errors can be anonymous (NULL org); the user requested all diagnostics.
    if n<>0 and tbl<>'client_errors' then raise exception 'Other organization records in %',tbl; end if;
    execute format('select count(*) from public.%I',tbl) into n;
    counts:=counts||jsonb_build_object(tbl,n);
  end loop;
  if not has_schema_privilege('cpc_maintenance','public','USAGE') then
    grant usage on schema public to cpc_maintenance;
    schema_granted:=true;
  end if;
  foreach tbl in array tables loop
    foreach priv in array array['SELECT','DELETE'] loop
      if not has_table_privilege('cpc_maintenance','public.'||tbl,priv) then
        execute format('grant %s on public.%I to cpc_maintenance',priv,tbl);
        undo_grants:=array_append(undo_grants,format('revoke %s on public.%I from cpc_maintenance',priv,tbl));
      end if;
    end loop;
    execute format('create policy purge_2630_maintenance on public.%I to cpc_maintenance using (true)',tbl);
  end loop;
  if exists(select 1 from pg_auth_members a join pg_roles role_row on role_row.oid=a.roleid
    join pg_roles g on g.oid=a.grantor join pg_roles m on m.oid=a.member
    where role_row.rolname='cpc_maintenance' and g.rolname=actor_role and m.rolname=actor_role) then
    raise exception 'Unexpected existing self-granted maintenance membership';
  end if;
  execute format('grant cpc_maintenance to %I with admin false, inherit false, set true granted by %I',actor_role,actor_role);
  execute 'set local role cpc_maintenance';
  foreach tbl in array tables loop
    -- Payments/ledger were asserted empty above and receive no DELETE statement.
    if tbl not in ('payment_submissions','ledger_entries') then
      execute format('delete from public.%I',tbl);
    end if;
    execute format('select count(*) from public.%I',tbl) into n;
    if n<>0 then raise exception 'Rows remain in %',tbl; end if;
  end loop;
  execute format('set local role %I',actor_role);
  execute format('revoke cpc_maintenance from %I granted by %I',actor_role,actor_role);
  foreach tbl in array tables loop execute format('drop policy purge_2630_maintenance on public.%I',tbl); end loop;
  foreach statement in array undo_grants loop execute statement; end loop;
  if schema_granted then revoke usage on schema public from cpc_maintenance; end if;
  perform core.write_audit(org,'preproduction.operational_cleanup','public.orgs',org,null,
    jsonb_build_object('migration','2630','deleted_counts',counts,'user_authorized_hard_delete',true,
      'members_imports_accounts_assessments_setup_preserved',true,'security_and_audit_preserved',true));
end $$;
