begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();
select has_column('public', 'members', 'is_staff_account', 'members carry the staff flag');
select is(
  (select count(*)::int from public.members m
   where m.profile_id is not null and m.is_staff_account is distinct from core.is_staff_profile(m.profile_id)),
  0, 'the flag matches the roles everywhere');
select is(
  (select count(*)::int from core.public_member_rows() r join public.members m on m.id = r.member_id where m.is_staff_account),
  0, 'the public Members page lists no staff account');
select * from finish();
rollback;
