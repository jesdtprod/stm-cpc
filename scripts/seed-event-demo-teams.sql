-- Explicit demo-data operation for EV-2026-00002, not an automatic migration.
-- One clearly labeled guest team per division; no sign-in accounts or passwords.
-- Uses the existing permission-checked RPCs and leaves approvals/payment rules intact.
-- Run: npx supabase@2.118.0 db query --linked -f scripts/seed-event-demo-teams.sql -o json
begin;
create temp table demo_results(division_name text,player_name text,partner_name text,rating numeric,status text);
do $$
declare ev public.events; dv public.divisions; actor uuid; pts numeric; ids text[];
  participant text; person_id text; registration text; existing public.registrations;
  names text[]; i integer; result jsonb; classification text; born date;
begin
  select * into ev from public.events where id='01M61GRT7AQ9JB7V34G2NZW0HB' and doc_no='EV-2026-00002' for update;
  if not found or ev.name <> 'STM Halloween Pickleball Tournament 2026'
    or ev.status not in ('registration_open','registration_closed') or not ev.allow_guest_players or ev.fee <> 0 then
    raise exception 'Expected free guest-enabled event is not available; inspect before seeding';
  end if;
  select p.auth_user_id into actor from public.profiles p
    join public.org_members om on om.profile_id=p.id and om.org_id=ev.org_id and om.unit_id is null
    join public.roles ro on ro.id=om.role_id
    join public.role_permissions rp on rp.role_id=ro.id
    join public.permissions pm on pm.id=rp.permission_id
    where p.is_active and p.deleted_at is null and om.is_active and om.deleted_at is null
      and ro.deleted_at is null and rp.deleted_at is null and pm.deleted_at is null and pm.code='events.admin_roster'
    order by p.id limit 1;
  if actor is null then raise exception 'No authorized roster administrator is available'; end if;
  perform set_config('request.jwt.claims',json_build_object('sub',actor,'role','authenticated')::text,true);
  for dv in select * from public.divisions where event_id=ev.id and status<>'cancelled' order by id for update loop
    if dv.status<>'open' or dv.format<>'doubles' or dv.age_group is not null then
      raise exception 'This seed supports only the inspected open doubles divisions without age restrictions';
    end if;
    perform pg_advisory_xact_lock(hashtextextended('demo-team:' || dv.id,0));
    select c.name into classification from public.categories c where c.id=dv.category_id;
    select greatest(2.000,r.rating_min) into pts from public.ranks r
      join public.rank_ladders l on l.id=r.ladder_id
      where l.category_id=dv.category_id and r.deleted_at is null and l.deleted_at is null
        and (dv.min_rank_id is null or r.sort_order >= (select sort_order from public.ranks where id=dv.min_rank_id))
        and (dv.max_rank_id is null or r.sort_order <= (select sort_order from public.ranks where id=dv.max_rank_id))
      order by r.sort_order limit 1;
    if pts is null then raise exception 'Division has no eligible numerical rating band'; end if;
    names := array['TEST ONLY - ' || classification || ' ' || right(dv.id,6) || ' Player A',
                   'TEST ONLY - ' || classification || ' ' || right(dv.id,6) || ' Player B'];
    ids := array[]::text[];
    for i in 1..2 loop
      select ep.id into participant from public.event_participants ep join public.persons pe on pe.id=ep.person_id
        where ep.event_id=ev.id and ep.member_id is null and ep.deleted_at is null and pe.deleted_at is null
          and pe.kind='guest' and pe.display_name=names[i];
      if participant is null then
        participant := core.ulid(); person_id := core.ulid(); born := date '2000-01-01';
        perform public.create_guest_event_participant(participant,ev.id,person_id,names[i],null,
          case when dv.gender in ('male','female') then dv.gender when i=1 then 'male' else 'female' end,
          born,null,null,pts);
      end if;
      ids := array_append(ids,participant);
    end loop;
    select * into existing from public.registrations r where r.division_id=dv.id
      and r.guest_participant_id=ids[1] and r.guest_partner_participant_id=ids[2]
      and r.status in ('requested','confirmed','waitlisted');
    if found then
      result := jsonb_build_object('id',existing.id,'status',existing.status);
    else
      if dv.max_entries is not null and (select count(*) from public.registrations r
        where r.division_id=dv.id and r.status in ('requested','confirmed')) >= dv.max_entries then
        raise exception 'Division is full; demo seed will not take a waitlist place';
      end if;
      registration := core.ulid();
      result := public.register_guest_for_event(registration,dv.id,ids[1],null,ids[2],null);
    end if;
    insert into demo_results values(dv.name,names[1],names[2],pts,result->>'status');
  end loop;
end $$;
commit;
select division_name,player_name,partner_name,rating,status from demo_results order by division_name;
