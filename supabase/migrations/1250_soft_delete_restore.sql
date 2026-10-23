-- 1250_soft_delete_restore (PLAN 4.2): the soft-delete and restore functions the master-data triggers expect
-- (0002 says deleted_* columns change only inside them). One pair serves every master table that is listed in
-- core.soft_delete_targets together with the permission it needs; later steps add their tables to that list.
--   soft_delete(table, id, reason, key)   reason required (3 to 500 characters); the table's own "still in use" guard
--                                         refuses a row that other records depend on; a second call changes nothing
--   restore_row(table, id, key)           brings the row back; a clash with a live row of the same code is refused
-- Both check the permission against the row's own club, take an idempotency key, and are audited by the table trigger.

create table core.soft_delete_targets (
  table_name text primary key check (table_name ~ '^[a-z_]+$'),
  permission text not null
);
comment on table core.soft_delete_targets is 'class: master (internal). Tables whose rows soft_delete / restore_row may act on, with the permission each needs.';
alter table core.soft_delete_targets enable row level security;
revoke all on core.soft_delete_targets from public, anon, authenticated;

insert into core.soft_delete_targets (table_name, permission) values
  ('categories', 'categories.manage'),
  ('rank_ladders', 'ranks.manage'),
  ('ranks', 'ranks.manage'),
  ('rank_rules', 'ranks.manage');

create or replace function core.soft_delete(p_table text, p_id text, p_reason text, p_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_perm text;
  v_org text;
  v_deleted timestamptz;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_replay jsonb;
  v_response jsonb;
begin
  select t.permission into v_perm from core.soft_delete_targets t where t.table_name = p_table;
  if v_perm is null then
    raise exception 'this kind of record cannot be deleted here' using errcode = '22023';
  end if;
  execute format('select org_id, deleted_at from public.%I where id = $1 for update', p_table)
    into v_org, v_deleted using p_id;
  if v_org is null then
    raise exception 'record not found' using errcode = '22023';
  end if;
  if not core.has_permission(v_org, null, v_perm) then
    raise exception 'you do not have permission to delete this' using errcode = '42501';
  end if;
  if v_reason is null or char_length(v_reason) < 3 then
    raise exception 'a reason is required' using errcode = '22023';
  end if;
  if char_length(v_reason) > 500 then
    raise exception 'the reason is too long' using errcode = '22023';
  end if;

  v_replay := core.idem_begin(p_key, v_org, 'soft_delete.' || p_table,
    jsonb_build_object('id', p_id, 'reason', v_reason));
  if v_replay is not null then
    return v_replay;
  end if;
  if v_deleted is not null then
    v_response := jsonb_build_object('ok', true, 'id', p_id, 'unchanged', true);
    perform core.idem_complete(p_key, v_response);
    return v_response;
  end if;

  perform set_config('core.rpc', 'on', true);
  execute format('update public.%I set deleted_at = now(), delete_reason = $2 where id = $1', p_table)
    using p_id, v_reason;
  perform set_config('core.rpc', 'off', true);
  v_response := jsonb_build_object('ok', true, 'id', p_id);
  perform core.idem_complete(p_key, v_response);
  return v_response;
end $$;

create or replace function core.restore_row(p_table text, p_id text, p_key text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_perm text;
  v_org text;
  v_deleted timestamptz;
  v_replay jsonb;
  v_response jsonb;
begin
  select t.permission into v_perm from core.soft_delete_targets t where t.table_name = p_table;
  if v_perm is null then
    raise exception 'this kind of record cannot be restored here' using errcode = '22023';
  end if;
  execute format('select org_id, deleted_at from public.%I where id = $1 for update', p_table)
    into v_org, v_deleted using p_id;
  if v_org is null then
    raise exception 'record not found' using errcode = '22023';
  end if;
  if not core.has_permission(v_org, null, v_perm) then
    raise exception 'you do not have permission to restore this' using errcode = '42501';
  end if;

  v_replay := core.idem_begin(p_key, v_org, 'restore.' || p_table, jsonb_build_object('id', p_id));
  if v_replay is not null then
    return v_replay;
  end if;
  if v_deleted is null then
    v_response := jsonb_build_object('ok', true, 'id', p_id, 'unchanged', true);
    perform core.idem_complete(p_key, v_response);
    return v_response;
  end if;

  perform set_config('core.rpc', 'on', true);
  begin
    execute format('update public.%I set deleted_at = null, deleted_by = null, delete_reason = null where id = $1', p_table)
      using p_id;
  exception when unique_violation then
    perform set_config('core.rpc', 'off', true);
    raise exception 'another active record already uses the same code or name; rename that one first' using errcode = '23505';
  end;
  perform set_config('core.rpc', 'off', true);
  v_response := jsonb_build_object('ok', true, 'id', p_id);
  perform core.idem_complete(p_key, v_response);
  return v_response;
end $$;

create or replace function public.soft_delete(p_table text, p_id text, p_reason text, p_key text) returns jsonb
language sql security invoker set search_path = '' as $$ select core.soft_delete(p_table, p_id, p_reason, p_key) $$;
create or replace function public.restore_row(p_table text, p_id text, p_key text) returns jsonb
language sql security invoker set search_path = '' as $$ select core.restore_row(p_table, p_id, p_key) $$;

revoke all on function core.soft_delete(text, text, text, text), core.restore_row(text, text, text),
  public.soft_delete(text, text, text, text), public.restore_row(text, text, text) from public, anon, authenticated;
-- The functions check the permission themselves.
grant execute on function core.soft_delete(text, text, text, text), core.restore_row(text, text, text),
  public.soft_delete(text, text, text, text), public.restore_row(text, text, text) to authenticated, service_role;
