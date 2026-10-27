-- Migration 1600: Always return member_no in core.ranking_list for club members.
-- This allows the player's ID number to be displayed below their name in the ranking list.

create or replace function core.ranking_list(p_category_id text default null)
returns table (member_id text, member_no text, display_name text, category_id text, category_name text, rank_id text,
  rank_name text, rank_idx integer, since timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_org text;
begin
  select pr.org_id into v_org from public.profiles pr where pr.auth_user_id = (select auth.uid()) and pr.is_active and pr.deleted_at is null limit 1;
  if v_org is null or not core.is_org_member(v_org) then
    raise exception 'sign in to see the ranking' using errcode = '42501';
  end if;
  return query
  select m.id, m.member_no, pe.display_name, c.id, c.name, r.id, r.name, ch.idx, mr.updated_at
  from public.member_ranks mr
  join public.members m on m.id = mr.member_id and m.deleted_at is null and m.status = 'active'
  join public.persons pe on pe.id = m.person_id
  join public.ranks r on r.id = mr.rank_id
  join public.rank_ladders l on l.id = r.ladder_id
  join public.categories c on c.id = l.category_id
  join core.rank_chain(v_org) ch on ch.rank_id = r.id
  where mr.deleted_at is null and m.org_id = v_org and (p_category_id is null or c.id = p_category_id)
  order by ch.idx desc, pe.display_name;
end $$;

create or replace function public.ranking_list(p_category_id text default null)
returns table (member_id text, member_no text, display_name text, category_id text, category_name text, rank_id text,
  rank_name text, rank_idx integer, since timestamptz)
language sql stable security invoker set search_path = '' as $$ select * from core.ranking_list(p_category_id) $$;

