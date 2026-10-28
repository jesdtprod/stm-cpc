-- Each Home visit samples at most 15 active CPC members, without replacement.
-- Photo signing checks eligibility independently of the random draw, so a second
-- request cannot reject a photo merely because it drew a different sample.
create or replace function public.club_home_stats() returns jsonb
language sql volatile security definer set search_path = '' as $$
  with club as (
    select o.id from public.orgs o where o.code = 'cpc' and o.deleted_at is null
  ), active_members as (
    select m.id, p.first_name, p.last_name, p.display_name, p.avatar_path
    from public.members m join club c on c.id = m.org_id
    join public.persons p on p.id = m.person_id and p.deleted_at is null
    where m.status = 'active' and m.deleted_at is null
  ), displayed_members as materialized (
    select *, random() as draw from active_members order by draw, id limit 15
  ), representative as (
    select * from displayed_members order by draw, id limit 1
  )
  select jsonb_build_object(
    'active_members', (select count(*) from active_members),
    'member_initials', (select coalesce(
      nullif(upper(left(btrim(coalesce(first_name, '')), 1) || left(btrim(coalesce(last_name, '')), 1)), ''),
      nullif(upper(left(btrim(coalesce(display_name, '')), 1)), ''), 'C') from representative),
    'member_badges', coalesce((select jsonb_agg(jsonb_build_object(
      'initials', coalesce(
        nullif(upper(left(btrim(coalesce(first_name, '')), 1) || left(btrim(coalesce(last_name, '')), 1)), ''),
        nullif(upper(left(btrim(coalesce(display_name, '')), 1)), ''), 'C'),
      'avatar_path', avatar_path) order by draw, id) from displayed_members), '[]'::jsonb)
  )
$$;
revoke all on function public.club_home_stats() from public, anon, authenticated;
grant execute on function public.club_home_stats() to anon, authenticated, service_role;

create function core.landing_active_member_photo(p_path text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.members m
    join public.orgs o on o.id = m.org_id and o.code = 'cpc' and o.deleted_at is null
    join public.persons p on p.id = m.person_id and p.deleted_at is null
    where m.status = 'active' and m.deleted_at is null and p.avatar_path = p_path
  )
$$;
revoke all on function core.landing_active_member_photo(text) from public, anon, authenticated;
grant execute on function core.landing_active_member_photo(text) to anon, authenticated, service_role;
drop policy avatars_landing_select on storage.objects;
create policy avatars_landing_select on storage.objects for select to anon, authenticated
  using (bucket_id = 'avatars' and core.landing_active_member_photo(name));
comment on function core.landing_active_member_photo(text) is
  'Public Home photo eligibility: current avatar files of active, nondeleted CPC members only. The bucket stays private; uploads and unrelated files are not granted.';
notify pgrst, 'reload schema';
