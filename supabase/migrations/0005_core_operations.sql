-- 0005_core_operations (PLAN 1.5)
-- idempotency_keys, counters (internal, schema core); settings, lookups, files,
-- notifications, client_errors (schema public, RLS). audit_log already exists (0002).

-- ---------------------------------------------------------------------------
-- idempotency_keys: layer 2 of DATABASE.md section 7. class: internal. No client access.
-- ---------------------------------------------------------------------------
create table core.idempotency_keys (
  id           text collate "C" primary key constraint idempotency_keys_id_ulid_chk check (core.is_ulid(id)),
  org_id       text,
  actor_id     text not null,
  scope        text not null,
  request_hash text not null,
  status       text not null constraint idempotency_keys_status_chk check (status in ('in_progress', 'completed', 'failed')),
  response     jsonb,
  created_at   timestamptz not null default now(),
  completed_at timestamptz,
  expires_at   timestamptz not null default now() + interval '30 days',
  constraint idempotency_keys_actor_scope_id_uq unique (actor_id, scope, id)
);
comment on table core.idempotency_keys is 'class: internal. Written only through core.idem_* helpers inside RPCs.';
create index idempotency_keys_expires_idx on core.idempotency_keys (expires_at);
alter table core.idempotency_keys enable row level security;
revoke all on core.idempotency_keys from public, anon, authenticated;

-- Start an operation. Returns NULL when the caller should do the work, or the stored response
-- when this key already completed with the same request (a replay).
-- Errors: 22023 bad key, CP422 key reused with a different request, CP409 still in progress.
create or replace function core.idem_begin(p_key text, p_org_id text, p_scope text, p_request jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  actor text := coalesce(core.current_profile_id(), 'system');
  h text := encode(extensions.digest(convert_to(coalesce(p_request, 'null'::jsonb)::text, 'utf8'), 'sha256'), 'hex');
  r core.idempotency_keys;
begin
  if not core.is_ulid(p_key) then
    raise exception 'invalid idempotency key' using errcode = '22023';
  end if;
  insert into core.idempotency_keys (id, org_id, actor_id, scope, request_hash, status)
  values (p_key, p_org_id, actor, p_scope, h, 'in_progress')
  on conflict (id) do nothing;
  if found then
    return null;
  end if;

  select * into r from core.idempotency_keys where id = p_key for update;
  if r.actor_id <> actor or r.scope <> p_scope or r.request_hash <> h then
    raise exception 'idempotency key reused with a different request' using errcode = 'CP422';
  end if;
  if r.expires_at < now() or r.status = 'failed' then
    update core.idempotency_keys
       set status = 'in_progress', response = null, completed_at = null, expires_at = now() + interval '30 days'
     where id = p_key;
    return null;
  end if;
  if r.status = 'completed' then
    return coalesce(r.response, 'null'::jsonb);
  end if;
  raise exception 'request is still in progress, retry later' using errcode = 'CP409';
end $$;

create or replace function core.idem_complete(p_key text, p_response jsonb) returns void
language sql security definer set search_path = '' as $$
  update core.idempotency_keys
     set status = 'completed', response = coalesce(p_response, 'null'::jsonb), completed_at = now()
   where id = p_key
$$;

create or replace function core.idem_fail(p_key text) returns void
language sql security definer set search_path = '' as $$
  update core.idempotency_keys set status = 'failed', completed_at = now() where id = p_key
$$;

-- Scheduled cleanup (schedule with pg_cron or an Edge Function once one is enabled).
create or replace function core.purge_expired_idempotency_keys() returns integer
language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  delete from core.idempotency_keys where expires_at < now();
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------------------
-- counters: per org / unit / series number sequence. class: internal.
-- ---------------------------------------------------------------------------
create table core.counters (
  id            text collate "C" primary key default core.ulid() constraint counters_id_ulid_chk check (core.is_ulid(id)),
  org_id        text not null,
  unit_id       text,
  series        text not null,
  current_value bigint not null default 0 constraint counters_value_chk check (current_value >= 0),
  updated_at    timestamptz not null default now()
);
comment on table core.counters is 'class: internal. Incremented under row lock by core.next_number.';
create unique index counters_series_uq on core.counters (org_id, coalesce(unit_id, ''), series);
alter table core.counters enable row level security;
revoke all on core.counters from public, anon, authenticated;

-- Next number of a series. The upsert takes the row lock, so concurrent callers never get the
-- same value. Uniqueness is promised, gapless sequences are not.
create or replace function core.next_number(p_org_id text, p_unit_id text, p_series text) returns bigint
language plpgsql security definer set search_path = '' as $$
declare v bigint;
begin
  insert into core.counters (org_id, unit_id, series, current_value)
  values (p_org_id, p_unit_id, p_series, 1)
  on conflict (org_id, (coalesce(unit_id, '')), series)
  do update set current_value = core.counters.current_value + 1, updated_at = now()
  returning current_value into v;
  return v;
end $$;

revoke all on function core.idem_begin(text, text, text, jsonb) from public, anon, authenticated;
revoke all on function core.idem_complete(text, jsonb) from public, anon, authenticated;
revoke all on function core.idem_fail(text) from public, anon, authenticated;
revoke all on function core.purge_expired_idempotency_keys() from public, anon, authenticated;
revoke all on function core.next_number(text, text, text) from public, anon, authenticated;
grant execute on function core.idem_begin(text, text, text, jsonb) to service_role;
grant execute on function core.idem_complete(text, jsonb) to service_role;
grant execute on function core.idem_fail(text) to service_role;
grant execute on function core.purge_expired_idempotency_keys() to service_role;
grant execute on function core.next_number(text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- settings: scoped key/value (org or unit). class: master.
-- permissions: settings.manage (write); any member of the org may read.
-- ---------------------------------------------------------------------------
create or replace function core.setting_valid(p_key text, p_value jsonb) returns boolean
language sql stable set search_path = '' as $$
  select case p_key
    when 'timezone' then jsonb_typeof(p_value) = 'string'
      and exists (select 1 from pg_catalog.pg_timezone_names n where n.name = p_value #>> '{}')
    else p_value is not null and p_value <> 'null'::jsonb
  end
$$;
revoke all on function core.setting_valid(text, jsonb) from public, anon;
grant execute on function core.setting_valid(text, jsonb) to authenticated, service_role;

create table public.settings (
  id            text collate "C" primary key default core.ulid(),
  org_id        text not null references public.orgs (id) on delete restrict,
  unit_id       text collate "C",
  key           text not null constraint settings_key_chk check (key ~ '^[a-z][a-z0-9_.]{0,60}$'),
  value         jsonb not null,
  created_at    timestamptz not null default now(),
  created_by    text,
  updated_at    timestamptz not null default now(),
  updated_by    text,
  version       integer not null default 1,
  deleted_at    timestamptz,
  deleted_by    text,
  delete_reason text,
  meta          jsonb not null default '{}'::jsonb,
  constraint settings_unit_fk foreign key (unit_id, org_id) references public.org_units (id, org_id) on delete restrict,
  constraint settings_value_chk check (core.setting_valid(key, value))
);
comment on table public.settings is 'class: master. permission: settings.manage (write); org members read.';
create index settings_org_idx on public.settings (org_id);
create index settings_unit_idx on public.settings (unit_id);
create unique index settings_key_active_uq on public.settings (org_id, coalesce(unit_id, ''), key) where deleted_at is null;

-- ---------------------------------------------------------------------------
-- lookups: admin-editable lists. class: master. permission: settings.manage (write).
-- ---------------------------------------------------------------------------
create table public.lookups (
  id            text collate "C" primary key default core.ulid(),
  org_id        text not null references public.orgs (id) on delete restrict,
  type          text not null constraint lookups_type_chk check (type ~ '^[a-z][a-z0-9_]{0,40}$'),
  code          text not null constraint lookups_code_chk check (code ~ '^[a-z0-9][a-z0-9_.-]{0,60}$'),
  label         text not null,
  sort          integer not null default 0,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  created_by    text,
  updated_at    timestamptz not null default now(),
  updated_by    text,
  version       integer not null default 1,
  deleted_at    timestamptz,
  deleted_by    text,
  delete_reason text,
  meta          jsonb not null default '{}'::jsonb
);
comment on table public.lookups is 'class: master. permission: settings.manage (write); org members read.';
create index lookups_org_idx on public.lookups (org_id);
create unique index lookups_code_active_uq on public.lookups (org_id, type, code) where deleted_at is null;

-- ---------------------------------------------------------------------------
-- files: metadata for stored objects. class: master.
-- permissions: payments.verify (read all); uploaders read their own.
-- ---------------------------------------------------------------------------
create table public.files (
  id            text collate "C" primary key default core.ulid(),
  org_id        text not null references public.orgs (id) on delete restrict,
  owner_table   text not null,
  owner_id      text not null,
  kind          text not null,
  bucket        text not null,
  storage_path  text not null,
  content_type  text,
  size_bytes    bigint not null constraint files_size_chk check (size_bytes >= 0),
  checksum      text,
  created_at    timestamptz not null default now(),
  created_by    text,
  updated_at    timestamptz not null default now(),
  updated_by    text,
  version       integer not null default 1,
  deleted_at    timestamptz,
  deleted_by    text,
  delete_reason text,
  meta          jsonb not null default '{}'::jsonb
);
comment on table public.files is 'class: master. permissions: payments.verify (read all); uploader reads own.';
create index files_org_idx on public.files (org_id);
create index files_owner_idx on public.files (owner_table, owner_id);
create index files_created_by_idx on public.files (created_by);
create unique index files_path_active_uq on public.files (bucket, storage_path) where deleted_at is null;

-- ---------------------------------------------------------------------------
-- notifications: outbound queue and history. class: document (status lifecycle).
-- Recipients read their own; status changes only by service code.
-- ---------------------------------------------------------------------------
create table public.notifications (
  id                   text collate "C" primary key default core.ulid(),
  org_id               text not null references public.orgs (id) on delete restrict,
  recipient_profile_id text collate "C" not null references public.profiles (id) on delete restrict,
  channel              text not null constraint notifications_channel_chk check (channel in ('in_app', 'sms', 'email')),
  template             text not null,
  payload              jsonb not null default '{}'::jsonb,
  status               text not null default 'queued' constraint notifications_status_chk check (status in ('queued', 'sent', 'failed', 'cancelled')),
  sent_at              timestamptz,
  read_at              timestamptz,
  error                text,
  created_at           timestamptz not null default now(),
  created_by           text,
  updated_at           timestamptz not null default now(),
  updated_by           text,
  version              integer not null default 1,
  meta                 jsonb not null default '{}'::jsonb
);
comment on table public.notifications is 'class: document. Recipient reads own; writes by service code and RPCs.';
create index notifications_org_idx on public.notifications (org_id);
create index notifications_recipient_idx on public.notifications (recipient_profile_id, created_at desc);
create index notifications_queue_idx on public.notifications (status) where status = 'queued';

-- ---------------------------------------------------------------------------
-- client_errors: browser error reports. class: ledger (append-only).
-- permission: audit.read (read); any signed-in user may report their own.
-- ---------------------------------------------------------------------------
create table public.client_errors (
  id           text collate "C" primary key default core.ulid(),
  org_id       text references public.orgs (id) on delete restrict,
  profile_id   text collate "C" references public.profiles (id) on delete restrict,
  message      text not null constraint client_errors_message_chk check (char_length(message) <= 2000),
  stack        text constraint client_errors_stack_chk check (char_length(stack) <= 8000),
  url          text constraint client_errors_url_chk check (char_length(url) <= 500),
  user_agent   text constraint client_errors_ua_chk check (char_length(user_agent) <= 300),
  app_version  text,
  occurred_at  timestamptz not null default now(),
  created_at   timestamptz not null default now(),
  created_by   text,
  updated_at   timestamptz not null default now(),
  updated_by   text,
  version      integer not null default 1,
  meta         jsonb not null default '{}'::jsonb
);
comment on table public.client_errors is 'class: ledger (append-only). permission: audit.read (read); insert own.';
create index client_errors_org_idx on public.client_errors (org_id, occurred_at desc);
create index client_errors_profile_idx on public.client_errors (profile_id);

select core.attach_standard('public.settings', 'master');
select core.attach_standard('public.lookups', 'master');
select core.attach_standard('public.files', 'master');
select core.attach_standard('public.notifications', 'document');
select core.attach_standard('public.client_errors', 'ledger');

alter table public.settings enable row level security;
alter table public.lookups enable row level security;
alter table public.files enable row level security;
alter table public.notifications enable row level security;
alter table public.client_errors enable row level security;

-- ---------------------------------------------------------------------------
-- RLS policies
-- ---------------------------------------------------------------------------
create policy settings_select on public.settings for select to authenticated
  using (core.is_org_member(org_id));
create policy settings_insert on public.settings for insert to authenticated
  with check (core.has_permission(org_id, unit_id, 'settings.manage'));
create policy settings_update on public.settings for update to authenticated
  using (core.has_permission(org_id, unit_id, 'settings.manage'))
  with check (core.has_permission(org_id, unit_id, 'settings.manage'));

create policy lookups_select on public.lookups for select to authenticated
  using (core.is_org_member(org_id));
create policy lookups_insert on public.lookups for insert to authenticated
  with check (core.has_permission(org_id, null, 'settings.manage'));
create policy lookups_update on public.lookups for update to authenticated
  using (core.has_permission(org_id, null, 'settings.manage'))
  with check (core.has_permission(org_id, null, 'settings.manage'));

create policy files_select on public.files for select to authenticated
  using (created_by = core.current_profile_id() or core.has_permission(org_id, null, 'payments.verify'));
create policy files_insert on public.files for insert to authenticated
  with check (core.is_org_member(org_id));

create policy notifications_select on public.notifications for select to authenticated
  using (recipient_profile_id = core.current_profile_id());

create policy client_errors_insert on public.client_errors for insert to authenticated
  with check (profile_id is not distinct from core.current_profile_id());
create policy client_errors_select on public.client_errors for select to authenticated
  using (org_id is not null and core.has_permission(org_id, null, 'audit.read'));

-- ---------------------------------------------------------------------------
-- Seed: the club timezone (DATABASE.md section 12; all dates use Asia/Manila).
-- ---------------------------------------------------------------------------
insert into public.settings (org_id, key, value)
select o.id, 'timezone', '"Asia/Manila"'::jsonb
from public.orgs o
where o.code = 'cpc' and o.deleted_at is null
on conflict (org_id, (coalesce(unit_id, '')), key) where deleted_at is null do nothing;
