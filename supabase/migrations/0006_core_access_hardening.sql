-- 0006_core_access_hardening (PLAN 1.6)
-- Revoke Supabase's default grants, then grant explicitly. After this migration:
--   * anon has no privilege on any table or function in public or core.
--   * authenticated can SELECT public tables (RLS filters rows), and INSERT/UPDATE only on the
--     tables that have policies for it, and only on columns the client may write.
--   * nobody but cpc_maintenance can delete, and nobody can truncate.
--   * new tables and functions are private by default.

-- New objects created by postgres start with no access for anon / authenticated / PUBLIC.
alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public revoke execute on functions from anon, authenticated;
alter default privileges for role postgres revoke execute on functions from public;

-- Existing objects.
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;
revoke all on all functions in schema core from public, anon, authenticated;

-- Functions that policies, defaults, constraints and the UI call as the signed-in user.
grant execute on function
  core.ulid(), core.is_ulid(text), core.ulid_time(text),
  core.current_profile_id(), core.has_permission(text, text, text),
  core.is_org_member(text), core.is_own_person(text), core.setting_valid(text, jsonb)
  to authenticated, service_role;
grant execute on function public.my_permissions() to authenticated;

-- Grants a client role only the columns it may write. The server stamps created_*, updated_*,
-- version and deleted_*; id, org_id and unit_id never change after insert (move RPCs only).
create or replace function core.grant_client_dml(tbl regclass, p_insert boolean, p_update boolean) returns void
language plpgsql set search_path = '' as $$
declare
  ins_cols text;
  upd_cols text;
begin
  execute format('revoke all on %s from anon, authenticated', tbl);
  execute format('grant select on %s to authenticated', tbl);
  select string_agg(quote_ident(a.attname), ', ' order by a.attnum) into ins_cols
  from pg_attribute a
  where a.attrelid = tbl and a.attnum > 0 and not a.attisdropped
    and a.attname <> all (array['created_at', 'created_by', 'updated_at', 'updated_by', 'version', 'deleted_at', 'deleted_by', 'delete_reason']);
  select string_agg(quote_ident(a.attname), ', ' order by a.attnum) into upd_cols
  from pg_attribute a
  where a.attrelid = tbl and a.attnum > 0 and not a.attisdropped
    and a.attname <> all (array['id', 'org_id', 'unit_id', 'created_at', 'created_by', 'updated_at', 'updated_by', 'version', 'deleted_at', 'deleted_by', 'delete_reason']);
  if p_insert then execute format('grant insert (%s) on %s to authenticated', ins_cols, tbl); end if;
  if p_update then execute format('grant update (%s) on %s to authenticated', upd_cols, tbl); end if;
end $$;
revoke all on function core.grant_client_dml(regclass, boolean, boolean) from public, anon, authenticated;

-- Read-only for clients (security tables and service-written tables): select only.
select core.grant_client_dml('public.orgs', false, false);
select core.grant_client_dml('public.profiles', false, false);
select core.grant_client_dml('public.permissions', false, false);
select core.grant_client_dml('public.roles', false, false);
select core.grant_client_dml('public.role_permissions', false, false);
select core.grant_client_dml('public.org_members', false, false);
select core.grant_client_dml('public.notifications', false, false);
-- Tables with insert and update policies.
select core.grant_client_dml('public.org_units', true, true);
select core.grant_client_dml('public.persons', true, true);
select core.grant_client_dml('public.person_relations', true, true);
select core.grant_client_dml('public.settings', true, true);
select core.grant_client_dml('public.lookups', true, true);
-- Insert-only.
select core.grant_client_dml('public.files', true, false);
select core.grant_client_dml('public.client_errors', true, false);

-- service_role (Edge Functions) keeps table access; RLS is bypassed by the role, the triggers still apply.
grant select, insert, update on all tables in schema public to service_role;
grant usage on all sequences in schema public to service_role;
