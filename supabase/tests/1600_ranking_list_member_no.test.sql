-- Tests for migration 1600: ranking_list always includes member_no for club members
begin;
select plan(3);

create temp table hid(h1 text, h2 text, h3 text);
insert into hid values (core.generate_ulid(), core.generate_ulid(), core.generate_ulid());

select pg_temp.as_user((select u from us where role = 'low')); set local role authenticated;
create temp table rl_1600 as select * from public.ranking_list();
reset role;
grant select on rl_1600 to public;

select ok((select count(*) from rl_1600 where display_name like 'Zzyzx%') = 4, 'four active, ranked members listed');
select is((select member_no from rl_1600 where display_name = 'Zzyzx High'), 'CPC-2026-97604', 'members see the member ID in the ranking list');
select is((select member_no from rl_1600 where display_name = 'Zzyzx Low'), 'CPC-2026-97602', 'every ranked member includes their member ID');

select * from finish();
rollback;

