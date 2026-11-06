begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

set local role anon;
create temp table public_event_result as select public.public_landing_info() as payload;
reset role;

select is(
  (select jsonb_array_length(payload -> 'events') from public_event_result),
  (select count(*)::int from public.events e join public.orgs o on o.id = e.org_id
    where o.code = 'cpc' and o.deleted_at is null
      and e.status in ('registration_open', 'registration_closed', 'drawn', 'in_progress', 'completed', 'cancelled')),
  'anonymous list includes all published events regardless of end date');
select ok(not exists (
  select 1 from public_event_result, jsonb_array_elements(payload -> 'events') e
    where e ->> 'status' not in ('registration_open', 'registration_closed', 'drawn', 'in_progress', 'completed', 'cancelled')),
  'draft events are private');
select ok(not exists (
  select 1 from public_event_result, jsonb_array_elements(payload -> 'events') e
    where e ?| array['id', 'created_by', 'registrations', 'members', 'cancel_reason']),
  'public event data excludes private details');
select ok(has_function_privilege('anon', 'public.public_landing_info()', 'EXECUTE'),
  'anonymous visitors can read public event summaries');

select * from finish();
rollback;
