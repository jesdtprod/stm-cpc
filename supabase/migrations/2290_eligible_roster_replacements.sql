-- Replacement choices use the same server eligibility checks as saving a roster.
create function core.roster_replacement_choices(p_registration_id text,p_player integer)
returns table(id text,member_id text,display_name text,rank_name text)
language plpgsql stable security definer set search_path = '' as $$
declare src public.registrations; dv public.divisions; ev public.events;
begin
  select * into src from public.registrations r where r.id=p_registration_id;
  if not found or not core.has_permission(src.org_id,src.unit_id,'events.admin_roster') then
    raise exception 'Only an administrator can choose roster replacements' using errcode='42501';
  end if;
  select * into dv from public.divisions d where d.id=src.division_id;
  select * into ev from public.events e where e.id=src.event_id;
  if src.status not in ('requested','confirmed') or dv.status<>'open'
    or ev.status not in ('registration_open','registration_closed')
    or exists(select 1 from public.division_stages s join public.draws dr on dr.division_stage_id=s.id
      where s.division_id=dv.id and dr.status='active') then
    raise exception 'Choose a current entry before the draw' using errcode='22023';
  end if;
  if p_player is null or p_player<1 or p_player>cardinality(core.roster_players(src)) then
    raise exception 'Choose a player in this entry' using errcode='22023';
  end if;
  return query
    with candidates as (
      select ep.id,ep.member_id,pe.display_name,pe.gender,
        case when ep.member_id is not null then 'm:'||ep.member_id else 'g:'||ep.id end as player_key,
        case when ep.member_id is null then
          coalesce(core.guest_assessed_rank(ep.id,dv.format,src.org_id),
            case when not core.cpc_points_enabled(src.org_id) then
              (select case when r.guest_participant_id=ep.id then r.guest_rank_id else r.guest_partner_rank_id end
                from public.registrations r where r.division_id=dv.id
                  and (r.guest_participant_id=ep.id or r.guest_partner_participant_id=ep.id)
                order by r.created_at desc limit 1) end)
        when core.cpc_points_enabled(src.org_id) then
          (select core.cpc_rank_for_points(src.org_id,cr.points) from public.member_cpc_ratings cr
            where cr.member_id=ep.member_id and cr.discipline=dv.format and cr.deleted_at is null)
        else (select mr.rank_id from public.member_ranks mr where mr.member_id=ep.member_id and mr.deleted_at is null)
        end as eligible_rank
      from public.event_participants ep join public.persons pe on pe.id=ep.person_id
      where ep.event_id=src.event_id and ep.org_id=src.org_id and ep.deleted_at is null and pe.deleted_at is null
    )
    select c.id,c.member_id,c.display_name,rk.name
    from candidates c left join public.ranks rk on rk.id=c.eligible_rank
    where case when c.member_id is null then core.guest_registration_problem(c.id,dv.id,c.eligible_rank)
      else core.registration_problem(c.member_id,dv.id,true) end is null
      and not exists(select 1 from public.registrations r where r.division_id=dv.id
        and r.status in ('requested','confirmed','waitlisted') and c.player_key=any(core.roster_players(r)))
      and (dv.gender is distinct from 'mixed' or dv.format<>'doubles' or
        c.gender = case (select pe.gender from public.persons pe where pe.id=
          case when left((core.roster_players(src))[3-p_player],2)='m:' then
            (select m.person_id from public.members m where m.id=substr((core.roster_players(src))[3-p_player],3))
          else (select ep.person_id from public.event_participants ep where ep.id=substr((core.roster_players(src))[3-p_player],3)) end)
        when 'male' then 'female' when 'female' then 'male' end)
    order by c.display_name,c.id;
end $$;
revoke all on function core.roster_replacement_choices(text,integer) from public,anon,authenticated;
grant execute on function core.roster_replacement_choices(text,integer) to authenticated;
create function public.roster_replacement_choices(p_registration_id text,p_player integer)
returns table(id text,member_id text,display_name text,rank_name text)
language sql security invoker set search_path = '' as $$
  select * from core.roster_replacement_choices(p_registration_id,p_player)
$$;
revoke all on function public.roster_replacement_choices(text,integer) from public,anon,authenticated;
grant execute on function public.roster_replacement_choices(text,integer) to authenticated;
notify pgrst,'reload schema';
