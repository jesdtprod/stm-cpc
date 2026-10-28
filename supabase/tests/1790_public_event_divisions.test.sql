begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

set local role anon;
create temp table li as select public.public_landing_info() as j;
reset role;
grant select on li to public;

select ok((select count(*)::int from li, jsonb_array_elements(j -> 'events') e where jsonb_typeof(e -> 'divisions') = 'array') >= 1,
  'events include a divisions array');
select ok(not exists (select 1 from li, jsonb_array_elements(j -> 'events') e, jsonb_array_elements(e -> 'divisions') d
  where not (d ? 'name' and d ? 'format' and d ? 'category' and d ? 'taken' and d ? 'max_entries')),
  'each division has name, format, category, taken and max_entries');
select ok(not exists (select 1 from li, jsonb_array_elements(j -> 'events') e, jsonb_array_elements(e -> 'divisions') d
  where d ? 'id' or d ? 'registrations' or d ? 'members'),
  'divisions expose no ids or registrant details');
select ok(not exists (select 1 from li, jsonb_array_elements(j -> 'events') e
  where jsonb_array_length(e -> 'divisions') <> (e ->> 'divisions_count')::int),
  'divisions list matches divisions_count');

select * from finish();
rollback;
