-- Post-application verification; read-only assertions, transaction rolled back.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select no_plan();
select is((select count(*) from public.events where id in
 ('01M61GRT7AQ9JB7V34G2NZW0HB','01M6T9PNQRPK825N59P9SJ7SMN')),0::bigint,'Both reviewed test events removed');
select is((select count(*) from core.audit_log where action='event.test_data_purged'
 and new_values->>'migration'='2620'),1::bigint,'One permanent purge audit');
select is((select count(*) from public.divisions where event_id in
 ('01M61GRT7AQ9JB7V34G2NZW0HB','01M6T9PNQRPK825N59P9SJ7SMN')),0::bigint,'No test divisions');
select is((select count(*) from public.registrations where event_id in
 ('01M61GRT7AQ9JB7V34G2NZW0HB','01M6T9PNQRPK825N59P9SJ7SMN')),0::bigint,'No test registrations');
select is((select count(*) from pg_policy where polname='purge_2620_maintenance'),0::bigint,'Temporary policies removed');
select ok(not exists(select 1 from pg_class where relnamespace='public'::regnamespace
 and relkind='r' and not relrowsecurity),'Public table RLS remains enabled');
select * from finish();
rollback;
