-- Rename only the 29 teams added by seed-event-demo-teams.sql.
-- The original three registrations and every player pairing remain unchanged.
do $$
declare
  ev public.events;
  reg record;
  n integer := 0;
  names text[] := array['Emerald Aces','Golden Eagles','Court Kings','Rally Rockets',
    'Dink Dynasty','Baseline Blazers','Net Navigators','Paddle Panthers',
    'Spin Masters','Volley Vikings','Smash Falcons','Crosscourt Crew',
    'Green Vipers','Sunset Strikers','Thunder Paddles','Silver Hawks',
    'Rapid Rallies','Firestorm Aces','Blue Comets','Topspin Titans',
    'Dink Dragons','Court Crusaders','Paddle Pirates','Net Ninjas',
    'Volley Wolves','Rally Rangers','Phoenix Paddles','Smash Sharks','Golden Geckos'];
begin
  perform set_config('lock_timeout','10s',true);
  select e.* into strict ev from public.events e join public.orgs o on o.id=e.org_id
    where o.code='cpc' and o.deleted_at is null and e.doc_no='EV-2026-00002' for update of e;
  if exists (select 1 from core.audit_log where action='event.fictional_team_names'
      and record_id=ev.id and new_values->>'migration'='2410') then return; end if;
  perform 1 from public.divisions where event_id=ev.id order by id for update;
  if ev.status not in ('registration_open','registration_closed') or exists (
    select 1 from public.divisions where event_id=ev.id and status<>'open') then
    raise exception 'Rename generated teams only before the draw';
  end if;
  for reg in select r.* from public.registrations r where r.event_id=ev.id and r.status='confirmed'
      and r.meta->>'team_name'=upper(r.guest_name_snapshot || ' / ' || r.guest_partner_name_snapshot)
      order by r.division_id,r.guest_name_snapshot,r.id for update loop
    n := n+1;
    if n>array_length(names,1) then raise exception 'Unexpected generated team count'; end if;
    perform core.apply_team_name(reg.id,reg.division_id,names[n]);
    perform core.write_audit(ev.org_id,'registration.team_name_corrected','public.registrations',reg.id,
      jsonb_build_object('team_name',reg.meta->>'team_name'),
      jsonb_build_object('team_name',core.team_name_clean(names[n]),'migration','2410'));
  end loop;
  if n<>29 then raise exception 'Expected 29 generated teams, found %',n; end if;
  perform core.write_audit(ev.org_id,'event.fictional_team_names','public.events',ev.id,null,
    jsonb_build_object('migration','2410','renamed_teams',n,'original_teams_preserved',3));
end $$;
