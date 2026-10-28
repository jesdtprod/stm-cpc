-- Explain why a selected guest cannot search partners instead of displaying a misleading empty list.
create function public.guest_division_eligibility(p_division_id text,p_guest_participant_id text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare dv public.divisions; problem text; v_rank text;
begin
  select * into dv from public.divisions d where d.id = p_division_id;
  if not found or core.current_profile_id() is null or not core.has_permission(dv.org_id,dv.unit_id,'events.admin_roster') then
    raise exception 'you do not have permission to register guests' using errcode = '42501';
  end if;
  problem := core.guest_registration_problem(p_guest_participant_id,dv.id,null);
  if problem is not null and core.cpc_points_enabled(dv.org_id) then
    select r.name into v_rank from public.event_participant_cpc_ratings cr
      join public.ranks r on r.id = core.cpc_rank_for_points(dv.org_id,cr.points)
      where cr.participant_id = p_guest_participant_id and cr.org_id = dv.org_id
        and cr.discipline = dv.format and cr.deleted_at is null and cr.points is not null;
    if v_rank is not null then
      problem := format('Guest rating: %s. %s Choose a division that fits this rating.',v_rank,problem);
    end if;
  end if;
  return jsonb_build_object('eligible',problem is null,'reason',problem);
end $$;
revoke all on function public.guest_division_eligibility(text,text) from public,anon,authenticated;
grant execute on function public.guest_division_eligibility(text,text) to authenticated,service_role;
notify pgrst, 'reload schema';
