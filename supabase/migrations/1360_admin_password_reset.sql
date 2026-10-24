-- 1360_admin_password_reset: the database half of the secure admin password reset (the Edge Function makes the new
-- random password and sets it in Auth; the script files it away; nothing prints it).
--   admin_reset_target(member_no)   the Auth user of an ACTIVE member who holds the admin role, or null for anyone else,
--                                   so this path cannot be used to reset an ordinary member
--   admin_reset_done(member_no)     marks the account as needing a new password at the next sign-in and records it in the audit log
-- Both are for the service role only.
create or replace function public.admin_reset_target(p_member_no text) returns uuid
language sql stable security definer set search_path = '' as $$
  select p.auth_user_id
  from public.members m
  join public.profiles p on p.id = m.profile_id and p.deleted_at is null
  join public.org_members om on om.profile_id = p.id and om.org_id = m.org_id and om.deleted_at is null and om.is_active
  join public.roles r on r.id = om.role_id and r.code = 'admin' and r.deleted_at is null
  where m.member_no = p_member_no and m.status = 'active' and m.deleted_at is null
  limit 1
$$;

create or replace function public.admin_reset_done(p_member_no text) returns void
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
  perform core.write_audit(v_member.org_id, 'admin.password_reset', 'public.members', v_member.id);
end $$;

revoke all on function public.admin_reset_target(text), public.admin_reset_done(text) from public, anon, authenticated;
grant execute on function public.admin_reset_target(text), public.admin_reset_done(text) to service_role;
