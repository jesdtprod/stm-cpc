-- User-identified test events EV-2026-00002 and EV-2026-00003 only.
-- No deletes: reverse rating effects, void play, withdraw rosters, archive guests.
-- Retain scores, snapshots and append-only logs for audit. Run atomically.
do $$
declare
  event_ids text[];
  division_ids text[];
  org text;
  h public.member_cpc_rating_history;
  r public.member_cpc_ratings;
  rh public.rank_history;
  fn text;
  definition text;
  changed text;
  definitions text[] := '{}';
  previous_rpc text := coalesce(current_setting('core.rpc',true),'off');
  reason constant text := 'User-requested cleanup of two test events (2620)';
  n integer;
begin
  perform set_config('lock_timeout','10s',true);
  select id into strict org from public.orgs where code='cpc' and deleted_at is null;
  if exists (select 1 from core.audit_log where org_id=org
    and action='event.test_data_cancelled' and new_values->>'migration'='2620') then return; end if;
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
      eligible_match_count=r.eligible_match_count-h.match_count_delta,reason=reason where id=r.id;
  end loop;
  for rh in select x.* from public.rank_history x where x.division_id=any(division_ids)
      and x.reverses_id is null and not exists (select 1 from public.rank_history y where y.reverses_id=x.id)
      order by x.occurred_at desc,x.id desc loop
    insert into public.rank_history(org_id,member_id,from_rank_id,to_rank_id,division_id,event_id,
      reason,reverses_id,revision,meta)
    values (org,rh.member_id,rh.to_rank_id,rh.from_rank_id,rh.division_id,rh.event_id,
      reason,rh.id,rh.revision,jsonb_build_object('migration','2620'));
  end loop;
  perform core.sync_member_club_rank(member_id, reason) from (
    select distinct member_id from public.member_cpc_rating_history where division_id=any(division_ids)
  ) affected;

  insert into public.score_events(org_id,match_id,kind,payload,reverses_id)
    select org,se.match_id,'corrected',jsonb_build_object('reason',reason,'migration','2620','voided',true),se.id
    from public.score_events se join public.matches m on m.id=se.match_id
    join public.division_stages s on s.id=m.division_stage_id
    where s.division_id=any(division_ids) and se.kind in ('finalized','forfeit')
      and not exists (select 1 from public.score_events x where x.reverses_id=se.id);
  update public.matches m set status='void',status_reason=reason
    from public.division_stages s where s.id=m.division_stage_id and s.division_id=any(division_ids)
      and m.status not in ('void','cancelled');
  update public.draws dr set status='superseded',redo_reason=reason from public.division_stages s
    where s.id=dr.division_stage_id and s.division_id=any(division_ids) and dr.status='active';
  update public.registrations set status='withdrawn',status_reason=reason
    where event_id=any(event_ids) and status in ('requested','confirmed','waitlisted');
  update public.entries set status='withdrawn' where division_id=any(division_ids) and status='active';
  update public.division_results set superseded_at=now() where division_id=any(division_ids) and superseded_at is null;

  -- Existing one-time correction pattern (2320): extend guards transactionally
  -- for completed documents, then restore their exact definitions before commit.
  foreach fn in array array['tg_events_update','tg_divisions_update','tg_stages_update'] loop
    select pg_get_functiondef(to_regprocedure('core.'||fn||'()')) into strict definition;
    definitions:=array_append(definitions,definition);
    changed:=replace(definition, '}'||chr(39)||'::jsonb);',
      '}'||chr(39)||'::jsonb || '||chr(39)||'{"completed":["cancelled"],"finalized":["cancelled"]}'||chr(39)||'::jsonb);');
    if changed=definition then raise exception 'Unexpected state guard: %',fn; end if;
    execute changed;
  end loop;
  update public.division_stages set status='cancelled' where division_id=any(division_ids) and status<>'cancelled';
  update public.divisions set status='cancelled',cancelled_at=now(),cancel_reason=reason,status_reason=reason,
    meta=meta||jsonb_build_object('test_data_cleanup','2620') where id=any(division_ids);
  update public.events set status='cancelled',cancelled_at=now(),cancel_reason=reason,status_reason=reason,
    meta=meta||jsonb_build_object('test_data_cleanup','2620') where id=any(event_ids);
  for n in 1..array_length(definitions,1) loop execute definitions[n]; end loop;

  update public.event_participant_cpc_ratings gr set deleted_at=now(),delete_reason=reason
    from public.event_participants ep where ep.id=gr.participant_id and ep.event_id=any(event_ids) and gr.deleted_at is null;
  update public.event_participants set deleted_at=now(),delete_reason=reason
    where event_id=any(event_ids) and deleted_at is null;
  update public.persons p set deleted_at=now(),delete_reason=reason
    where p.kind='guest' and p.deleted_at is null
      and exists (select 1 from public.event_participants ep where ep.person_id=p.id and ep.event_id=any(event_ids))
      and not exists (select 1 from public.event_participants ep where ep.person_id=p.id and ep.event_id<>all(event_ids))
      and not exists (select 1 from public.members m where m.person_id=p.id)
      and not exists (select 1 from public.payment_submissions ps where ps.payer_person_id=p.id);
  perform set_config('core.rpc',previous_rpc,true);
  perform core.write_audit(org,'event.test_data_cancelled','public.events',event_ids[1],null,
    jsonb_build_object('migration','2620','events',to_jsonb(event_ids),'no_hard_deletes',true));
end $$;
