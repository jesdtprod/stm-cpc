-- 1530_ranking_screens (PLAN 8.3): what the ranking list and the rank history screens read.
--   * ranking_list(category): every active member who holds a rank, highest first (by the chain of ladders), with the category,
--     the rank and when it was set. Any signed-in member of the club may read it (display names only); staff who can read members
--     also get the member ID and member row ID (for the override button).
--   * rank_history_view(member): a member's rank history, newest first, exactly as rank_history holds it: each row is a move, a
--     reversal of an earlier move after a correction (is_reversal), or a move that has since been reversed (reversed). A member
--     reads their own history; staff who can read members may read anyone's.

create or replace function core.ranking_list(p_category_id text default null)
returns table (member_id text, member_no text, display_name text, category_id text, category_name text, rank_id text,
  rank_name text, rank_idx integer, since timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_org text;
  v_staff boolean;
begin
  select pr.org_id into v_org from public.profiles pr where pr.auth_user_id = (select auth.uid()) and pr.is_active and pr.deleted_at is null limit 1;
  if v_org is null or not core.is_org_member(v_org) then
    raise exception 'sign in to see the ranking' using errcode = '42501';
  end if;
  v_staff := core.has_permission(v_org, null, 'members.read');
  return query
  select m.id, case when v_staff then m.member_no end, pe.display_name, c.id, c.name, r.id, r.name, ch.idx, mr.updated_at
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

create or replace function core.rank_history_view(p_member_id text default null)
returns table (id text, occurred_at timestamptz, from_name text, to_name text, reason text, rule_name text, event_name text,
  division_name text, is_reversal boolean, reversed boolean, revision integer)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_me public.members;
  v_target public.members;
begin
  select m.* into v_me from public.members m join public.profiles pr on pr.id = m.profile_id
  where pr.auth_user_id = (select auth.uid()) and pr.is_active and pr.deleted_at is null and m.deleted_at is null limit 1;
  if p_member_id is null then
    v_target := v_me;
  else
    select * into v_target from public.members x where x.id = p_member_id and x.deleted_at is null;
  end if;
  if v_target.id is null then
    raise exception 'member not found' using errcode = '22023';
  end if;
  if v_target.id is distinct from v_me.id and not core.has_permission(v_target.org_id, null, 'members.read') then
    raise exception 'you can read only your own rank history' using errcode = '42501';
  end if;
  return query
  select h.id, h.occurred_at, rf.name, rt.name, h.reason, ru.name, ev.name, dv.name,
    h.reverses_id is not null,
    exists (select 1 from public.rank_history y where y.reverses_id = h.id),
    h.revision
  from public.rank_history h
  left join public.ranks rf on rf.id = h.from_rank_id
  join public.ranks rt on rt.id = h.to_rank_id
  left join public.rank_rules ru on ru.id = h.rule_id
  left join public.divisions dv on dv.id = h.division_id
  left join public.events ev on ev.id = h.event_id
  where h.member_id = v_target.id
  order by h.occurred_at desc, h.id desc;
end $$;
create or replace function public.rank_history_view(p_member_id text default null)
returns table (id text, occurred_at timestamptz, from_name text, to_name text, reason text, rule_name text, event_name text,
  division_name text, is_reversal boolean, reversed boolean, revision integer)
language sql stable security invoker set search_path = '' as $$ select * from core.rank_history_view(p_member_id) $$;

revoke all on function core.ranking_list(text), public.ranking_list(text), core.rank_history_view(text), public.rank_history_view(text)
  from public, anon, authenticated;
grant execute on function core.ranking_list(text), public.ranking_list(text), core.rank_history_view(text), public.rank_history_view(text)
  to authenticated, service_role;
