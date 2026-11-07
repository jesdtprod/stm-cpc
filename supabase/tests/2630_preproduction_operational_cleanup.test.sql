-- Run after the explicitly authorized pre-production reset.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select no_plan();
select is((select count(*) from public.bookings),0::bigint,'Test bookings removed');
select is((select count(*) from public.booking_events),0::bigint,'Test booking history removed');
select is((select count(*) from public.booking_participants),0::bigint,'Test booking participants removed');
select is((select count(*) from public.member_notifications),0::bigint,'Member notifications cleared');
select is((select count(*) from public.member_notification_reads),0::bigint,'Notification reads cleared');
select is((select count(*) from public.notifications),0::bigint,'Notification queue cleared');
select is((select count(*) from public.payment_submissions),0::bigint,'Payment table remains empty');
select is((select count(*) from public.ledger_entries),0::bigint,'Financial ledger remains empty');
select is((select count(*) from core.audit_log where action='preproduction.operational_cleanup'
 and new_values->>'migration'='2630'),1::bigint,'Cleanup audit retained');
select is((select count(*) from pg_policy where polname='purge_2630_maintenance'),0::bigint,'Temporary maintenance policies removed');
select * from finish();
rollback;
