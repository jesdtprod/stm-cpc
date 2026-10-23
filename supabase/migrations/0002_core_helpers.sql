-- 0002_core_helpers (PLAN 1.2)
-- Standard-table helpers: attach_standard, enable_standard_rls and the triggers behind them.
-- Also creates core.audit_log now (PLAN lists it under 1.5) because the audit trigger that
-- attach_standard wires by default needs it to exist before any table gets rows.

-- Fix to 0001: is_ulid(null) must be false, not null.
create or replace function core.is_ulid(value text) returns boolean
language sql immutable parallel safe set search_path = '' as $$
  select coalesce(value ~ '^[0-7][0-9A-HJKMNP-TV-Z]{25}$', false)
$$;

-- Dedicated maintenance role: the only role that may hard-delete (retention purge, DATABASE.md 15).
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'cpc_maintenance') then
    create role cpc_maintenance nologin noinherit;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- audit_log: class log (insert-only for everyone). Internal, no client access.
-- Omits the standard columns on purpose: it is written only by triggers and RPCs.
-- Permission to read it: audit.read, through a later RPC.
-- ---------------------------------------------------------------------------
create table core.audit_log (
  id          text collate "C" primary key default core.ulid()
              constraint audit_log_id_ulid_chk check (core.is_ulid(id)),
  org_id      text,
  actor_id    text,
  action      text not null,
  table_name  text,
  record_id   text,
  old_values  jsonb,
  new_values  jsonb,
  request_id  text,
  occurred_at timestamptz not null default now()
);
comment on table core.audit_log is 'class: log (insert-only). permission: audit.read via RPC. Written by core.tg_audit and core.write_audit.';
create index audit_log_org_occurred_idx on core.audit_log (org_id, occurred_at desc);
create index audit_log_table_record_idx on core.audit_log (table_name, record_id);
alter table core.audit_log enable row level security;
revoke all on core.audit_log from public, anon, authenticated;

create or replace function core.tg_audit_log_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'audit_log is insert-only' using errcode = '42501';
end $$;

create trigger a_no_update before update on core.audit_log
  for each row execute function core.tg_audit_log_guard();
create trigger b_no_delete before delete on core.audit_log
  for each row execute function core.tg_audit_log_guard();
create trigger c_no_truncate before truncate on core.audit_log
  for each statement execute function core.tg_audit_log_guard();

-- ---------------------------------------------------------------------------
-- Caller identity. Stub here, replaced by the real lookup in 0003 once profiles exists.
-- ---------------------------------------------------------------------------
create or replace function core.current_profile_id() returns text
language sql stable set search_path = '' as $$ select null::text $$;

-- Appends one audit row from an RPC or Edge Function (sign-ins, exports, role changes, ...).
create or replace function core.write_audit(
  p_org_id text, p_action text, p_table text, p_record_id text,
  p_old jsonb default null, p_new jsonb default null
) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into core.audit_log (org_id, actor_id, action, table_name, record_id, old_values, new_values, request_id)
  values (
    p_org_id, coalesce(core.current_profile_id(), 'system'), p_action, p_table, p_record_id, p_old, p_new,
    (nullif(current_setting('request.headers', true), '')::jsonb) ->> 'x-request-id'
  );
end $$;

-- ---------------------------------------------------------------------------
-- Trigger functions
-- ---------------------------------------------------------------------------

-- id and created_* never change; org_id / unit_id change only inside a permissioned "move" RPC
-- that sets core.allow_move = 'on' for its transaction.
create or replace function core.tg_immutable() returns trigger
language plpgsql set search_path = '' as $$
declare
  o jsonb := to_jsonb(old);
  n jsonb := to_jsonb(new);
  k text;
begin
  foreach k in array array['id', 'created_at', 'created_by'] loop
    if o -> k is distinct from n -> k then
      raise exception 'column % is immutable', k using errcode = '42501';
    end if;
  end loop;
  foreach k in array array['org_id', 'unit_id'] loop
    if o ? k and o -> k is distinct from n -> k
       and coalesce(current_setting('core.allow_move', true), '') <> 'on' then
      raise exception 'column % cannot change after creation', k using errcode = '42501';
    end if;
  end loop;
  return new;
end $$;

-- Server-stamps created_*, updated_*, version. Client-supplied values are overwritten.
create or replace function core.tg_stamp() returns trigger
language plpgsql set search_path = '' as $$
declare
  actor text := coalesce(core.current_profile_id(), 'system');
begin
  if tg_op = 'INSERT' then
    new.created_at := now();
    new.created_by := actor;
    new.updated_at := now();
    new.updated_by := actor;
    new.version := 1;
  else
    new.updated_at := now();
    new.updated_by := actor;
    new.version := old.version + 1;
  end if;
  return new;
end $$;

-- Master data: deleted rows reject updates (except restore), and deleted_* changes only
-- inside soft_delete/restore RPCs (they set core.rpc = 'on' for their transaction).
create or replace function core.tg_master_rules() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (old.deleted_at, old.deleted_by, old.delete_reason)
       is distinct from (new.deleted_at, new.deleted_by, new.delete_reason) then
    if coalesce(current_setting('core.rpc', true), '') <> 'on' then
      raise exception 'deleted_* columns change only through soft_delete / restore RPCs' using errcode = '42501';
    end if;
    if new.deleted_at is not null and new.deleted_by is null then
      new.deleted_by := coalesce(core.current_profile_id(), 'system');
    end if;
  elsif old.deleted_at is not null then
    raise exception 'a deleted row cannot be updated; restore it first' using errcode = '55000';
  end if;
  return new;
end $$;

create or replace function core.tg_block_delete() returns trigger
language plpgsql set search_path = '' as $$
begin
  if current_user <> 'cpc_maintenance' then
    raise exception 'hard delete is not allowed on %.%', tg_table_schema, tg_table_name using errcode = '42501';
  end if;
  return old;
end $$;

create or replace function core.tg_block_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception '% is append-only: corrections are new reversing rows', tg_table_name using errcode = '42501';
end $$;

create or replace function core.tg_block_truncate() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'truncate is not allowed on %.%', tg_table_schema, tg_table_name using errcode = '42501';
end $$;

-- Writes the audit row. Personal and secret fields are masked. Updates log changed columns only.
create or replace function core.tg_audit() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  o jsonb;
  n jsonb;
  oldv jsonb := '{}'::jsonb;
  newv jsonb := '{}'::jsonb;
  k text;
  act text := lower(tg_op);
  rid text;
  org text;
begin
  if tg_op = 'INSERT' then
    n := to_jsonb(new); newv := n; rid := n ->> 'id'; org := n ->> 'org_id';
  elsif tg_op = 'DELETE' then
    o := to_jsonb(old); oldv := o; rid := o ->> 'id'; org := o ->> 'org_id';
  else
    o := to_jsonb(old); n := to_jsonb(new); rid := n ->> 'id'; org := n ->> 'org_id';
    for k in select jsonb_object_keys(n) loop
      if k in ('updated_at', 'updated_by', 'version') then continue; end if;
      if o -> k is distinct from n -> k then
        oldv := oldv || jsonb_build_object(k, o -> k);
        newv := newv || jsonb_build_object(k, n -> k);
      end if;
    end loop;
    if newv = '{}'::jsonb then return null; end if;
    if o -> 'deleted_at' = 'null'::jsonb and n -> 'deleted_at' <> 'null'::jsonb then act := 'soft_delete';
    elsif o -> 'deleted_at' <> 'null'::jsonb and n -> 'deleted_at' = 'null'::jsonb then act := 'restore';
    end if;
  end if;

  for k in select jsonb_object_keys(oldv) loop
    if k ~* '(password|passwd|token|secret|email|mobile|phone|birth)' then oldv := jsonb_set(oldv, array[k], '"***"'); end if;
  end loop;
  for k in select jsonb_object_keys(newv) loop
    if k ~* '(password|passwd|token|secret|email|mobile|phone|birth)' then newv := jsonb_set(newv, array[k], '"***"'); end if;
  end loop;

  insert into core.audit_log (org_id, actor_id, action, table_name, record_id, old_values, new_values, request_id)
  values (
    org, coalesce(core.current_profile_id(), 'system'), act, tg_table_schema || '.' || tg_table_name, rid,
    nullif(oldv, '{}'::jsonb), nullif(newv, '{}'::jsonb),
    (nullif(current_setting('request.headers', true), '')::jsonb) ->> 'x-request-id'
  );
  return null;
end $$;

-- ---------------------------------------------------------------------------
-- attach_standard(table, kind): kind is master (soft delete), document (status lifecycle)
-- or ledger (append-only). Idempotent.
-- ---------------------------------------------------------------------------
create or replace function core.attach_standard(tbl regclass, kind text default 'master') returns void
language plpgsql set search_path = '' as $$
declare
  rel text;
begin
  if kind not in ('master', 'document', 'ledger') then
    raise exception 'unknown table class %', kind;
  end if;
  select c.relname into rel from pg_class c where c.oid = tbl;

  if not exists (select 1 from pg_constraint where conrelid = tbl and conname = rel || '_id_ulid_chk') then
    execute format('alter table %s add constraint %I check (core.is_ulid(id))', tbl, rel || '_id_ulid_chk');
  end if;

  execute format('drop trigger if exists a_immutable on %s', tbl);
  execute format('drop trigger if exists b_stamp on %s', tbl);
  execute format('drop trigger if exists c_rules on %s', tbl);
  execute format('drop trigger if exists d_no_delete on %s', tbl);
  execute format('drop trigger if exists e_no_truncate on %s', tbl);
  execute format('drop trigger if exists z_audit on %s', tbl);

  if kind = 'ledger' then
    execute format('create trigger b_stamp before insert on %s for each row execute function core.tg_stamp()', tbl);
    execute format('create trigger c_rules before update on %s for each row execute function core.tg_block_update()', tbl);
  else
    execute format('create trigger a_immutable before update on %s for each row execute function core.tg_immutable()', tbl);
    execute format('create trigger b_stamp before insert or update on %s for each row execute function core.tg_stamp()', tbl);
    if kind = 'master' then
      execute format('create trigger c_rules before update on %s for each row execute function core.tg_master_rules()', tbl);
      if not exists (select 1 from pg_constraint where conrelid = tbl and conname = rel || '_deleted_pair_chk') then
        execute format(
          'alter table %s add constraint %I check ((deleted_at is null) = (deleted_by is null))',
          tbl, rel || '_deleted_pair_chk');
      end if;
    end if;
  end if;
  execute format('create trigger d_no_delete before delete on %s for each row execute function core.tg_block_delete()', tbl);
  execute format('create trigger e_no_truncate before truncate on %s for each statement execute function core.tg_block_truncate()', tbl);
  execute format('create trigger z_audit after insert or update or delete on %s for each row execute function core.tg_audit()', tbl);
end $$;

-- ---------------------------------------------------------------------------
-- enable_standard_rls(table, scope, module): RLS plus select/insert/update policies that
-- check permission codes <module>.read / .create / .update. There is no delete policy.
--   org  : rows of the org, for members with an org-wide role
--   unit : rows of the unit (unit_id column), for members of that unit or org-wide
--   own  : rows whose profile_id is the caller, or <module>.read_all
-- ---------------------------------------------------------------------------
create or replace function core.enable_standard_rls(tbl regclass, scope text, module text) returns void
language plpgsql set search_path = '' as $$
declare
  rel text;
  u text;
  sel text;
  ins text;
  upd text;
begin
  if scope not in ('org', 'unit', 'own') then
    raise exception 'unknown RLS scope %', scope;
  end if;
  select c.relname into rel from pg_class c where c.oid = tbl;
  u := case scope when 'org' then 'null' else 'unit_id' end;

  upd := format('core.has_permission(org_id, %s, %L)', u, module || '.update');
  if scope = 'own' then
    sel := format('profile_id = core.current_profile_id() or core.has_permission(org_id, unit_id, %L)', module || '.read_all');
    ins := format('profile_id = core.current_profile_id() and core.has_permission(org_id, unit_id, %L)', module || '.create');
  else
    sel := format('core.has_permission(org_id, %s, %L)', u, module || '.read');
    ins := format('core.has_permission(org_id, %s, %L)', u, module || '.create');
  end if;

  execute format('alter table %s enable row level security', tbl);
  execute format('drop policy if exists %I on %s', rel || '_select', tbl);
  execute format('drop policy if exists %I on %s', rel || '_insert', tbl);
  execute format('drop policy if exists %I on %s', rel || '_update', tbl);
  execute format('create policy %I on %s for select to authenticated using (%s)', rel || '_select', tbl, sel);
  execute format('create policy %I on %s for insert to authenticated with check (%s)', rel || '_insert', tbl, ins);
  execute format('create policy %I on %s for update to authenticated using (%s) with check (%s)', rel || '_update', tbl, upd, upd);
end $$;

-- Helpers are for migrations and service code only.
revoke all on function core.write_audit(text, text, text, text, jsonb, jsonb) from public, anon, authenticated;
revoke all on function core.attach_standard(regclass, text) from public, anon, authenticated;
revoke all on function core.enable_standard_rls(regclass, text, text) from public, anon, authenticated;
revoke all on function core.current_profile_id() from public, anon;
grant execute on function core.current_profile_id() to authenticated, service_role;
revoke all on function core.is_ulid(text) from public, anon;
grant execute on function core.is_ulid(text) to authenticated, service_role;
