-- Publish only current club rating values alongside the existing public member fields.
-- The public directory switch and membership eligibility remain authoritative.
create or replace function public.public_members() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_org text;
begin
  select o.id into v_org from public.orgs o where o.code = 'cpc' and o.deleted_at is null;
  if v_org is null or not core.setting_bool(v_org, 'public.members_enabled', true) then
    return jsonb_build_object('enabled', false);
  end if;
  return jsonb_build_object('enabled', true, 'members', coalesce((
    select jsonb_agg(jsonb_build_object(
      'name', q.display_name, 'first_name', q.first_name, 'last_name', q.last_name,
      'middle_name', q.middle_initial, 'suffix', q.suffix, 'member_no', q.member_no,
      'is_active', q.is_active, 'photo', q.avatar_path, 'category', q.category_name, 'rank', q.rank_name,
      'singles_points', q.singles_points, 'doubles_points', q.doubles_points
    ) order by q.rank_idx desc nulls last, q.display_name, q.member_id)
    from (
      select r.*, m.member_no, (m.status = 'active') as is_active, p.first_name, p.last_name,
        substring(p.middle_name from '[[:alpha:]]') as middle_initial, p.suffix,
        s.points as singles_points, d.points as doubles_points
      from core.public_member_rows() r
      join public.members m on m.id = r.member_id
      join public.persons p on p.id = m.person_id
      left join public.member_cpc_ratings s on s.member_id = m.id and s.org_id = m.org_id
        and s.discipline = 'singles' and s.deleted_at is null
      left join public.member_cpc_ratings d on d.member_id = m.id and d.org_id = m.org_id
        and d.discipline = 'doubles' and d.deleted_at is null
    ) q
  ), '[]'::jsonb));
end $$;
revoke all on function public.public_members() from public, anon, authenticated;
grant execute on function public.public_members() to anon, authenticated, service_role;
notify pgrst, 'reload schema';
