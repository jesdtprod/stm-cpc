-- 1070_login_throttle (PLAN 3.1)
-- Support for the member-login Edge Function: failure counters and lockout that work the same for member IDs
-- that exist and ones that do not, and two small service-only reads/writes. Nothing here is callable by
-- members or the public; only service_role (the Edge Function) can call the public.login_* wrappers.
-- The counters hold SHA-256 hashes of "id:<MEMBER-ID>" and "ip:<address>", never the values themselves.

create table core.login_throttle (
  key_hash          text primary key constraint login_throttle_key_chk check (key_hash ~ '^(id|ip):[0-9a-f]{64}$'),
  failures          integer not null default 0 constraint login_throttle_failures_chk check (failures >= 0),
  window_started_at timestamptz not null default now(),
  locked_until      timestamptz,
  updated_at        timestamptz not null default now()
);
comment on table core.login_throttle is 'class: internal. Sign-in failure counters per hashed member ID and per hashed address. Written by core.login_record_failure only.';
create index login_throttle_updated_idx on core.login_throttle (updated_at);
alter table core.login_throttle enable row level security;
revoke all on core.login_throttle from public, anon, authenticated;
create policy deny_clients on core.login_throttle for all to anon, authenticated using (false);

-- True when any of the keys is locked right now.
create or replace function core.login_is_locked(p_keys text[]) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from core.login_throttle t where t.key_hash = any (p_keys) and t.locked_until > now())
$$;

-- Counts one failure for the key. After p_max failures inside the window the key is locked for p_lock_seconds.
-- Returns true when the key is locked after this failure. An advisory lock per key serializes parallel
-- guesses, so they cannot slip past the limit.
create or replace function core.login_record_failure(p_key text, p_max integer, p_window_seconds integer, p_lock_seconds integer)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  r core.login_throttle;
  n integer;
  started timestamptz;
  lock_until timestamptz;
begin
  perform pg_advisory_xact_lock(hashtext(p_key));
  select * into r from core.login_throttle where key_hash = p_key;
  if not found then
    n := 1;
    started := now();
    lock_until := null;
  else
    lock_until := r.locked_until;
    if r.window_started_at < now() - make_interval(secs => p_window_seconds) then
      n := 1;
      started := now();
    else
      n := r.failures + 1;
      started := r.window_started_at;
    end if;
  end if;
  if n >= p_max then
    lock_until := now() + make_interval(secs => p_lock_seconds);
  end if;
  insert into core.login_throttle as t (key_hash, failures, window_started_at, locked_until, updated_at)
  values (p_key, n, started, lock_until, now())
  on conflict (key_hash) do update
    set failures = excluded.failures, window_started_at = excluded.window_started_at,
        locked_until = excluded.locked_until, updated_at = now();
  return coalesce(lock_until > now(), false);
end $$;

create or replace function core.login_clear(p_key text) returns void
language sql security definer set search_path = '' as $$
  delete from core.login_throttle where key_hash = p_key
$$;

create or replace function core.login_purge_old() returns integer
language plpgsql security definer set search_path = '' as $$
declare
  n integer;
begin
  delete from core.login_throttle where updated_at < now() - interval '2 days' and coalesce(locked_until, '-infinity') < now();
  get diagnostics n = row_count;
  return n;
end $$;

-- What the login function needs to know about a signed-in Auth user.
create or replace function core.member_login_state(p_auth_user_id uuid)
returns table (member_id text, member_no text, status text, must_change_password boolean, temp_password_expires_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select m.id, m.member_no, m.status, coalesce(a.must_change_password, false), a.temp_password_expires_at
  from public.profiles p
  join public.members m on m.profile_id = p.id and m.deleted_at is null
  left join public.member_access a on a.member_id = m.id and a.deleted_at is null
  where p.auth_user_id = p_auth_user_id and p.is_active and p.deleted_at is null
  limit 1
$$;

-- Records a successful sign-in: stamps member_access and writes the audit row. Holds no personal data.
create or replace function core.member_login_succeeded(p_member_id text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  org text;
begin
  update public.member_access set last_login_at = now(), failed_attempts = 0, locked_until = null
  where member_id = p_member_id and deleted_at is null;
  select m.org_id into org from public.members m where m.id = p_member_id;
  if org is not null then
    insert into core.audit_log (org_id, actor_id, action, table_name, record_id)
    values (org, 'system', 'login.success', 'public.members', p_member_id);
  end if;
end $$;

-- Service-only wrappers in public so the Edge Function can reach them through the API.
create or replace function public.login_is_locked(p_keys text[]) returns boolean
language sql stable security invoker set search_path = '' as $$ select core.login_is_locked(p_keys) $$;
create or replace function public.login_record_failure(p_key text, p_max integer, p_window_seconds integer, p_lock_seconds integer) returns boolean
language sql security invoker set search_path = '' as $$ select core.login_record_failure(p_key, p_max, p_window_seconds, p_lock_seconds) $$;
create or replace function public.login_clear(p_key text) returns void
language sql security invoker set search_path = '' as $$ select core.login_clear(p_key) $$;
create or replace function public.member_login_state(p_auth_user_id uuid)
returns table (member_id text, member_no text, status text, must_change_password boolean, temp_password_expires_at timestamptz)
language sql stable security invoker set search_path = '' as $$ select * from core.member_login_state(p_auth_user_id) $$;
create or replace function public.member_login_succeeded(p_member_id text) returns void
language sql security invoker set search_path = '' as $$ select core.member_login_succeeded(p_member_id) $$;

revoke all on function core.login_is_locked(text[]), core.login_record_failure(text, integer, integer, integer), core.login_clear(text),
  core.login_purge_old(), core.member_login_state(uuid), core.member_login_succeeded(text) from public, anon, authenticated;
revoke all on function public.login_is_locked(text[]), public.login_record_failure(text, integer, integer, integer), public.login_clear(text),
  public.member_login_state(uuid), public.member_login_succeeded(text) from public, anon, authenticated;
grant execute on function core.login_is_locked(text[]), core.login_record_failure(text, integer, integer, integer), core.login_clear(text),
  core.login_purge_old(), core.member_login_state(uuid), core.member_login_succeeded(text) to service_role;
grant execute on function public.login_is_locked(text[]), public.login_record_failure(text, integer, integer, integer), public.login_clear(text),
  public.member_login_state(uuid), public.member_login_succeeded(text) to service_role;
