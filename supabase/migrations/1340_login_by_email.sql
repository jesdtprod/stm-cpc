-- 1340_login_by_email: lets the member-login function find a member from the email address on their profile.
-- member_no_for_email(email) returns the member ID only when exactly one member with an account uses that address
-- (compared without regard to capitals). Two members sharing an address, or no member, both give null, so the
-- function can never pick the wrong person. It is callable only by the service role (the Edge Function): nobody can
-- use it from a browser to find out who owns an address. The password is still required, and the same lockout,
-- CAPTCHA and one generic failure message apply.
create or replace function public.member_no_for_email(p_email text) returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_nos text[];
begin
  if v_email = '' or char_length(v_email) > 254 then
    return null;
  end if;
  select array_agg(m.member_no) into v_nos
  from public.members m join public.persons pe on pe.id = m.person_id
  where lower(btrim(pe.email)) = v_email and m.profile_id is not null and m.deleted_at is null and pe.deleted_at is null;
  if v_nos is null or cardinality(v_nos) <> 1 then
    return null;
  end if;
  return v_nos[1];
end $$;

revoke all on function public.member_no_for_email(text) from public, anon, authenticated;
grant execute on function public.member_no_for_email(text) to service_role;
