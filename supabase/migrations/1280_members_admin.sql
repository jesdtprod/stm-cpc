-- 1280_members_admin (PLAN 4.5): what the member management screens need from the database.
--   archive_member(member, reason, key)   any member who is not archived becomes archived (members.suspend);
--                                         login access stops at once; status history and audit record it
--   resolve_import_issue(issue, note, key)  marks an import issue as reviewed (members.review_import)
--   members join soft_delete / restore_row (members.update), but only an archived, rejected or never-signed-in member
--   with no open bookings or event registrations can be deleted: an active member is archived first.
-- Archived is a final status in the lifecycle (it has no way back); soft delete only hides the record and can be undone.

create or replace function core.archive_member(p_member_id text, p_reason text, p_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_mem public.members;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_replay jsonb;
  v_response jsonb;
begin
  select * into v_mem from public.members m where m.id = p_member_id and m.deleted_at is null for update;
  if not found then
    raise exception 'member not found' using errcode = '22023';
  end if;
  if not core.has_permission(v_mem.org_id, null, 'members.suspend') then
    raise exception 'you do not have permission to archive members' using errcode = '42501';
  end if;
  if v_reason is null or char_length(v_reason) < 3 then
    raise exception 'a reason is required' using errcode = '22023';
  end if;
  if char_length(v_reason) > 500 then
    raise exception 'the reason is too long' using errcode = '22023';
  end if;

  v_replay := core.idem_begin(p_key, v_mem.org_id, 'member.archive',
    jsonb_build_object('member_id', p_member_id, 'reason', v_reason));
  if v_replay is not null then
    return v_replay;
  end if;
  if v_mem.status = 'archived' then
    v_response := jsonb_build_object('ok', true, 'member_id', v_mem.id, 'status', 'archived', 'unchanged', true);
    perform core.idem_complete(p_key, v_response);
    return v_response;
  end if;

  update public.members set status = 'archived', status_reason = v_reason where id = v_mem.id;
  if v_mem.profile_id is not null then
    update public.org_members set is_active = false where profile_id = v_mem.profile_id and deleted_at is null;
  end if;
  perform core.write_audit(v_mem.org_id, 'member.archive', 'public.members', v_mem.id,
    jsonb_build_object('status', v_mem.status), jsonb_build_object('status', 'archived', 'reason', v_reason));
  v_response := jsonb_build_object('ok', true, 'member_id', v_mem.id, 'status', 'archived');
  perform core.idem_complete(p_key, v_response);
  return v_response;
end $$;

create or replace function core.resolve_import_issue(p_issue_id text, p_note text, p_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_issue public.member_import_issues;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_replay jsonb;
  v_response jsonb;
begin
  select * into v_issue from public.member_import_issues i where i.id = p_issue_id and i.deleted_at is null for update;
  if not found then
    raise exception 'issue not found' using errcode = '22023';
  end if;
  if not core.has_permission(v_issue.org_id, null, 'members.review_import') then
    raise exception 'you do not have permission to review import issues' using errcode = '42501';
  end if;
  if v_note is not null and char_length(v_note) > 500 then
    raise exception 'the note is too long' using errcode = '22023';
  end if;

  v_replay := core.idem_begin(p_key, v_issue.org_id, 'import_issue.resolve',
    jsonb_build_object('issue_id', p_issue_id, 'note', v_note));
  if v_replay is not null then
    return v_replay;
  end if;
  if v_issue.resolved_at is not null then
    v_response := jsonb_build_object('ok', true, 'issue_id', v_issue.id, 'unchanged', true);
    perform core.idem_complete(p_key, v_response);
    return v_response;
  end if;

  update public.member_import_issues
  set resolved_at = now(), resolved_by = coalesce(core.current_profile_id(), 'system'),
      meta = case when v_note is null then meta else jsonb_set(meta, '{resolution_note}', to_jsonb(v_note)) end
  where id = v_issue.id;
  perform core.write_audit(v_issue.org_id, 'import_issue.resolve', 'public.member_import_issues', v_issue.id, null,
    jsonb_build_object('issue_code', v_issue.issue_code, 'source_row', v_issue.source_row, 'note', v_note));
  v_response := jsonb_build_object('ok', true, 'issue_id', v_issue.id);
  perform core.idem_complete(p_key, v_response);
  return v_response;
end $$;

create or replace function public.archive_member(p_member_id text, p_reason text, p_key text) returns jsonb
language sql security invoker set search_path = '' as $$ select core.archive_member(p_member_id, p_reason, p_key) $$;
create or replace function public.resolve_import_issue(p_issue_id text, p_note text, p_key text) returns jsonb
language sql security invoker set search_path = '' as $$ select core.resolve_import_issue(p_issue_id, p_note, p_key) $$;

revoke all on function core.archive_member(text, text, text), core.resolve_import_issue(text, text, text),
  public.archive_member(text, text, text), public.resolve_import_issue(text, text, text) from public, anon, authenticated;
-- The functions check the permission themselves.
grant execute on function core.archive_member(text, text, text), core.resolve_import_issue(text, text, text),
  public.archive_member(text, text, text), public.resolve_import_issue(text, text, text) to authenticated, service_role;

-- Members can be hidden and brought back, with guards.
insert into core.soft_delete_targets (table_name, permission) values ('members', 'members.update')
on conflict (table_name) do nothing;

create or replace function core.tg_members_in_use() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.deleted_at is not null and old.deleted_at is null then
    if new.status in ('pending_approval', 'active', 'suspended') then
      raise exception 'an % member cannot be deleted; archive the member first', replace(new.status, '_', ' ') using errcode = '23503';
    end if;
    if exists (select 1 from public.bookings b where b.requested_by_member_id = new.id
               and b.status in ('pending_approval', 'confirmed', 'checked_in') and upper(b.during) > now())
       or exists (select 1 from public.registrations r join public.events e on e.id = r.event_id
                  where r.member_id = new.id and r.status in ('requested', 'confirmed', 'waitlisted')
                    and e.status not in ('completed', 'cancelled')) then
      raise exception 'the member still has upcoming bookings or event registrations; cancel them first' using errcode = '23503';
    end if;
  end if;
  return new;
end $$;
create trigger c2_members_in_use before update on public.members
  for each row execute function core.tg_members_in_use();
