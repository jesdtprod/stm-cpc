begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();

select is(public.member_reset_target('CPC-0000-00000'), null::uuid, 'an unknown member ID has no reset target');

select is(
  has_function_privilege('anon', 'public.member_reset_target(text)', 'execute')
    or has_function_privilege('authenticated', 'public.member_reset_target(text)', 'execute')
    or has_function_privilege('anon', 'public.member_reset_done(text)', 'execute')
    or has_function_privilege('authenticated', 'public.member_reset_done(text)', 'execute'),
  false,
  'only the service role can run the member password reset functions');

select is(has_function_privilege('service_role', 'public.member_reset_target(text)', 'execute'), true, 'the service role can look up a target');

select * from finish();
rollback;
