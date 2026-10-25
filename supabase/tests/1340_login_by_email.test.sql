begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.mk(p_no text, p_email text, p_account boolean) returns void language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); org text := (select id from public.orgs where code = 'cpc');
begin
  insert into public.persons (id, org_id, display_name, email) values (per, org, 'Fake ' || p_no, p_email);
  if p_account then
    insert into auth.users (id, email) values (u, lower(p_no) || '@members.example.test');
    insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, org, u, per);
    insert into public.org_members (org_id, profile_id, role_id) values (org, pid, (select id from public.roles where org_id = org and code = 'member'));
  end if;
  insert into public.members (org_id, person_id, profile_id, member_no) values (org, per, case when p_account then pid end, p_no);
end $$;

select pg_temp.mk('CPC-2026-9601', 'Solo.Person@Example.Test', true);
select pg_temp.mk('CPC-2026-9602', 'family@example.test', true);
-- shared addresses exist from before the one-email rule (1440), so the second family member is added around it
set local session_replication_role = replica;
select pg_temp.mk('CPC-2026-9603', 'family@example.test', true);
set local session_replication_role = origin;
select pg_temp.mk('CPC-2026-9604', 'noaccount@example.test', false);

select is(public.member_no_for_email('solo.person@example.test'), 'CPC-2026-9601', 'an address used by one member finds them');
select is(public.member_no_for_email('  SOLO.PERSON@EXAMPLE.TEST '), 'CPC-2026-9601', 'whatever the capitals or spaces');
select is(public.member_no_for_email('family@example.test'), null, 'an address two members share finds nobody');
select is(public.member_no_for_email('noaccount@example.test'), null, 'a member without an account cannot sign in by email');
select is(public.member_no_for_email('nobody@example.test'), null, 'an unknown address finds nobody');
select is(public.member_no_for_email(''), null, 'an empty address finds nobody');
select is(public.member_no_for_email(repeat('a', 300) || '@example.test'), null, 'an address that is too long finds nobody');

select is(has_function_privilege('anon', 'public.member_no_for_email(text)', 'execute'), false, 'a visitor cannot ask who owns an address');
select is(has_function_privilege('authenticated', 'public.member_no_for_email(text)', 'execute'), false, 'nor a signed-in member');
select is(has_function_privilege('service_role', 'public.member_no_for_email(text)', 'execute'), true, 'only the sign-in function (service role) can');

select * from finish();
rollback;
