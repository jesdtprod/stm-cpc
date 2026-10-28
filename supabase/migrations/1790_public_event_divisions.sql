-- 1790_public_event_divisions: list each public event's divisions (type, who may enter, entries taken / limit)
-- on the landing info. Counts only; no registrant names leave the database.
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
        'divisions_count', (select count(*)::int from public.divisions d where d.event_id = e.id and d.status <> 'cancelled'),
        'divisions', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'name', d.name, 'format', d.format, 'gender', d.gender, 'age_group', d.age_group,
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
notify pgrst, 'reload schema';
