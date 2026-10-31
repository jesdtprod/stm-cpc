begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();
select is(
  (select array_agg(pe.code order by pe.code)
   from public.roles r
   join public.role_permissions rp on rp.role_id = r.id and rp.deleted_at is null
   join public.permissions pe on pe.id = rp.permission_id
   where r.code = 'scanner' and r.deleted_at is null),
  array['bookings.checkin'],
  'the scanner role holds only bookings.checkin');
select is(has_function_privilege('authenticated', 'public.create_scanner_member(text, text, uuid)', 'execute'), false, 'only the service role makes scanner accounts');
select is(has_function_privilege('service_role', 'public.create_scanner_member(text, text, uuid)', 'execute'), true, 'the Edge Function can');
select * from finish();
rollback;
