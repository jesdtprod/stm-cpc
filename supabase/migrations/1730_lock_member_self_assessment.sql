-- 1730: One member submission; later corrections require ranks.override.
-- Existing official club ranks serve as read-only assessments when no estimate was saved.
-- No backfill changes official ranks or stored estimates. Completed retries still replay.
create or replace function core.get_member_self_assessment(p_member_id text default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare m public.members; actor text := core.current_profile_id(); own boolean; editable boolean;
  official record; locked boolean; selected_rank text;
begin
  select * into m from public.members x where x.deleted_at is null
    and ((p_member_id is null and x.profile_id = actor) or x.id = p_member_id);
  if actor is null or not found then
    raise exception 'self-assessment is not available' using errcode = '42501';
  end if;
  own := m.profile_id = actor;
  if not coalesce(own, false) and not core.has_permission(m.org_id, null, 'members.read') then
    raise exception 'self-assessment is not available' using errcode = '42501';
  end if;
  select mr.rank_id, r.name, mr.updated_at into official
    from public.member_ranks mr join public.ranks r on r.id = mr.rank_id
    where mr.member_id = m.id and mr.deleted_at is null limit 1;
  locked := m.self_assessment_version > 0 or official.rank_id is not null;
  selected_rank := case when m.self_assessment_version = 0 then official.rank_id else m.self_assessed_rank_id end;
  editable := case when own then not locked and m.status in ('invited', 'pending_approval', 'active') and not exists (
      select 1 from public.member_access a where a.member_id = m.id and a.deleted_at is null and a.must_change_password)
    else core.has_permission(m.org_id, null, 'ranks.override') end;
  return jsonb_build_object(
    'member_id', m.id, 'rank_id', selected_rank,
    'rank_name', (select r.name from public.ranks r where r.id = selected_rank),
    'version', m.self_assessment_version,
    'source', case when m.self_assessment_version = 0 and official.rank_id is not null then 'club' else m.self_assessment_source end,
    'origin', case when m.self_assessment_version > 0 then 'assessment' when official.rank_id is not null then 'club_rank' else 'none' end,
    'locked', locked,
    'updated_at', case when m.self_assessment_version = 0 then official.updated_at else m.self_assessed_at end, 'reason', m.self_assessment_reason,
    'can_edit', coalesce(editable, false), 'admin_edit', not coalesce(own, false),
    'official_rank', official.name, 'official_rank_id', official.rank_id,
    'options', (select coalesce(jsonb_agg(jsonb_build_object('value', r.id, 'label', r.name, 'category', c.name)
      order by c.sort_order, r.sort_order, r.id), '[]'::jsonb)
      from public.ranks r join public.rank_ladders l on l.id = r.ladder_id
      join public.categories c on c.id = l.category_id
      where r.org_id = m.org_id and l.org_id = m.org_id and c.org_id = m.org_id
        and r.deleted_at is null and l.deleted_at is null and c.deleted_at is null and l.is_active and c.is_active)
  );
end $$;

create or replace function core.set_member_self_assessment(
  p_member_id text, p_rank_id text, p_expected_version integer, p_key text, p_reason text default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare m public.members; actor text := core.current_profile_id(); own boolean;
  reason text := nullif(btrim(p_reason), ''); replay jsonb; response jsonb;
begin
  select * into m from public.members x where x.id = p_member_id and x.deleted_at is null for update;
  if actor is null or not found then
    raise exception 'self-assessment is not available' using errcode = '42501';
  end if;
  own := coalesce(m.profile_id = actor, false);
  if own then
    if m.status not in ('invited', 'pending_approval', 'active') or exists (
      select 1 from public.member_access a where a.member_id = m.id and a.deleted_at is null and a.must_change_password) then
      raise exception 'your account cannot change its self-assessment' using errcode = '42501';
    end if;
  elsif not core.has_permission(m.org_id, null, 'ranks.override') then
    raise exception 'not allowed to adjust another member''s self-assessment' using errcode = '42501';
  end if;
  if not own and coalesce(length(reason), 0) < 3 then
    raise exception 'give a reason for this correction' using errcode = '22023';
  end if;
  if length(reason) > 500 then raise exception 'reason is too long' using errcode = '22023'; end if;
  replay := core.idem_begin(p_key, m.org_id, 'members.self_assessment',
    jsonb_build_object('member', m.id, 'rank', p_rank_id, 'version', p_expected_version, 'reason', reason));
  if replay is not null then return replay; end if;
  if p_expected_version is null or p_expected_version <> m.self_assessment_version then
    raise exception 'self-assessment changed; reload it before saving' using errcode = 'CP409';
  end if;
  if own and (m.self_assessment_version > 0 or exists (
    select 1 from public.member_ranks mr where mr.member_id = m.id and mr.deleted_at is null
  )) then
    raise exception 'your assessment is locked; ask an admin to update it' using errcode = '42501';
  end if;
  if own and p_rank_id is null then
    raise exception 'choose a rank before submitting your assessment' using errcode = '22023';
  end if;
  if p_rank_id is not null then
    perform r.id from public.ranks r join public.rank_ladders l on l.id = r.ladder_id
      join public.categories c on c.id = l.category_id
      where r.id = p_rank_id and r.org_id = m.org_id and l.org_id = m.org_id and c.org_id = m.org_id
        and r.deleted_at is null and l.deleted_at is null and c.deleted_at is null and l.is_active and c.is_active
      for share of r, l, c;
    if not found then raise exception 'choose an available rank' using errcode = '22023'; end if;
  end if;
  update public.members set self_assessed_rank_id = p_rank_id,
    self_assessment_version = self_assessment_version + 1,
    self_assessment_source = case when own then 'member' else 'admin' end,
    self_assessed_at = now(), self_assessed_by = actor, self_assessment_reason = reason
    where id = m.id;
  perform core.write_audit(m.org_id, 'member.self_assessment', 'public.members', m.id,
    jsonb_build_object('rank_id', m.self_assessed_rank_id, 'version', m.self_assessment_version),
    jsonb_build_object('rank_id', p_rank_id, 'source', case when own then 'member' else 'admin' end, 'reason', reason));
  response := jsonb_build_object('ok', true, 'member_id', m.id, 'version', m.self_assessment_version + 1);
  perform core.idem_complete(p_key, response);
  return response;
end $$;


-- Preserve the existing private core / authenticated wrapper access.
revoke all on function core.get_member_self_assessment(text),
  core.set_member_self_assessment(text,text,integer,text,text) from public, anon, authenticated;
grant execute on function core.get_member_self_assessment(text),
  core.set_member_self_assessment(text,text,integer,text,text) to authenticated, service_role;
NOTIFY pgrst, 'reload schema';
