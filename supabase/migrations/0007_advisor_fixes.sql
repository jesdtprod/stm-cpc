-- 0007_advisor_fixes (PLAN 1.7)
-- Resolves the Supabase Security and Performance Advisor findings on 0001-0006.

-- 1. SECURITY DEFINER function reachable through /rest/v1/rpc (lint 0029).
--    The privileged lookup moves to core (not exposed); the public RPC is a SECURITY INVOKER wrapper.
create or replace function core.my_permissions() returns table (org_id text, unit_id text, code text)
language sql stable security definer set search_path = '' as $$
  select m.org_id, m.unit_id, pe.code
  from public.profiles p
  join public.org_members m on m.profile_id = p.id
  join public.roles r on r.id = m.role_id
  join public.role_permissions rp on rp.role_id = r.id
  join public.permissions pe on pe.id = rp.permission_id
  where p.auth_user_id = (select auth.uid())
    and p.is_active and p.deleted_at is null
    and m.is_active and m.deleted_at is null
    and r.deleted_at is null and rp.deleted_at is null and pe.deleted_at is null
$$;
revoke all on function core.my_permissions() from public, anon;
grant execute on function core.my_permissions() to authenticated, service_role;

create or replace function public.my_permissions() returns table (org_id text, unit_id text, code text)
language sql stable security invoker set search_path = '' as $$
  select * from core.my_permissions()
$$;

-- 2. Two permissive SELECT policies on persons -> one (lint 0006).
--    Note: core.enable_standard_rls('public.persons', ...) would recreate the standard one; do not re-run it.
drop policy persons_select on public.persons;
drop policy persons_select_own on public.persons;
create policy persons_select on public.persons for select to authenticated
  using (core.has_permission(org_id, null, 'members.read') or core.is_own_person(id));

-- 3. Foreign keys without a covering index (lint 0001). The composite foreign keys need
--    composite indexes; they make the single-column ones redundant.
drop index public.org_members_role_idx;
drop index public.org_members_unit_idx;
drop index public.role_permissions_role_idx;
drop index public.settings_unit_idx;
create index org_members_role_org_idx on public.org_members (role_id, org_id);
create index org_members_unit_org_idx on public.org_members (unit_id, org_id) where unit_id is not null;
create index role_permissions_role_org_idx on public.role_permissions (role_id, org_id);
create index settings_unit_org_idx on public.settings (unit_id, org_id) where unit_id is not null;

-- 4. Internal tables: say explicitly that no client role may reach them (lint 0008).
create policy deny_clients on core.audit_log for all to anon, authenticated using (false);
create policy deny_clients on core.idempotency_keys for all to anon, authenticated using (false);
create policy deny_clients on core.counters for all to anon, authenticated using (false);
