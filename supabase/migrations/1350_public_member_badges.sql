-- 1350_public_member_badges: publish at most 15 approved member initials for the landing page.
create or replace function public.club_home_stats() returns jsonb
language sql stable security definer set search_path = '' as $$
  with club as (
    select o.id from public.orgs o where o.code = 'cpc' and o.deleted_at is null
  ), active_members as (
    select m.id, m.created_at, p.first_name, p.last_name, p.display_name
    from public.members m
    join club c on c.id = m.org_id
    join public.persons p on p.id = m.person_id and p.deleted_at is null
    where m.status = 'active' and m.deleted_at is null
  ), displayed_members as (
    select * from active_members order by created_at desc, id desc limit 15
  ), representative as (
    select * from displayed_members order by created_at desc, id desc limit 1
  )
  select jsonb_build_object(
    'active_members', (select count(*) from active_members),
    'member_initials', (
      select coalesce(
        nullif(upper(left(btrim(coalesce(first_name, '')), 1) || left(btrim(coalesce(last_name, '')), 1)), ''),
        nullif(upper(left(btrim(coalesce(display_name, '')), 1)), '')
      )
      from representative
    ),
    'member_badges', coalesce((
      select jsonb_agg(jsonb_build_object(
        'initials', coalesce(
          nullif(upper(left(btrim(coalesce(first_name, '')), 1) || left(btrim(coalesce(last_name, '')), 1)), ''),
          nullif(upper(left(btrim(coalesce(display_name, '')), 1)), ''),
          'C'
        )
      ) order by created_at desc, id desc)
      from displayed_members
    ), '[]'::jsonb)
  )
$$;

revoke all on function public.club_home_stats() from public, anon, authenticated;
grant execute on function public.club_home_stats() to anon, authenticated, service_role;
