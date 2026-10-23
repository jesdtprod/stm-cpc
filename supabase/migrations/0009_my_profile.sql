-- 0009_my_profile (PLAN 1B.2 / 1B.5)
-- The signed-in user's own profile id and org, for the client session and error reports.
-- Same pattern as my_permissions: privileged lookup in core, SECURITY INVOKER wrapper in public.

create or replace function core.my_profile() returns table (profile_id text, org_id text)
language sql stable security definer set search_path = '' as $$
  select p.id, p.org_id
  from public.profiles p
  where p.auth_user_id = (select auth.uid())
    and p.is_active and p.deleted_at is null
  limit 1
$$;
revoke all on function core.my_profile() from public, anon;
grant execute on function core.my_profile() to authenticated, service_role;

create or replace function public.my_profile() returns table (profile_id text, org_id text)
language sql stable security invoker set search_path = '' as $$
  select * from core.my_profile()
$$;
revoke all on function public.my_profile() from public, anon;
grant execute on function public.my_profile() to authenticated;
