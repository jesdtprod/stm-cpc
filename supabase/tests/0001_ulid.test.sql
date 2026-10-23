begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

-- 1.1: generated IDs match the format and sort by time
select ok(core.ulid() ~ '^[0-7][0-9A-HJKMNP-TV-Z]{25}$', 'ulid() matches the format check');
select is(length(core.ulid()), 26, 'ulid() is 26 characters');
select ok(core.is_ulid(core.ulid()), 'is_ulid accepts a generated value');
select ok(not core.is_ulid('not-a-ulid'), 'is_ulid rejects garbage');
select ok(not core.is_ulid('8ZZZZZZZZZZZZZZZZZZZZZZZZZ'), 'is_ulid rejects a first character above 7');
select ok(not core.is_ulid('0ILOU0000000000000000000000'), 'is_ulid rejects excluded letters (I L O U)');
select ok(not core.is_ulid(null), 'is_ulid(null) is not true');

select is(
  (select count(distinct core.ulid()) from generate_series(1, 2000)),
  2000::bigint,
  '2000 generated IDs are all distinct'
);

create temp table t_ids(seq int, id text);
insert into t_ids select 1, core.ulid();
select pg_sleep(0.01);
insert into t_ids select 2, core.ulid();
select pg_sleep(0.01);
insert into t_ids select 3, core.ulid();
select is(
  (select array_agg(seq order by id collate "C") from t_ids),
  array[1, 2, 3],
  'IDs sort by creation time under collation C'
);

select ok(
  abs(extract(epoch from core.ulid_time(core.ulid()) - clock_timestamp())) < 5,
  'ulid_time() decodes the creation time'
);
select throws_ok($$select core.ulid_time('bad')$$, '22023', 'invalid ULID', 'ulid_time rejects an invalid ULID');

-- anon cannot call core functions
set local role anon;
select throws_ok($$select core.ulid()$$, '42501', null, 'anon cannot execute core.ulid()');
reset role;

select * from finish();
rollback;
