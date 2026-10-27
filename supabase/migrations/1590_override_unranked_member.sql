-- Fix: an administrator override on a member with no rank yet created no member_ranks row.
-- core.override_member_rank (1510) tested FOUND after inserting the rank_history row, so FOUND came from that insert
-- (always true) and the function updated a row that did not exist. The rank was recorded in the history only.
-- The lookup result is now kept in a variable. Members already affected keep their history row; setting the rank again
-- from the member profile creates the missing current rank.

create or replace function core.override_member_rank(p_member_id text, p_rank_id text, p_reason text, p_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  m public.members;
  v_cur public.member_ranks;
  v_had boolean;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_replay jsonb;
  v_response jsonb;
begin
  select * into m from public.members x where x.id = p_member_id and x.deleted_at is null;
  if not found then
    raise exception 'member not found' using errcode = '22023';
  end if;
  if not core.has_permission(m.org_id, null, 'ranks.override') then
    raise exception 'you do not have permission to override a rank' using errcode = '42501';
  end if;
  if m.profile_id is not null and m.profile_id = core.current_profile_id() then
    raise exception 'you cannot change your own rank' using errcode = '42501';
  end if;
  if v_reason is null or char_length(v_reason) < 3 or char_length(v_reason) > 500 then
    raise exception 'a reason of 3 to 500 characters is required' using errcode = '22023';
  end if;
  v_replay := core.idem_begin(p_key, m.org_id, 'rank.override', jsonb_build_object('member', p_member_id, 'rank', p_rank_id, 'reason', v_reason));
  if v_replay is not null then
    return v_replay;
  end if;
  if not exists (select 1 from core.rank_chain(m.org_id) c where c.rank_id = p_rank_id) then
    raise exception 'choose a rank from the club''s ladders' using errcode = '22023';
  end if;
  select * into v_cur from public.member_ranks mr where mr.member_id = m.id and mr.deleted_at is null for update;
  v_had := found;
  if v_had and v_cur.rank_id = p_rank_id then
    raise exception 'the member is already at that rank' using errcode = '22023';
  end if;
  insert into public.rank_history (org_id, member_id, from_rank_id, to_rank_id, reason)
  values (m.org_id, m.id, case when v_had then v_cur.rank_id end, p_rank_id, 'Override: ' || v_reason);
  if v_had then
    update public.member_ranks set rank_id = p_rank_id, set_by_rule_id = null, source_division_id = null where id = v_cur.id;
  else
    insert into public.member_ranks (org_id, member_id, rank_id) values (m.org_id, m.id, p_rank_id);
  end if;
  perform core.write_audit(m.org_id, 'rank.override', 'public.member_ranks', m.id,
    jsonb_build_object('rank_id', case when v_had then v_cur.rank_id end), jsonb_build_object('rank_id', p_rank_id, 'reason', v_reason));
  v_response := jsonb_build_object('member_id', m.id, 'rank_id', p_rank_id);
  perform core.idem_complete(p_key, v_response);
  return v_response;
end $$;
revoke all on function core.override_member_rank(text, text, text, text) from public, anon, authenticated;
grant execute on function core.override_member_rank(text, text, text, text) to authenticated, service_role;
