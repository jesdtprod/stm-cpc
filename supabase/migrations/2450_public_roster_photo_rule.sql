-- The public roster photo rule could not see the persons table as a visitor (row security), so no photo was readable.
-- The paths now come from a function that runs with the owner's rights and returns only roster photos.
create or replace function core.roster_avatar_paths() returns table (path text)
language sql stable security definer set search_path = '' as $$
  select pe.avatar_path from public.persons pe
  where pe.avatar_path is not null and pe.deleted_at is null
    and pe.id in (select x.person_id from core.roster_person_ids() x)
$$;
revoke all on function core.roster_avatar_paths() from public;
grant execute on function core.roster_avatar_paths() to anon, authenticated, service_role;

drop policy avatars_public_roster_select on storage.objects;
create policy avatars_public_roster_select on storage.objects for select to anon, authenticated
  using (bucket_id = 'avatars' and name in (select p.path from core.roster_avatar_paths() p));

notify pgrst, 'reload schema';
