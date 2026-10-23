-- 1140_my_access_state_profile (PLAN 3.4)
-- The profile page needs the member's own contact details and address codes to fill the form. They come with
-- my_access_state() so the page makes one call. Only the caller's own row is ever returned.

drop function public.my_access_state();
drop function core.my_access_state();

create or replace function core.my_access_state()
returns table (
  member_id text, member_no text, status text, must_change_password boolean, profile_complete boolean, display_name text,
  mobile text, email text, street_line text, barangay_code text, city_muni_code text, province_code text, region_code text
)
language sql stable security definer set search_path = '' as $$
  select m.id, m.member_no, m.status, coalesce(a.must_change_password, false), core.profile_complete(m.person_id), p.display_name,
         p.mobile, p.email, p.street_line, p.barangay_code, p.city_muni_code, p.province_code, p.region_code
  from public.profiles pr
  join public.members m on m.profile_id = pr.id and m.deleted_at is null
  join public.persons p on p.id = m.person_id
  left join public.member_access a on a.member_id = m.id and a.deleted_at is null
  where pr.auth_user_id = (select auth.uid()) and pr.is_active and pr.deleted_at is null
  limit 1
$$;

create or replace function public.my_access_state()
returns table (
  member_id text, member_no text, status text, must_change_password boolean, profile_complete boolean, display_name text,
  mobile text, email text, street_line text, barangay_code text, city_muni_code text, province_code text, region_code text
)
language sql stable security invoker set search_path = '' as $$ select * from core.my_access_state() $$;

revoke all on function core.my_access_state(), public.my_access_state() from public, anon, authenticated;
grant execute on function core.my_access_state(), public.my_access_state() to authenticated, service_role;
