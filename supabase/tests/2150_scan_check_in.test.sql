begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();
select is(has_function_privilege('anon', 'public.scan_check_in(text, text)', 'execute'), false, 'visitors cannot scan');
select is(has_function_privilege('authenticated', 'public.scan_check_in(text, text)', 'execute'), true, 'signed-in staff can call it; the function checks the permission');
select throws_ok($$select core.scan_check_in('NOPE', 'k1')$$, '22023', 'this QR code does not match any booking', 'an unknown code is refused');
select * from finish();
rollback;
