-- Guest profiles may be created without either rating. Blank remains NR, never zero.
-- Division registration eligibility is enforced separately (including NR Beginner Low).
create or replace function public.create_guest_event_participant(
  p_id text, p_event_id text, p_guest_person_id text, p_guest_name text,
  p_guest_mobile text default null, p_guest_gender text default null,
  p_guest_birth_date date default null, p_dupr_id text default null,
  p_singles_rating numeric default null, p_doubles_rating numeric default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare ev public.events; guest public.persons; result jsonb; replay jsonb;
  dupr text := nullif(upper(btrim(coalesce(p_dupr_id,''))), '');
  guest_name text := nullif(btrim(coalesce(p_guest_name,'')), '');
  mobile text := nullif(btrim(coalesce(p_guest_mobile,'')), '');
begin
  select * into ev from public.events where id = p_event_id for update;
  if not found or not core.has_permission(ev.org_id,ev.unit_id,'events.admin_roster') then
    raise exception 'You do not have permission to manage these event participants' using errcode = '42501';
  end if;
  if dupr is not null and dupr !~ '^[A-Z0-9]{1,32}$' then
    raise exception 'DUPR ID must contain 1 to 32 letters or numbers' using errcode = '22023';
  end if;
  if p_guest_person_id is null or not core.is_ulid(p_guest_person_id) or guest_name is null
    or char_length(guest_name) > 120 then
    raise exception 'A guest ID and name are required (up to 120 characters)' using errcode = '22023';
  end if;
  if p_singles_rating is not null then perform core.cpc_rating_band_code(p_singles_rating); end if;
  if p_doubles_rating is not null then perform core.cpc_rating_band_code(p_doubles_rating); end if;
  replay := core.idem_begin(p_id,ev.org_id,'guest_participant.create',jsonb_build_object(
    'event',p_event_id,'person',p_guest_person_id,'name',guest_name,'mobile',mobile,
    'gender',p_guest_gender,'birth_date',p_guest_birth_date,'dupr_id',dupr,
    'singles',p_singles_rating,'doubles',p_doubles_rating));
  if replay is not null then return replay; end if;
  begin
    insert into public.persons(id,org_id,kind,display_name,mobile,gender,date_of_birth,dupr_id)
      values(p_guest_person_id,ev.org_id,'guest',guest_name,mobile,p_guest_gender,p_guest_birth_date,dupr)
      on conflict(id) do nothing;
  exception when unique_violation then
    raise exception 'That DUPR ID is already recorded for another person in this club' using errcode = '23505';
  end;
  select * into guest from public.persons where id = p_guest_person_id for update;
  if guest.org_id <> ev.org_id or guest.kind <> 'guest' or guest.deleted_at is not null then
    raise exception 'Choose a guest identity in this club' using errcode = '22023';
  end if;
  if guest.dupr_id is distinct from dupr then
    raise exception 'Adding a participant cannot replace an existing person DUPR ID' using errcode = 'CP422';
  end if;
  result := public.create_event_participant(p_id,ev.id,null,p_guest_person_id,guest_name,mobile,p_guest_gender,p_guest_birth_date);
  if p_singles_rating is not null then
    insert into public.event_participant_cpc_ratings(org_id,unit_id,participant_id,discipline,points,source,reason,assessed_at,assessed_by)
      values(ev.org_id,ev.unit_id,p_id,'singles',p_singles_rating,'admin_assessment','Assessed when added as a guest',now(),core.current_profile_id());
  end if;
  if p_doubles_rating is not null then
    insert into public.event_participant_cpc_ratings(org_id,unit_id,participant_id,discipline,points,source,reason,assessed_at,assessed_by)
      values(ev.org_id,ev.unit_id,p_id,'doubles',p_doubles_rating,'admin_assessment','Assessed when added as a guest',now(),core.current_profile_id());
  end if;
  if p_singles_rating is not null or p_doubles_rating is not null then
    perform core.write_audit(ev.org_id,'cpc_rating.guest_assessment','public.event_participants',p_id,null,
      jsonb_build_object('participant_id',p_id,'singles',p_singles_rating,'doubles',p_doubles_rating,'at','add guest'));
  end if;
  result := result || jsonb_build_object('dupr_id',dupr);
  perform core.idem_complete(p_id,result);
  return result;
end $$;
revoke all on function public.create_guest_event_participant(text,text,text,text,text,text,date,text,numeric,numeric) from public,anon,authenticated;
grant execute on function public.create_guest_event_participant(text,text,text,text,text,text,date,text,numeric,numeric) to authenticated;
notify pgrst, 'reload schema';
