-- 1330_public_club_home_stats: the public landing page may show the total number
-- of active CPC members, without exposing identities or any member details.
create or replace function public.club_home_stats() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'active_members', count(*) filter (
      where m.status = 'active' and m.deleted_at is null
    )
  )
  from public.orgs o
  left join public.members m on m.org_id = o.id
  where o.code = 'cpc' and o.deleted_at is null
$$;

revoke all on function public.club_home_stats() from public, anon, authenticated;
grant execute on function public.club_home_stats() to anon, authenticated, service_role;
