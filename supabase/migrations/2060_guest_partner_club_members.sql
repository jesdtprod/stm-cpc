-- Admin guest registration may find all eligible club members, not just event participants.
-- A null result id means a member needs an event participant identity before registration.
create or replace function core.eligible_event_partners(p_division_id text, p_guest_participant_id text default null)
returns table(id text, display_name text, member_id text, member_no text, is_guest boolean)
language plpgsql stable security definer set search_path = '' as $$
declare dv public.divisions; ev public.events; v_ratings boolean;
begin
  select * into dv from public.divisions d where d.id = p_division_id;
  if not found then raise exception 'division not found' using errcode = '22023'; end if;
  select * into ev from public.events e where e.id = dv.event_id;
  if core.current_profile_id() is null or not core.has_permission(ev.org_id,dv.unit_id,'events.admin_roster') then
    raise exception 'you do not have permission to register guests' using errcode = '42501';
  end if;
  if dv.format <> 'doubles' then return; end if;
  v_ratings := core.cpc_points_enabled(ev.org_id);
  if v_ratings and p_guest_participant_id is not null
    and core.guest_registration_problem(p_guest_participant_id,dv.id,null) is not null then return; end if;
  return query
  select q.pid,q.dname,q.mid,q.mno,q.guest from (
    select ep.id as pid,pe.display_name as dname,null::text as mid,null::text as mno,true as guest
    from public.event_participants ep join public.persons pe on pe.id = ep.person_id
    where ep.event_id = ev.id and ep.org_id = ev.org_id and ep.member_id is null
      and ep.deleted_at is null and pe.deleted_at is null and ep.id is distinct from p_guest_participant_id
      and (not v_ratings or core.guest_registration_problem(ep.id,dv.id,null) is null)
      and not exists(select 1 from public.registrations r where r.division_id = dv.id
        and r.status in ('requested','confirmed','waitlisted')
        and (r.guest_participant_id = ep.id or r.guest_partner_participant_id = ep.id))
    union all
    select ep.id,pe.display_name,m.id,m.member_no,false
    from public.members m join public.persons pe on pe.id = m.person_id
    left join public.event_participants ep on ep.event_id = ev.id and ep.member_id = m.id and ep.deleted_at is null
    where m.org_id = ev.org_id and m.status = 'active' and m.deleted_at is null and pe.deleted_at is null
      and core.registration_problem(m.id,dv.id,true) is null
      and not exists(select 1 from public.registrations r where r.division_id = dv.id
        and r.status in ('requested','confirmed','waitlisted')
        and (r.member_id = m.id or r.meta->>'partner_member_id' = m.id))
  ) q order by q.dname,q.mid,q.pid;
end $$;

create function public.ensure_event_member_participant(p_id text,p_event_id text,p_member_id text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare ev public.events; existing public.event_participants;
begin
  select * into ev from public.events where id = p_event_id;
  if not found or core.current_profile_id() is null or not core.has_permission(ev.org_id,ev.unit_id,'events.admin_roster') then
    raise exception 'you do not have permission to manage event participants' using errcode = '42501';
  end if;
  if p_id is null or not core.is_ulid(p_id) or p_member_id is null then
    raise exception 'participant and member IDs are required' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('event-member:' || p_event_id || ':' || p_member_id,0));
  select * into existing from public.event_participants ep where ep.id = p_id;
  if found and (existing.event_id <> p_event_id or existing.member_id is distinct from p_member_id) then
    raise exception 'this participant ID was used for a different request' using errcode = 'CP422';
  end if;
  select * into existing from public.event_participants ep
    where ep.event_id = ev.id and ep.member_id = p_member_id and ep.deleted_at is null;
  if found then return jsonb_build_object('id',existing.id,'member_id',existing.member_id,'replayed',true); end if;
  return public.create_event_participant(p_id,p_event_id,p_member_id);
end $$;
revoke all on function public.ensure_event_member_participant(text,text,text) from public,anon,authenticated;
grant execute on function public.ensure_event_member_participant(text,text,text) to authenticated,service_role;
notify pgrst, 'reload schema';
