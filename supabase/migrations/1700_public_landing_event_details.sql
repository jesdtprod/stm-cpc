-- 1700_public_landing_event_details: include public tournament schedule, registration window,
-- rating/ranking system flags, template format name, and division count on public events.
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
        'divisions_count', (select count(*)::int from public.divisions d where d.event_id = e.id and d.status <> 'cancelled')
      ) order by e.starts_on, e.name)
      from (
        select x.* from public.events x, today t
        where x.org_id in (select id from club)
          and x.status in ('registration_open', 'registration_closed', 'drawn', 'in_progress')
          and x.ends_on >= t.d
        order by x.starts_on, x.name limit 6) e), '[]'::jsonb),
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

