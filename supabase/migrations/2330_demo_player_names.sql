-- Explicit correction of fictional seed labels, before a replacement draw.
-- Only exact seed-generated guest names in EV-2026-00002 are eligible.
-- Original labels remain in audit history and voided draw snapshots.
do $$
declare
  ev public.events;
  player record;
  parts text[];
  new_name text;
  first_names text[] := array['Adrian','Marco','Paolo','Luis','Diego','Rafael','Miguel','Gabriel',
    'Daniel','Carlo','Andre','Nico','Enzo','Javier','Lorenzo','Mateo'];
  renamed integer := 0;
begin
  select e.* into strict ev from public.events e join public.orgs o on o.id = e.org_id
    where o.code = 'cpc' and o.deleted_at is null and e.doc_no = 'EV-2026-00002' for update of e;
  if exists (select 1 from core.audit_log where record_id = ev.id
      and action = 'event.demo_names_corrected' and new_values ->> 'migration' = '2330') then return; end if;
  if ev.status <> 'registration_closed' or exists (
      select 1 from public.divisions where event_id = ev.id and status <> 'open')
    or exists (select 1 from public.draws dr join public.division_stages s on s.id = dr.division_stage_id
      join public.divisions d on d.id = s.division_id where d.event_id = ev.id and dr.status = 'active') then
    raise exception 'Correct fictional seed labels only while all divisions are undrawn';
  end if;
  -- Table locks prevent concurrent roster changes. These two snapshot guards are
  -- restored before commit; RLS, identity, audit and stamp triggers stay enabled.
  lock table public.registrations, public.entry_guests in access exclusive mode;
  alter table public.registrations disable trigger c2_registrations_update;
  alter table public.entry_guests disable trigger c2_entry_guests_frozen;
  for player in
    select ep.id as participant_id, p.id as person_id, p.display_name, d.id as division_id
    from public.event_participants ep join public.persons p on p.id = ep.person_id
    join public.divisions d on d.event_id = ep.event_id
    join public.categories c on c.id = d.category_id
    where ep.event_id = ev.id and ep.member_id is null and ep.deleted_at is null
      and p.kind = 'guest' and p.deleted_at is null
      and p.display_name ~ ('^TEST ONLY - ' || c.name || ' ' || right(d.id,6) || ' Team ([1-9]|1[0-6]) Player [AB]$')
    order by ep.id for update of ep, p
  loop
    parts := regexp_match(player.display_name, '^TEST ONLY - (Beginner|Novice) [A-Z0-9]+ Team ([0-9]+) Player ([AB])$');
    if parts is null then raise exception 'Unexpected seed label'; end if;
    new_name := first_names[parts[2]::integer] || ' ' || case
      when parts[1] = 'Beginner' and parts[3] = 'A' then 'Santos'
      when parts[1] = 'Beginner' then 'Reyes'
      when parts[3] = 'A' then 'Cruz' else 'Garcia' end;
    if exists (select 1 from public.event_participants ep where ep.person_id = player.person_id
        and ep.event_id <> ev.id and ep.deleted_at is null) then
      raise exception 'Seed guest is used in another event';
    end if;
    update public.persons set display_name = new_name,
      meta = meta || jsonb_build_object('fictional_demo', true, 'demo_original_name', player.display_name)
      where id = player.person_id;
    update public.registrations set guest_name_snapshot = new_name
      where event_id = ev.id and guest_participant_id = player.participant_id
        and guest_name_snapshot = player.display_name;
    update public.registrations set guest_partner_name_snapshot = new_name
      where event_id = ev.id and guest_partner_participant_id = player.participant_id
        and guest_partner_name_snapshot = player.display_name;
    update public.entry_guests set display_name_snapshot = new_name
      where participant_id = player.participant_id and display_name_snapshot = player.display_name;
    perform core.write_audit(ev.org_id, 'demo.player_name_corrected', 'public.persons', player.person_id,
      jsonb_build_object('display_name', player.display_name),
      jsonb_build_object('display_name', new_name, 'fictional_demo', true, 'migration', '2330'));
    renamed := renamed + 1;
  end loop;
  if renamed <> 54 then raise exception 'Expected 54 fictional seed players, found %', renamed; end if;
  alter table public.registrations enable trigger c2_registrations_update;
  alter table public.entry_guests enable trigger c2_entry_guests_frozen;
  perform core.write_audit(ev.org_id, 'event.demo_names_corrected', 'public.events', ev.id, null,
    jsonb_build_object('migration', '2330', 'fictional_players', renamed));
end $$;
