-- 1370_member_password_reset: lets the club owner give an ordinary active member a new password (a forgotten password
-- when no email reset is set up). Like the administrator reset (1360) it is service role only: the Edge Function makes the
-- random password and sets it in Auth, a script files it away outside the repository, and nothing prints it.
--   member_reset_target(member_no)   the Auth user of an ACTIVE member who has a sign-in, or null (unknown, not active, no login)
--   member_reset_done(member_no)     marks the account as needing a new password at the next sign-in and writes the audit log
create or replace function public.member_reset_target(p_member_no text) returns uuid
language sql stable security definer set search_path = '' as $$
  select p.auth_user_id
  from public.members m
  join public.profiles p on p.id = m.profile_id and p.deleted_at is null and p.is_active
  where m.member_no = p_member_no and m.status = 'active' and m.deleted_at is null and p.auth_user_id is not null
  limit 1
$$;

create or replace function public.member_reset_done(p_member_no text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_member public.members;
begin
  select * into v_member from public.members m where m.member_no = p_member_no and m.deleted_at is null;
  if not found then
    raise exception 'member not found' using errcode = '22023';
  end if;
  update public.member_access set must_change_password = true, temp_password_expires_at = null
  where member_id = v_member.id and deleted_at is null;
  perform core.write_audit(v_member.org_id, 'member.password_reset', 'public.members', v_member.id);
end $$;

revoke all on function public.member_reset_target(text), public.member_reset_done(text) from public, anon, authenticated;
grant execute on function public.member_reset_target(text), public.member_reset_done(text) to service_role;
