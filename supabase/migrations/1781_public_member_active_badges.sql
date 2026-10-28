-- Expose only an active-membership boolean for public card badges.
-- Existing publication, eligibility and private-field exclusions stay in force.
create or replace function public.public_members() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_org text;
begin
  select o.id into v_org from public.orgs o where o.code = 'cpc' and o.deleted_at is null;
  if v_org is null or not core.setting_bool(v_org, 'public.members_enabled', true) then
    return jsonb_build_object('enabled', false);
  end if;
  return jsonb_build_object('enabled', true, 'members', coalesce((
    select jsonb_agg(jsonb_build_object(
      'name', q.display_name, 'first_name', q.first_name, 'last_name', q.last_name,
      'middle_name', q.middle_initial, 'suffix', q.suffix, 'member_no', q.member_no,
      'is_active', q.is_active, 'photo', q.avatar_path, 'category', q.category_name, 'rank', q.rank_name
    ) order by q.rank_idx desc nulls last, q.display_name, q.member_id)
    from (
      select r.*, m.member_no, (m.status = 'active') as is_active, p.first_name, p.last_name,
        substring(p.middle_name from '[[:alpha:]]') as middle_initial, p.suffix
      from core.public_member_rows() r
      join public.members m on m.id = r.member_id
      join public.persons p on p.id = m.person_id
    ) q
  ), '[]'::jsonb));
end $$;
revoke all on function public.public_members() from public, anon, authenticated;
grant execute on function public.public_members() to anon, authenticated, service_role;
notify pgrst, 'reload schema';
