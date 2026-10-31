-- Public availability flag only; private membership settings remain inaccessible.
create or replace function public.membership_applications_open() returns boolean
language sql stable security definer set search_path = '' as $$
  select core.signup_enabled()
$$;
revoke all on function public.membership_applications_open() from public, anon, authenticated;
grant execute on function public.membership_applications_open() to anon, authenticated, service_role;
comment on function public.membership_applications_open() is 'Public registration availability only. Registration is still enforced by member-signup.';

notify pgrst, 'reload schema';
