-- 1200_member_approval (PLAN 3.5)
-- The approval flow as one permissioned, idempotent, audited function: decide_member(action, member, reason, key, ...).
--   approve    pending_approval -> active      (members.approve)  gives the member role, optional starting rank
--   reject     pending_approval -> rejected    (members.approve)  reason required
--   reconsider rejected -> pending_approval    (members.approve)  reason required
--   suspend    active -> suspended             (members.suspend)  reason required; permissions stop at once
--   restore    suspended -> active             (members.suspend)  reason required
-- The caller sends a ULID idempotency key: the same key and request replays the first answer, the same key with a
-- different request is refused. A request that finds the member already in the wanted state changes nothing.
-- Every decision is in audit_log and (through the members trigger) in member_status_events.

-- Rejected applicants can be reconsidered (FEATURES 4.3).
create or replace function core.tg_members_status() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if new.status not in ('imported', 'pending_approval') then
      raise exception 'a new member starts as imported or pending_approval, not %', new.status using errcode = '22023';
    end if;
    return new;
  end if;
  if new.status = old.status then return new; end if;
  if not (
    (old.status = 'imported' and new.status = 'invited')
    or (old.status = 'invited' and new.status = 'pending_approval')
    or (old.status = 'pending_approval' and new.status in ('active', 'rejected'))
    or (old.status = 'rejected' and new.status = 'pending_approval')
    or (old.status = 'active' and new.status = 'suspended')
    or (old.status = 'suspended' and new.status = 'active')
    or (old.status <> 'archived' and new.status = 'archived')
  ) then
    raise exception 'member status cannot change from % to %', old.status, new.status using errcode = '22023';
  end if;
  return new;
end $$;

create or replace function core.decide_member(
  p_action text, p_member_id text, p_reason text, p_key text,
  p_acknowledge_flags boolean default false, p_rank_id text default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  mem public.members;
  reason text := nullif(btrim(coalesce(p_reason, '')), '');
  needed text;
  target text;
  expected_from text;
  replay jsonb;
  response jsonb;
  open_flags integer;
  member_role text;
  pending_role text;
  rk public.ranks;
  old_rank text;
begin
  if p_action not in ('approve', 'reject', 'reconsider', 'suspend', 'restore') then
    raise exception 'unknown action' using errcode = '22023';
  end if;
  select * into mem from public.members where id = p_member_id and deleted_at is null for update;
  if not found then
    raise exception 'member not found' using errcode = '22023';
  end if;
  needed := case when p_action in ('suspend', 'restore') then 'members.suspend' else 'members.approve' end;
  if not core.has_permission(mem.org_id, null, needed) then
    raise exception 'you do not have permission to % members', p_action using errcode = '42501';
  end if;
  if p_action <> 'approve' and (reason is null or length(reason) < 3) then
    raise exception 'a reason is required' using errcode = '22023';
  end if;
  if reason is not null and length(reason) > 500 then
    raise exception 'the reason is too long' using errcode = '22023';
  end if;

  replay := core.idem_begin(p_key, mem.org_id, 'member.' || p_action,
    jsonb_build_object('member_id', p_member_id, 'reason', reason, 'ack', coalesce(p_acknowledge_flags, false), 'rank', p_rank_id));
  if replay is not null then
    return replay;
  end if;

  target := case p_action when 'approve' then 'active' when 'reject' then 'rejected' when 'reconsider' then 'pending_approval'
                          when 'suspend' then 'suspended' else 'active' end;
  -- Already where the request wants it: nothing to do (a second approval, for example).
  if mem.status = target then
    response := jsonb_build_object('ok', true, 'member_id', mem.id, 'status', mem.status, 'unchanged', true);
    perform core.idem_complete(p_key, response);
    return response;
  end if;

  if p_action = 'approve' then
    if mem.status <> 'pending_approval' then
      raise exception 'only a member waiting for approval can be approved' using errcode = '22023';
    end if;
    select count(*)::integer into open_flags from public.member_review_flags f
    where f.member_id = mem.id and f.resolved_at is null and f.deleted_at is null;
    if open_flags > 0 and not coalesce(p_acknowledge_flags, false) then
      raise exception 'this application has % open review flag(s); review them and approve again to confirm', open_flags using errcode = '22023';
    end if;
    update public.member_review_flags set resolved_at = now(), resolved_by = coalesce(core.current_profile_id(), 'system')
    where member_id = mem.id and resolved_at is null and deleted_at is null;
    if p_rank_id is not null then
      select r.* into rk from public.ranks r join public.rank_ladders l on l.id = r.ladder_id
      where r.id = p_rank_id and r.org_id = mem.org_id and r.deleted_at is null and l.deleted_at is null;
      if not found then
          raise exception 'the starting rank does not exist' using errcode = '22023';
      end if;
    end if;
  else
    expected_from := case p_action when 'reject' then 'pending_approval' when 'reconsider' then 'rejected'
                                   when 'suspend' then 'active' else 'suspended' end;
    if mem.status <> expected_from then
      raise exception 'cannot % a member who is %', p_action, mem.status using errcode = '22023';
    end if;
  end if;

  update public.members set status = target,
    status_reason = case p_action when 'approve' then coalesce(reason, 'approved') else reason end
  where id = mem.id;

  -- Access follows the decision.
  if mem.profile_id is not null then
    if p_action = 'approve' then
      select r.id into member_role from public.roles r where r.org_id = mem.org_id and r.code = 'member' and r.deleted_at is null;
      select r.id into pending_role from public.roles r where r.org_id = mem.org_id and r.code = 'pending_member' and r.deleted_at is null;
      update public.org_members set role_id = member_role, is_active = true
      where profile_id = mem.profile_id and role_id = pending_role and deleted_at is null;
    elsif p_action = 'suspend' then
      update public.org_members set is_active = false where profile_id = mem.profile_id and deleted_at is null;
    elsif p_action = 'restore' then
      update public.org_members set is_active = true where profile_id = mem.profile_id and deleted_at is null;
    end if;
  end if;

  -- An optional starting rank, recorded in the rank history.
  if p_action = 'approve' and rk.id is not null then
    select mr.rank_id into old_rank from public.member_ranks mr where mr.member_id = mem.id and mr.deleted_at is null;
    if old_rank is null then
      insert into public.member_ranks (org_id, member_id, rank_id) values (mem.org_id, mem.id, rk.id);
      insert into public.rank_history (org_id, member_id, to_rank_id, reason) values (mem.org_id, mem.id, rk.id, 'starting rank at approval');
    end if;
  end if;

  perform core.write_audit(mem.org_id, 'member.' || p_action, 'public.members', mem.id,
    jsonb_build_object('status', mem.status), jsonb_build_object('status', target, 'reason', reason));
  response := jsonb_build_object('ok', true, 'member_id', mem.id, 'status', target);
  perform core.idem_complete(p_key, response);
  return response;
end $$;

create or replace function public.decide_member(
  p_action text, p_member_id text, p_reason text, p_key text,
  p_acknowledge_flags boolean default false, p_rank_id text default null
) returns jsonb
language sql security invoker set search_path = '' as $$
  select core.decide_member(p_action, p_member_id, p_reason, p_key, p_acknowledge_flags, p_rank_id)
$$;

revoke all on function core.decide_member(text, text, text, text, boolean, text), public.decide_member(text, text, text, text, boolean, text)
  from public, anon, authenticated;
-- Members with the right permission call it through the API; the function checks the permission itself.
grant execute on function core.decide_member(text, text, text, text, boolean, text), public.decide_member(text, text, text, text, boolean, text)
  to authenticated, service_role;
