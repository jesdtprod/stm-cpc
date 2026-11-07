-- User-identified test events EV-2026-00002 and EV-2026-00003 only.
-- Explicit user override permits permanent deletion of these two test events.
-- Preserve member accounts, assessments, unrelated data and the purge audit.
-- Maintenance grants/policies exist only inside this atomic statement.
do $$
declare
  event_ids text[];
  division_ids text[];
  org text;
  h public.member_cpc_rating_history;
  r public.member_cpc_ratings;
  tbl text;
  priv text;
  undo_grants text[] := '{}';
  sql text;
  schema_granted boolean := false;
  actor_role text := current_user;
  removed integer;
  guest_ids text[];
  tables text[] := array['score_events','match_games','division_results','division_cpc_rating_snapshots',
    'entry_members','entry_guests','matches','draws','event_roster_changes','entries','registrations',
    'event_participant_cpc_ratings','event_participants','member_cpc_rating_history','rank_history',
    'division_stages','divisions','events','persons'];
  previous_rpc text := coalesce(current_setting('core.rpc',true),'off');
  reason constant text := 'User-authorized permanent test-event cleanup (2620)';
  n integer;
begin
  perform set_config('lock_timeout','10s',true);
  select id into strict org from public.orgs where code='cpc' and deleted_at is null;
  if exists (select 1 from core.audit_log where org_id=org
    and action='event.test_data_purged' and new_values->>'migration'='2620') then return; end if;
  lock table public.events, public.divisions, public.division_stages, public.registrations,
    public.entries, public.matches, public.member_cpc_ratings, public.member_cpc_rating_history,
    public.member_ranks, public.rank_history, public.event_participants, public.persons,
    public.event_participant_cpc_ratings, public.payment_submissions in share row exclusive mode;
  select array_agg(id order by id) into event_ids from public.events
    where org_id=org and (doc_no,id) in (
      ('EV-2026-00002','01M61GRT7AQ9JB7V34G2NZW0HB'),
      ('EV-2026-00003','01M6T9PNQRPK825N59P9SJ7SMN'));
  if cardinality(event_ids) is distinct from 2 then raise exception 'Expected both reviewed test events'; end if;
  select array_agg(id order by id) into division_ids from public.divisions where event_id=any(event_ids);
  if cardinality(division_ids) is distinct from 4
    or (select count(*) from public.registrations where event_id=any(event_ids)) <> 33
    or (select count(*) from public.matches m join public.division_stages s on s.id=m.division_stage_id
        where s.division_id=any(division_ids)) <> 78
    or (select count(*) from public.member_cpc_rating_history x where x.division_id=any(division_ids)
        and x.entry_type='division_finalization' and not exists (
          select 1 from public.member_cpc_rating_history y where y.reverses_id=x.id)) <> 2 then
    raise exception 'Reviewed cleanup scope changed; inspect before proceeding';
  end if;
  if exists (select 1 from public.payment_submissions p join public.registrations rg
    on p.source_type='event_registration' and p.source_id=rg.id where rg.event_id=any(event_ids))
    or exists (select 1 from public.registrations where event_id=any(event_ids) and fee_snapshot<>0) then
    raise exception 'Payments or charged registrations require separate reconciliation';
  end if;
  perform set_config('core.rpc','on',true);

  -- Subtract only unreversed test contributions from current values, never reset
  -- other disciplines, initial assessments or later legitimate adjustments.
  for h in select x.* from public.member_cpc_rating_history x where x.division_id=any(division_ids)
      and x.entry_type='division_finalization' and not exists (
        select 1 from public.member_cpc_rating_history y where y.reverses_id=x.id)
      order by x.member_id,x.discipline,x.created_at desc,x.id desc loop
    select * into strict r from public.member_cpc_ratings where id=h.rating_id and deleted_at is null for update;
    if r.points is null or r.points-h.points_delta not between 0 and 8
      or r.eligible_match_count<h.match_count_delta then
      raise exception 'Rating reversal requires review';
    end if;
    insert into public.member_cpc_rating_history(org_id,unit_id,member_id,rating_id,discipline,
      entry_type,division_id,reverses_id,points_before,points_after,match_count_before,match_count_after,
      points_delta,match_count_delta,revision,reason,meta)
    values (org,r.unit_id,r.member_id,r.id,h.discipline,'reversal',h.division_id,h.id,
      r.points,r.points-h.points_delta,r.eligible_match_count,r.eligible_match_count-h.match_count_delta,
      -h.points_delta,-h.match_count_delta,h.revision,reason,jsonb_build_object('migration','2620'));
    update public.member_cpc_ratings set points=r.points-h.points_delta,
      eligible_match_count=r.eligible_match_count-h.match_count_delta,reason='User-authorized permanent test-event cleanup (2620)' where id=r.id;
    -- Restore assessment provenance once this rating has no remaining played
    -- matches. Keep the original assessment ledger rows unchanged.
    if r.eligible_match_count=h.match_count_delta then
      update public.member_cpc_ratings current_rating set
        source=assessment.entry_type,reason=assessment.reason,
        assessed_at=assessment.created_at,assessed_by=assessment.created_by
      from (select a.entry_type,a.reason,a.created_at,a.created_by
        from public.member_cpc_rating_history a
        where a.rating_id=r.id and a.entry_type in ('admin_assessment','member_self')
        order by a.created_at desc,a.id desc limit 1) assessment
      where current_rating.id=r.id;
    end if;
  end loop;
  -- Preserve actual current Club Rank, recalculated from restored ratings.
  perform core.sync_member_club_rank(member_id, reason) from (
    select distinct member_id from public.member_cpc_rating_history where division_id=any(division_ids)
  ) affected;
  update public.member_ranks set source_division_id=null where source_division_id=any(division_ids);
  select array_agg(p.id) into guest_ids from public.persons p
    where p.kind='guest'
      and exists (select 1 from public.event_participants ep where ep.person_id=p.id and ep.event_id=any(event_ids))
      and not exists (select 1 from public.event_participants ep where ep.person_id=p.id and ep.event_id<>all(event_ids))
      and not exists (select 1 from public.members m where m.person_id=p.id)
      and not exists (select 1 from public.profiles pr where pr.person_id=p.id)
      and not exists (select 1 from public.payment_submissions ps where ps.payer_person_id=p.id)
      and not exists (select 1 from public.consents c where c.person_id=p.id or c.accepted_by_person_id=p.id)
      and not exists (select 1 from public.person_relations pr where pr.person_id=p.id or pr.related_person_id=p.id);

  -- Store exact scoped IDs so every maintenance DELETE is limited to reviewed rows.
  create temp table purge_2620_ids (table_name text, id text, primary key(table_name,id)) on commit drop;
  insert into purge_2620_ids select 'events',unnest(event_ids);
  insert into purge_2620_ids select 'divisions',unnest(division_ids);
  insert into purge_2620_ids select 'persons',unnest(guest_ids);
  insert into purge_2620_ids select 'division_stages',id from public.division_stages where division_id=any(division_ids);
  insert into purge_2620_ids select 'registrations',id from public.registrations where event_id=any(event_ids);
  insert into purge_2620_ids select 'entries',id from public.entries where division_id=any(division_ids);
  insert into purge_2620_ids select 'event_participants',id from public.event_participants where event_id=any(event_ids);
  insert into purge_2620_ids select 'event_participant_cpc_ratings',id from public.event_participant_cpc_ratings
    where participant_id in (select id from purge_2620_ids where table_name='event_participants');
  insert into purge_2620_ids select 'matches',id from public.matches
    where division_stage_id in (select id from purge_2620_ids where table_name='division_stages');
  insert into purge_2620_ids select 'draws',id from public.draws
    where division_stage_id in (select id from purge_2620_ids where table_name='division_stages');
  insert into purge_2620_ids select 'match_games',id from public.match_games
    where match_id in (select id from purge_2620_ids where table_name='matches');
  insert into purge_2620_ids select 'score_events',id from public.score_events
    where match_id in (select id from purge_2620_ids where table_name='matches');
  insert into purge_2620_ids select 'division_results',id from public.division_results where division_id=any(division_ids);
  insert into purge_2620_ids select 'division_cpc_rating_snapshots',id from public.division_cpc_rating_snapshots where division_id=any(division_ids);
  insert into purge_2620_ids select 'entry_members',id from public.entry_members where division_id=any(division_ids);
  insert into purge_2620_ids select 'entry_guests',id from public.entry_guests
    where entry_id in (select id from purge_2620_ids where table_name='entries');
  insert into purge_2620_ids select 'event_roster_changes',id from public.event_roster_changes where event_id=any(event_ids);
  insert into purge_2620_ids select 'member_cpc_rating_history',id from public.member_cpc_rating_history where division_id=any(division_ids);
  insert into purge_2620_ids select 'rank_history',id from public.rank_history where division_id=any(division_ids) or event_id=any(event_ids);
  perform core.write_audit(org,'event.test_data_purge_scope','public.events',event_ids[1],null,
    jsonb_build_object('migration','2620','counts',(select jsonb_object_agg(x.table_name,x.n) from (
      select table_name,count(*) n from purge_2620_ids group by table_name) x)));
  if not has_schema_privilege('cpc_maintenance','public','USAGE') then
    grant usage on schema public to cpc_maintenance;
    schema_granted:=true;
  end if;
  grant select on purge_2620_ids to cpc_maintenance;
  foreach tbl in array tables loop
    foreach priv in array array['SELECT','DELETE'] loop
      if not has_table_privilege('cpc_maintenance','public.'||tbl,priv) then
        execute format('grant %s on public.%I to cpc_maintenance',priv,tbl);
        undo_grants:=array_append(undo_grants,format('revoke %s on public.%I from cpc_maintenance',priv,tbl));
      end if;
    end loop;
    execute format('create policy purge_2620_maintenance on public.%I to cpc_maintenance using (true)',tbl);
  end loop;
  if exists (select 1 from pg_auth_members a join pg_roles role_row on role_row.oid=a.roleid
    join pg_roles g on g.oid=a.grantor join pg_roles m on m.oid=a.member
    where role_row.rolname='cpc_maintenance' and g.rolname=actor_role and m.rolname=actor_role) then
    raise exception 'Unexpected existing self-granted maintenance membership';
  end if;
  execute format('grant cpc_maintenance to %I with admin false, inherit false, set true granted by %I',actor_role,actor_role);
  execute 'set local role cpc_maintenance';
  foreach tbl in array tables loop
    -- Self-referential tables must be deleted leaves-first with restrictive FKs.
    if tbl in ('score_events','member_cpc_rating_history','rank_history','matches','draws') then
      loop
        execute format('delete from public.%I t where t.id in (select id from pg_temp.purge_2620_ids where table_name=%L)
          and not exists (select 1 from public.%I child where child.%I=t.id)',tbl,tbl,tbl,
          case tbl when 'matches' then 'feeds_match_id' when 'draws' then 'replaces_draw_id' else 'reverses_id' end);
        get diagnostics removed=row_count;
        exit when removed=0;
      end loop;
    else
      execute format('delete from public.%I where id in (select id from pg_temp.purge_2620_ids where table_name=%L)',tbl,tbl);
    end if;
    execute format('select count(*) from public.%I where id in (select id from pg_temp.purge_2620_ids where table_name=%L)',tbl,tbl) into n;
    if n<>0 then raise exception 'Scoped records remain in %; transaction aborted',tbl; end if;
  end loop;
  execute format('set local role %I',actor_role);
  execute format('revoke cpc_maintenance from %I granted by %I',actor_role,actor_role);
  foreach tbl in array tables loop execute format('drop policy purge_2620_maintenance on public.%I',tbl); end loop;
  foreach sql in array undo_grants loop execute sql; end loop;
  if schema_granted then revoke usage on schema public from cpc_maintenance; end if;
  perform set_config('core.rpc',previous_rpc,true);
  perform core.write_audit(org,'event.test_data_purged','public.events',event_ids[1],null,
    jsonb_build_object('migration','2620','events',to_jsonb(event_ids),'member_accounts_preserved',true,
      'rating_contributions_reversed',2,'user_authorized_hard_delete',true));
end $$;
