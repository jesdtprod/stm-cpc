-- Profile photos for the signed-in club ranking only; the bucket stays private.
create or replace function core.can_read_ranked_avatar(p_path text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.persons pe
    join public.members m on m.person_id = pe.id
    join public.member_ranks mr on mr.member_id = m.id and mr.deleted_at is null
    where pe.avatar_path = p_path and pe.deleted_at is null
      and m.deleted_at is null and m.status = 'active'
      and core.is_org_member(m.org_id)
  )
$$;
revoke all on function core.can_read_ranked_avatar(text) from public, anon, authenticated;
grant execute on function core.can_read_ranked_avatar(text) to authenticated;

create policy avatars_ranked_select on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and core.can_read_ranked_avatar(name));

create or replace function core.ranking_photos(p_member_ids text[])
returns table (member_id text, avatar_path text)
language plpgsql stable security definer set search_path = '' as $$
declare v_org text;
begin
  select pr.org_id into v_org from public.profiles pr
  where pr.auth_user_id = (select auth.uid()) and pr.is_active and pr.deleted_at is null limit 1;
  if v_org is null or not core.is_org_member(v_org) then
    raise exception 'sign in to see ranking photos' using errcode = '42501';
  end if;
  if cardinality(p_member_ids) > 1000 then
    raise exception 'request at most 1000 ranking photos' using errcode = '22023';
  end if;
  return query select distinct m.id, pe.avatar_path
  from public.members m
  join public.persons pe on pe.id = m.person_id and pe.deleted_at is null
  join public.member_ranks mr on mr.member_id = m.id and mr.deleted_at is null
  where m.org_id = v_org and m.id = any(p_member_ids)
    and m.status = 'active' and m.deleted_at is null and pe.avatar_path is not null;
end $$;
create or replace function public.ranking_photos(p_member_ids text[])
returns table (member_id text, avatar_path text)
language sql stable security invoker set search_path = '' as $$ select * from core.ranking_photos(p_member_ids) $$;
revoke all on function core.ranking_photos(text[]), public.ranking_photos(text[]) from public, anon, authenticated;
grant execute on function core.ranking_photos(text[]), public.ranking_photos(text[]) to authenticated, service_role;
