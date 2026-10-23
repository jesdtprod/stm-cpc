-- 0001_core_ulid (PLAN 1.1)
-- Schema `core` (internal, never exposed through the API), the ULID generator
-- and the ULID format check. Kit version: core v1.0.0.

create schema if not exists core;
comment on schema core is 'Internal helpers and tables. Not exposed through the API (config.toml api.schemas lists only public and graphql_public).';

-- Only signed-in roles may reach core objects; anon gets nothing.
revoke all on schema core from public;
grant usage on schema core to authenticated, service_role;

-- 48-bit millisecond timestamp + 80 random bits, Crockford base32 (DATABASE.md section 4).
create or replace function core.ulid() returns text
language plpgsql volatile set search_path = '' as $$
declare
  enc text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  ts  bigint := floor(extract(epoch from clock_timestamp()) * 1000)::bigint;
  rnd bytea := extensions.gen_random_bytes(10);
  res text := '';
  i int; b int; v int;
begin
  for i in 0..9 loop
    res := res || substr(enc, ((ts >> (5 * (9 - i))) & 31)::int + 1, 1);
  end loop;
  for i in 0..15 loop
    b := (i * 5) / 8;
    v := (get_byte(rnd, b) << 8) | get_byte(rnd, least(b + 1, 9));
    res := res || substr(enc, ((v >> (16 - ((i * 5) % 8) - 5)) & 31) + 1, 1);
  end loop;
  return res;
end $$;

-- Format check shared by constraints and RPCs: 26 chars, Crockford base32, first char 0-7.
create or replace function core.is_ulid(value text) returns boolean
language sql immutable parallel safe set search_path = '' as $$
  select value ~ '^[0-7][0-9A-HJKMNP-TV-Z]{25}$'
$$;

-- Decodes the creation time of a ULID (used to reject IDs far in the future).
create or replace function core.ulid_time(value text) returns timestamptz
language plpgsql immutable set search_path = '' as $$
declare
  enc text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  ms bigint := 0;
  i int;
begin
  if not core.is_ulid(value) then
    raise exception 'invalid ULID' using errcode = '22023';
  end if;
  for i in 1..10 loop
    ms := (ms << 5) | (strpos(enc, substr(value, i, 1)) - 1);
  end loop;
  return to_timestamp(ms / 1000.0);
end $$;

revoke all on function core.ulid() from public, anon;
revoke all on function core.is_ulid(text) from public, anon;
revoke all on function core.ulid_time(text) from public, anon;
grant execute on function core.ulid() to authenticated, service_role;
grant execute on function core.is_ulid(text) to authenticated, service_role;
grant execute on function core.ulid_time(text) to authenticated, service_role;
