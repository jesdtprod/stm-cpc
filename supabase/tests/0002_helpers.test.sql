begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

-- Scratch tables (rolled back): one master table and one append-only table.
create table public.t_std (
  id text collate "C" primary key default core.ulid(),
  org_id text not null, unit_id text,
  created_at timestamptz, created_by text, updated_at timestamptz, updated_by text,
  version int, deleted_at timestamptz, deleted_by text, delete_reason text,
  meta jsonb not null default '{}', name text, email text
);
create table public.t_led (
  id text collate "C" primary key default core.ulid(),
  org_id text not null, unit_id text,
  created_at timestamptz, created_by text, updated_at timestamptz, updated_by text,
  version int, meta jsonb not null default '{}', amount numeric
);
select core.attach_standard('public.t_std', 'master');
select core.attach_standard('public.t_led', 'ledger');
grant all on public.t_std, public.t_led to authenticated;
-- Supabase enables RLS on new public tables automatically; these scratch tables test the triggers, not RLS.
alter table public.t_std disable row level security;
alter table public.t_led disable row level security;

create temp table k as select core.ulid() as a;
grant select on k to public;

insert into public.t_std (id, org_id, name, email, created_at, created_by, version)
values ((select a from k), 'org_a', 'one', 'a@example.test', '2000-01-01', 'attacker', 99);

-- stamping: client-supplied stamps are overwritten
select is((select version from public.t_std where name = 'one'), 1, 'insert stamps version = 1');
select is((select created_by from public.t_std where name = 'one'), 'system', 'insert stamps created_by from the server');
select ok((select created_at from public.t_std where name = 'one') > '2020-01-01', 'insert stamps created_at from the server');

update public.t_std set name = 'uno' where name = 'one';
select is((select version from public.t_std where name = 'uno'), 2, 'update bumps version');
select is((select count(*)::int from public.t_std where name = 'uno' and version = 1), 0, 'a stale version matches no row (optimistic concurrency)');

-- immutable columns
select throws_ok($$update public.t_std set id = core.ulid() where name = 'uno'$$, '42501', 'column id is immutable', 'id cannot change');
select throws_ok($$update public.t_std set created_at = now() - interval '1 day' where name = 'uno'$$, '42501', 'column created_at is immutable', 'created_at cannot change');
select throws_ok($$update public.t_std set created_by = 'me' where name = 'uno'$$, '42501', 'column created_by is immutable', 'created_by cannot change');
select throws_ok($$update public.t_std set org_id = 'org_b' where name = 'uno'$$, '42501', 'column org_id cannot change after creation', 'org_id cannot change');
select set_config('core.allow_move', 'on', true);
select lives_ok($$update public.t_std set org_id = 'org_b' where name = 'uno'$$, 'a permissioned move RPC may change org_id');
select set_config('core.allow_move', 'off', true);

-- hard delete is blocked, for the table owner and for client roles
select throws_ok($$delete from public.t_std where name = 'uno'$$, '42501', 'hard delete is not allowed on public.t_std', 'hard delete refused by trigger');
select throws_ok($$truncate public.t_std$$, '42501', 'truncate is not allowed on public.t_std', 'truncate refused');
set local role authenticated;
select throws_ok($$delete from public.t_std where name = 'uno'$$, '42501', 'hard delete is not allowed on public.t_std', 'client DELETE refused');
reset role;

-- soft delete rules
select throws_ok(
  $$update public.t_std set deleted_at = now(), deleted_by = 'x' where name = 'uno'$$,
  '42501', 'deleted_* columns change only through soft_delete / restore RPCs', 'deleted_* cannot be written directly');
select set_config('core.rpc', 'on', true);
select lives_ok($$update public.t_std set deleted_at = now(), delete_reason = 'test' where name = 'uno'$$, 'soft delete inside an RPC works');
select is((select deleted_by from public.t_std where name = 'uno'), 'system', 'soft delete stamps deleted_by');
select set_config('core.rpc', 'off', true);
select throws_ok(
  $$update public.t_std set name = 'x' where name = 'uno'$$,
  '55000', 'a deleted row cannot be updated; restore it first', 'a deleted row rejects updates');
select set_config('core.rpc', 'on', true);
select lives_ok($$update public.t_std set deleted_at = null, deleted_by = null, delete_reason = null where name = 'uno'$$, 'restore works');
select set_config('core.rpc', 'off', true);
select is((select deleted_at is null from public.t_std where name = 'uno'), true, 'row is active again after restore');
select throws_ok(
  $$update public.t_std set deleted_by = 'someone' where name = 'uno'$$,
  '42501', null, 'deleted_by alone cannot be set directly');

-- id format check
select throws_ok($$insert into public.t_std (id, org_id) values ('bad', 'org_a')$$, '23514', null, 'a malformed id is rejected');
select lives_ok($$select core.attach_standard('public.t_std', 'master')$$, 'attach_standard is idempotent');

-- audit log
select ok(exists(select 1 from core.audit_log where table_name = 'public.t_std' and record_id = (select a from k) and action = 'insert'), 'insert is audited');
select ok(exists(select 1 from core.audit_log where table_name = 'public.t_std' and record_id = (select a from k) and action = 'update' and old_values ->> 'name' = 'one' and new_values ->> 'name' = 'uno'), 'update audit holds changed columns');
select ok(exists(select 1 from core.audit_log where table_name = 'public.t_std' and record_id = (select a from k) and action = 'soft_delete'), 'soft delete is audited');
select ok(exists(select 1 from core.audit_log where table_name = 'public.t_std' and record_id = (select a from k) and action = 'restore'), 'restore is audited');
select is((select new_values ->> 'email' from core.audit_log where table_name = 'public.t_std' and record_id = (select a from k) and action = 'insert'), '***', 'personal fields are masked in the audit log');
select lives_ok($$select core.write_audit('org_a', 'signin', 'auth', null)$$, 'write_audit appends a row');
select ok(exists(select 1 from core.audit_log where action = 'signin' and org_id = 'org_a'), 'write_audit row exists');
select throws_ok($$update core.audit_log set action = 'x'$$, '42501', 'audit_log is insert-only', 'audit_log update refused');
select throws_ok($$delete from core.audit_log$$, '42501', 'audit_log is insert-only', 'audit_log delete refused');
select throws_ok($$truncate core.audit_log$$, '42501', 'audit_log is insert-only', 'audit_log truncate refused');
set local role authenticated;
select throws_ok($$select count(*) from core.audit_log$$, '42501', null, 'clients cannot read audit_log directly');
reset role;

-- append-only table
insert into public.t_led (org_id, amount) values ('org_a', 10);
select is((select version from public.t_led), 1, 'ledger insert is stamped');
select throws_ok($$update public.t_led set amount = 11$$, '42501', 't_led is append-only: corrections are new reversing rows', 'ledger update refused');
select throws_ok($$delete from public.t_led$$, '42501', 'hard delete is not allowed on public.t_led', 'ledger delete refused');

select * from finish();
rollback;
