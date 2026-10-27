-- Optional skill estimate on the existing master members table. Official CPC ranks,
-- rank history, DUPR ratings and event eligibility are unaffected.
alter table public.members
  add column self_assessed_rank_id text collate "C" references public.ranks(id) on delete restrict,
  add column self_assessment_version integer not null default 0 check (self_assessment_version >= 0),
  add column self_assessment_source text check (self_assessment_source in ('member', 'admin')),
  add column self_assessed_at timestamptz,
  add column self_assessed_by text collate "C" references public.profiles(id) on delete restrict,
  add column self_assessment_reason text check (length(self_assessment_reason) <= 500);
alter table public.members add constraint members_self_assessment_state_chk check (
  (self_assessment_version = 0 and self_assessed_rank_id is null and self_assessment_source is null
    and self_assessed_at is null and self_assessed_by is null and self_assessment_reason is null)
  or (self_assessment_version > 0 and self_assessment_source is not null
    and self_assessed_at is not null and self_assessed_by is not null
    and (self_assessment_source <> 'admin' or coalesce(length(btrim(self_assessment_reason)), 0) >= 3))
);
comment on column public.members.self_assessed_rank_id is
  'Optional self-assessment, not an official rank. Own-member and ranks.override RPC writes only; existing members RLS applies.';
create index members_self_assessed_rank_idx on public.members(self_assessed_rank_id) where self_assessed_rank_id is not null;
create index members_self_assessed_by_idx on public.members(self_assessed_by) where self_assessed_by is not null;

create function core.get_member_self_assessment(p_member_id text default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare m public.members; actor text := core.current_profile_id(); own boolean; editable boolean;
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
  editable := case when own then m.status in ('invited', 'pending_approval', 'active') and not exists (
      select 1 from public.member_access a where a.member_id = m.id and a.deleted_at is null and a.must_change_password)
    else core.has_permission(m.org_id, null, 'ranks.override') end;
  return jsonb_build_object(
    'member_id', m.id, 'rank_id', m.self_assessed_rank_id,
    'rank_name', (select r.name from public.ranks r where r.id = m.self_assessed_rank_id),
    'version', m.self_assessment_version, 'source', m.self_assessment_source,
    'updated_at', m.self_assessed_at, 'reason', m.self_assessment_reason,
    'can_edit', coalesce(editable, false), 'admin_edit', not coalesce(own, false),
    'official_rank', (select r.name from public.member_ranks mr join public.ranks r on r.id = mr.rank_id
      where mr.member_id = m.id and mr.deleted_at is null limit 1),
    'options', (select coalesce(jsonb_agg(jsonb_build_object('value', r.id, 'label', r.name, 'category', c.name)
      order by c.sort_order, r.sort_order, r.id), '[]'::jsonb)
      from public.ranks r join public.rank_ladders l on l.id = r.ladder_id
      join public.categories c on c.id = l.category_id
      where r.org_id = m.org_id and l.org_id = m.org_id and c.org_id = m.org_id
        and r.deleted_at is null and l.deleted_at is null and c.deleted_at is null and l.is_active and c.is_active)
  );
end $$;

create function core.set_member_self_assessment(
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

create function public.get_member_self_assessment(p_member_id text default null) returns jsonb
language sql stable security invoker set search_path = '' as $$ select core.get_member_self_assessment(p_member_id) $$;
create function public.set_member_self_assessment(
  p_member_id text, p_rank_id text, p_expected_version integer, p_key text, p_reason text default null
) returns jsonb language sql security invoker set search_path = '' as $$
  select core.set_member_self_assessment(p_member_id, p_rank_id, p_expected_version, p_key, p_reason) $$;
revoke all on function core.get_member_self_assessment(text), public.get_member_self_assessment(text),
  core.set_member_self_assessment(text,text,integer,text,text), public.set_member_self_assessment(text,text,integer,text,text)
  from public, anon, authenticated;
grant execute on function core.get_member_self_assessment(text), public.get_member_self_assessment(text),
  core.set_member_self_assessment(text,text,integer,text,text), public.set_member_self_assessment(text,text,integer,text,text)
  to authenticated, service_role;
