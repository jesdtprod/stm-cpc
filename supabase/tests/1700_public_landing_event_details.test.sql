begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

set local role anon;
create temp table li as select public.public_landing_info() as j;
reset role;
grant select on li to public;

select is(has_function_privilege('anon', 'public.public_landing_info()', 'execute'), true, 'anyone can read the landing information');
select ok((select count(*)::int from li, jsonb_array_elements(j -> 'events') e where e ? 'divisions_count') >= 1, 'events include divisions_count');
select ok((select count(*)::int from li, jsonb_array_elements(j -> 'events') e where e ? 'registration_opens_at') >= 1, 'events include registration_opens_at');
select ok((select count(*)::int from li, jsonb_array_elements(j -> 'events') e where e ? 'registration_closes_at') >= 1, 'events include registration_closes_at');
select ok((select count(*)::int from li, jsonb_array_elements(j -> 'events') e where e ? 'dupr_rated') >= 1, 'events include dupr_rated flag');
select ok((select count(*)::int from li, jsonb_array_elements(j -> 'events') e where e ? 'apply_cpc_rank_changes') >= 1, 'events include apply_cpc_rank_changes flag');
select ok((select count(*)::int from li, jsonb_array_elements(j -> 'events') e where e ? 'default_format_template_name') >= 1, 'events include default_format_template_name');

select * from finish();
rollback;

