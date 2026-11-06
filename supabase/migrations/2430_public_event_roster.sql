-- Official roster on the public events page: the approved (confirmed) teams of each published event, with team name, player
-- names and photos. Visible to everyone, as chosen by the club. Only confirmed registrations of published events are shown;
-- drafts, pending, waitlisted and withdrawn entries are never returned. Photos are readable only for those players.

-- Person ids of everyone on an official roster (used by the photo rule below).
create or replace function core.roster_person_ids() returns table (person_id text)
language sql stable security definer set search_path = '' as $$
  select m.person_id from public.registrations r join public.events e on e.id = r.event_id
    join public.members m on m.id = r.member_id
    where r.status = 'confirmed' and e.status in ('registration_open', 'registration_closed', 'drawn', 'in_progress', 'completed')
  union
  select m.person_id from public.registrations r join public.events e on e.id = r.event_id
    join public.members m on m.id = r.meta ->> 'partner_member_id'
    where r.status = 'confirmed' and e.status in ('registration_open', 'registration_closed', 'drawn', 'in_progress', 'completed')
  union
  select ep.person_id from public.registrations r join public.events e on e.id = r.event_id
    join public.event_participants ep on ep.id in (r.guest_participant_id, r.guest_partner_participant_id)
    where r.status = 'confirmed' and e.status in ('registration_open', 'registration_closed', 'drawn', 'in_progress', 'completed')
$$;
revoke all on function core.roster_person_ids() from public;
grant execute on function core.roster_person_ids() to anon, authenticated, service_role;

create or replace function public.public_event_roster(p_event_id text)
returns table (division_id text, team_name text, p1_name text, p1_path text, p1_guest boolean,
  p2_name text, p2_path text, p2_guest boolean)
language sql stable security definer set search_path = '' as $$
  select r.division_id, nullif(btrim(r.meta ->> 'team_name'), ''),
    coalesce(r.guest_name_snapshot, pe1.display_name), pe1.avatar_path, r.member_id is null,
    coalesce(r.guest_partner_name_snapshot, pe2.display_name), pe2.avatar_path, r.guest_partner_participant_id is not null
  from public.registrations r
  join public.events e on e.id = r.event_id and e.id = p_event_id
    and e.status in ('registration_open', 'registration_closed', 'drawn', 'in_progress', 'completed')
    and e.org_id in (select o.id from public.orgs o where o.code = 'cpc' and o.deleted_at is null)
  left join public.members m1 on m1.id = r.member_id
  left join public.event_participants ep1 on ep1.id = r.guest_participant_id
  left join public.persons pe1 on pe1.id = coalesce(m1.person_id, ep1.person_id) and pe1.deleted_at is null
  left join public.members m2 on m2.id = r.meta ->> 'partner_member_id'
  left join public.event_participants ep2 on ep2.id = r.guest_partner_participant_id
  left join public.persons pe2 on pe2.id = coalesce(m2.person_id, ep2.person_id) and pe2.deleted_at is null
  where r.status = 'confirmed'
  order by r.division_id, 2 nulls last, 3
$$;
revoke all on function public.public_event_roster(text) from public, anon, authenticated;
grant execute on function public.public_event_roster(text) to anon, authenticated, service_role;

create policy avatars_public_roster_select on storage.objects for select to anon, authenticated
  using (
    bucket_id = 'avatars'
    and exists (select 1 from public.persons pe
      where pe.avatar_path = storage.objects.name and pe.deleted_at is null
        and pe.id in (select x.person_id from core.roster_person_ids() x))
  );

-- The public events list now carries ids so the page can match each roster to its division.
create or replace function public.public_landing_info() returns jsonb
language sql stable security definer set search_path = '' as $$
  with club as (
    select o.id from public.orgs o where o.code = 'cpc' and o.deleted_at is null
  ), today as (
    select (now() at time zone 'Asia/Manila')::date as d
  )
  select jsonb_build_object(
    'events', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', e.id,
        'name', e.name,
        'starts_on', e.starts_on,
        'ends_on', e.ends_on,
        'location', e.location,
        'status', e.status,
        'fee', e.fee,
        'registration_opens_at', e.registration_opens_at,
        'registration_closes_at', e.registration_closes_at,
        'dupr_rated', e.dupr_rated,
        'apply_cpc_rank_changes', e.apply_cpc_rank_changes,
        'default_format_template_name', (select t.name from public.format_templates t where t.id = e.default_format_template_id),
        'divisions_count', (select count(*)::int from public.divisions d where d.event_id = e.id and d.status <> 'cancelled'),
        'divisions', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'id', d.id, 'name', d.name, 'format', d.format, 'gender', d.gender, 'age_group', d.age_group,
            'category', c.name, 'min_rank', rmin.name, 'max_rank', rmax.name, 'max_entries', d.max_entries,
            'taken', (select count(*)::int from public.registrations r
                      where r.division_id = d.id and r.status in ('requested', 'confirmed'))
          ) order by c.sort_order, d.name), '[]'::jsonb)
          from public.divisions d
          join public.categories c on c.id = d.category_id
          left join public.ranks rmin on rmin.id = d.min_rank_id
          left join public.ranks rmax on rmax.id = d.max_rank_id
          where d.event_id = e.id and d.status <> 'cancelled')
      ) order by e.starts_on, e.name)
      from (
        select x.* from public.events x
        where x.org_id in (select id from club)
          and x.status in ('registration_open', 'registration_closed', 'drawn', 'in_progress', 'completed', 'cancelled')
          -- Drafts remain private; published events remain visible after their end date.
        order by x.starts_on, x.name) e), '[]'::jsonb),
    'courts', coalesce((
      select jsonb_agg(jsonb_build_object('name', c.name, 'indoor', c.indoor, 'surface', c.surface,
        'hours', (
          select jsonb_build_object('opens', to_char(min(h.opens_at), 'HH24:MI'), 'closes', to_char(max(h.closes_at), 'HH24:MI'),
            'days', count(distinct h.weekday))
          from public.court_hours h, today t
          where (h.court_id is null or h.court_id = c.id) and h.org_id = c.org_id and h.deleted_at is null
            and h.valid_from <= t.d and (h.valid_to is null or h.valid_to >= t.d))
        ) order by c.sort_order, c.name)
      from public.courts c
      where c.org_id in (select id from club) and c.deleted_at is null and c.status = 'available'), '[]'::jsonb),
    'results_public', (select coalesce(bool_or(core.setting_bool(id, 'public.results_enabled', false)), false) from club),
    'leaderboard_public', (select coalesce(bool_or(core.setting_bool(id, 'public.leaderboard_enabled', false)), false) from club)
  )
$$;

revoke all on function public.public_landing_info() from public, anon, authenticated;
grant execute on function public.public_landing_info() to anon, authenticated, service_role;


notify pgrst, 'reload schema';
