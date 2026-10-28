-- Unrated guests follow the member NR rule: only Beginner divisions starting at Beginner Low.
-- This is registration eligibility only; it does not assign a numerical rating.
create or replace function core.guest_assessed_rank(p_participant text, p_format text, p_org text) returns text
language plpgsql stable security definer set search_path = '' as $$
declare v_points numeric;
begin
  if not core.cpc_points_enabled(p_org) then return null; end if;
  select r.points into v_points from public.event_participant_cpc_ratings r
    where r.participant_id = p_participant and r.org_id = p_org and r.discipline = p_format and r.deleted_at is null;
  -- The division-specific check below decides whether NR is allowed.
  return core.cpc_rank_for_points(p_org, coalesce(v_points, 2.000));
end $$;

create or replace function core.guest_registration_problem(p_participant text, p_division text, p_rank text, p_confirm boolean default false) returns text
language plpgsql stable security definer set search_path = '' as $$
declare ep public.event_participants; pe public.persons; dv public.divisions; ev public.events;
  rk record; lo integer; hi integer; age_years integer; grp text; v_points numeric; v_low text;
begin
  select * into ep from public.event_participants where id = p_participant and deleted_at is null;
  if not found or ep.member_id is not null then return 'Choose a guest participant.'; end if;
  select * into dv from public.divisions where id = p_division;
  if not found or dv.event_id <> ep.event_id or dv.org_id <> ep.org_id then return 'That participant belongs to another event.'; end if;
  select * into ev from public.events where id = dv.event_id;
  if not ev.allow_guest_players then return 'This event does not allow guest players.'; end if;
  if ev.dupr_rated then return 'DUPR guest eligibility is not available yet.'; end if;
  if dv.status <> 'open' or (ev.status <> 'registration_open' and not ((p_confirm or core.has_permission(ev.org_id,dv.unit_id,'events.admin_roster')) and ev.status = 'registration_closed')) then return 'Registration is not open.'; end if;
  if not p_confirm and not core.has_permission(ev.org_id,dv.unit_id,'events.admin_roster') and ((ev.registration_opens_at is not null and now() < ev.registration_opens_at)
    or (ev.registration_closes_at is not null and now() >= ev.registration_closes_at)) then return 'Outside the registration window.'; end if;
  select * into pe from public.persons where id = ep.person_id and kind = 'guest' and deleted_at is null;
  if not found or exists(select 1 from public.members where person_id = pe.id) then return 'Choose an active guest identity.'; end if;
  if core.cpc_points_enabled(ev.org_id) then
    select cr.points into v_points from public.event_participant_cpc_ratings cr
      where cr.participant_id = ep.id and cr.org_id = ev.org_id and cr.discipline = dv.format and cr.deleted_at is null;
    if v_points is null then
      select coalesce(
        (select r.code from public.ranks r where r.id = dv.min_rank_id),
        (select r.code from public.ranks r join public.rank_ladders l on l.id = r.ladder_id
          where l.category_id = dv.category_id and r.deleted_at is null and l.deleted_at is null order by r.sort_order limit 1)) into v_low;
      if v_low is distinct from 'beginner-low' then
        return format('This guest has no %s rating. Unrated guests can join only Beginner divisions starting at Beginner Low.', dv.format);
      end if;
    end if;
    p_rank := core.cpc_rank_for_points(ev.org_id, coalesce(v_points, 2.000));
  end if;
  select r.sort_order, l.category_id into rk from public.ranks r join public.rank_ladders l on l.id = r.ladder_id
    join public.categories c on c.id = l.category_id
    where r.id = p_rank and r.deleted_at is null and l.deleted_at is null and c.deleted_at is null and r.org_id = ep.org_id;
  if not found or rk.category_id <> dv.category_id then return 'Assess the guest at a rank in this division category.'; end if;
  select sort_order into lo from public.ranks where id = dv.min_rank_id;
  select sort_order into hi from public.ranks where id = dv.max_rank_id;
  if rk.sort_order < lo or rk.sort_order > hi then return 'The guest rank is outside this division rank band.'; end if;
  if dv.gender in ('male','female') and pe.gender is distinct from dv.gender then return 'The guest does not meet this division gender requirement.'; end if;
  grp := btrim(coalesce(dv.age_group,''));
  if grp ~ '^\d{1,2}\+$' or grp ~ '^\d{1,2}\s*-\s*\d{1,2}$' then
    if pe.date_of_birth is null then return 'The guest birth date is required for this age group.'; end if;
    age_years := extract(year from age(ev.starts_on, pe.date_of_birth))::integer;
    if age_years < substring(grp from '^\d+')::integer
      or (grp !~ '\+$' and age_years > substring(grp from '(\d+)$')::integer) then return 'The guest does not meet this division age requirement.'; end if;
  end if;
  return null;
end $$;
notify pgrst, 'reload schema';
