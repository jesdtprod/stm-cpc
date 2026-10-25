begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create temp table fx as select (select id from public.orgs where code = 'cpc') as org, core.ulid() as p1, core.ulid() as p2, core.ulid() as p3, core.ulid() as p4;
grant select on fx to public;

insert into public.persons (id, org_id, kind, display_name, email) values ((select p1 from fx), (select org from fx), 'member', 'Zzyzx One', 'zzyzx.one@example.test');

select throws_ok(format($f$insert into public.persons (id, org_id, kind, display_name, email) values (%L, %L, 'member', 'Zzyzx Two', ' ZZYZX.One@Example.test ')$f$, (select p2 from fx), (select org from fx)),
  '23505', 'that email is already used by another member', 'the same email is refused, ignoring case and spaces');
select lives_ok(format($f$insert into public.persons (id, org_id, kind, display_name, email) values (%L, %L, 'member', 'Zzyzx Two', 'zzyzx.two@example.test')$f$, (select p2 from fx), (select org from fx)), 'a different email is accepted');
select throws_ok(format($f$update public.persons set email = 'zzyzx.one@example.test' where id = %L$f$, (select p2 from fx)),
  '23505', 'that email is already used by another member', 'changing a profile to a used email is refused');
select lives_ok(format($f$update public.persons set display_name = 'Zzyzx Two B' where id = %L$f$, (select p2 from fx)), 'other edits are unaffected');
select lives_ok(format($f$insert into public.persons (id, org_id, kind, display_name, email) values (%L, %L, 'member', 'Zzyzx Three', null)$f$, (select p3 from fx), (select org from fx)), 'a member with no email is accepted');
select lives_ok(format($f$insert into public.persons (id, org_id, kind, display_name, email) values (%L, %L, 'member', 'Zzyzx Four', '')$f$, (select p4 from fx), (select org from fx)), 'and so are several with an empty email');

-- addresses that were already shared before the rule keep working
set local session_replication_role = replica;
insert into public.persons (id, org_id, kind, display_name, email) values (core.ulid(), (select org from fx), 'member', 'Zzyzx Old Share', 'zzyzx.one@example.test');
set local session_replication_role = origin;
select lives_ok(format($f$update public.persons set display_name = 'Zzyzx One B' where id = %L$f$, (select p1 from fx)), 'a member whose address was already shared can still be edited');
select lives_ok(format($f$update public.persons set email = 'zzyzx.one@example.test', mobile = '09171230000' where id = %L$f$, (select p1 from fx)), 'and saving the same address again is not refused');
select lives_ok(format($f$update public.persons set email = 'ZZYZX.one@example.test' where id = %L$f$, (select p1 from fx)), 'the same address in another case is not a change');
select is(public.signup_email_taken('ZZYZX.ONE@example.test'), true, 'sign-up can ask whether an email is taken');
select is(public.signup_email_taken('free.address@example.test'), false, 'a free address is not taken');
select is(has_function_privilege('anon', 'public.signup_email_taken(text)', 'execute'), false, 'the public cannot ask');
select is(has_function_privilege('authenticated', 'public.signup_email_taken(text)', 'execute'), false, 'nor can signed-in members');

select * from finish();
rollback;
