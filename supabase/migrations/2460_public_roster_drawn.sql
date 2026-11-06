-- The public roster rows also say whether the division has been drawn (so the page can offer the bracket) and carry the division id
-- used for that link. A division id alone gives no access: the bracket page needs a signed-in account.
drop function public.public_event_rosters();
create or replace function public.public_event_rosters()
returns table (event_name text, starts_on date, division_name text, division_id text, drawn boolean, team_name text, p1_name text, p1_path text, p1_guest boolean,
  p2_name text, p2_path text, p2_guest boolean)
language sql stable security definer set search_path = '' as $$
  select e.name, e.starts_on, d.name, d.id,
    exists (select 1 from public.division_stages s where s.division_id = d.id and s.status in ('drawn', 'in_progress', 'completed')),
    nullif(btrim(r.meta ->> 'team_name'), ''),
    coalesce(r.guest_name_snapshot, pe1.display_name), pe1.avatar_path, r.member_id is null,
    coalesce(r.guest_partner_name_snapshot, pe2.display_name), pe2.avatar_path, r.guest_partner_participant_id is not null
  from public.registrations r
  join public.events e on e.id = r.event_id
    and e.status in ('registration_open', 'registration_closed', 'drawn', 'in_progress', 'completed')
    and e.org_id in (select o.id from public.orgs o where o.code = 'cpc' and o.deleted_at is null)
  join public.divisions d on d.id = r.division_id and d.status <> 'cancelled'
  left join public.members m1 on m1.id = r.member_id
  left join public.event_participants ep1 on ep1.id = r.guest_participant_id
  left join public.persons pe1 on pe1.id = coalesce(m1.person_id, ep1.person_id) and pe1.deleted_at is null
  left join public.members m2 on m2.id = r.meta ->> 'partner_member_id'
  left join public.event_participants ep2 on ep2.id = r.guest_partner_participant_id
  left join public.persons pe2 on pe2.id = coalesce(m2.person_id, ep2.person_id) and pe2.deleted_at is null
  where r.status = 'confirmed'
  order by e.starts_on, e.name, d.name, 6 nulls last, 7
$$;
revoke all on function public.public_event_rosters() from public, anon, authenticated;
grant execute on function public.public_event_rosters() to anon, authenticated, service_role;

notify pgrst, 'reload schema';
