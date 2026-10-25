begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create function pg_temp.mk(p_role text, p_no text, p_dob date, p_email text, p_barangay boolean, p_account boolean default true) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); mid text := core.ulid(); org text := (select id from public.orgs where code = 'cpc');
begin
  insert into public.persons (id, org_id, kind, display_name, date_of_birth, email, mobile, barangay_code)
  values (per, org, 'member', 'Fake ' || p_no, p_dob, p_email, '09171234567', case when p_barangay then (select code from public.psgc_areas where level = 'barangay' limit 1) end);
  if p_account then
    insert into auth.users (id, email) values (u, lower(p_no) || '@members.example.test');
    insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, org, u, per);
    insert into public.org_members (org_id, profile_id, role_id) values (org, pid, (select id from public.roles where org_id = org and code = p_role));
  end if;
  insert into public.members (id, org_id, person_id, profile_id, member_no) values (mid, org, per, case when p_account then pid end, p_no);
  update public.members set status = 'invited' where id = mid;
  update public.members set status = 'pending_approval' where id = mid;
  update public.members set status = 'active' where id = mid;
  insert into public.member_access (org_id, member_id, must_change_password) values (org, mid, false);
  return u;
end $$;
create temp table us(role text primary key, u uuid, mid text);
grant select on us to public;
insert into us select 'admin', pg_temp.mk('admin', 'CPC-2026-98001', '1980-01-01', 'zadmin@example.test', true), null;
insert into us select 'admin2', pg_temp.mk('admin', 'CPC-2026-98002', '1980-02-02', 'zadmin2@example.test', true), null;
insert into us select 'member', pg_temp.mk('member', 'CPC-2026-98003', '1990-07-04', 'zmember@example.test', true), null;
insert into us select 'other', pg_temp.mk('member', 'CPC-2026-98004', '1991-08-05', 'zother@example.test', true), null;
insert into us select 'nodob', pg_temp.mk('member', 'CPC-2026-98005', null, 'znodob@example.test', true), null;
insert into us select 'noemail', pg_temp.mk('member', 'CPC-2026-98006', '1992-09-06', null, true), null;
update us set mid = (select m.id from public.members m join public.profiles p on p.id = m.profile_id where p.auth_user_id = us.u);
create temp table nologin as select pg_temp.mk('member', 'CPC-2026-98007', '1993-10-07', 'znologin@example.test', true, false) as u;
create temp table nl as select m.id from public.members m where m.member_no = 'CPC-2026-98007';
grant select on nl to public;

-- ---- access
select is(has_function_privilege('anon', 'public.admin_prepare_member_reset(text)', 'execute'), false, 'anonymous callers cannot reset');
select pg_temp.as_user((select u from us where role = 'member')); set local role authenticated;
select throws_ok(format($f$select public.admin_prepare_member_reset(%L)$f$, (select mid from us where role = 'other')), '42501', 'you do not have permission to reset passwords', 'a member cannot reset another member');
reset role;

-- ---- what an administrator may reset
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select is((select public.admin_prepare_member_reset((select mid from us where role = 'member')) ->> 'member_no'), 'CPC-2026-98003', 'an administrator can prepare a reset for a member');
select is((select public.admin_prepare_member_reset((select mid from us where role = 'member')) ->> 'date_of_birth'), '1990-07-04', 'with the birth date on file');
select throws_ok(format($f$select public.admin_prepare_member_reset(%L)$f$, (select mid from us where role = 'admin')), '22023', 'use Change password for your own account', 'not your own account');
select throws_ok(format($f$select public.admin_prepare_member_reset(%L)$f$, (select mid from us where role = 'admin2')), '42501', 'an administrator account cannot be reset here', 'not another administrator');
select throws_ok(format($f$select public.admin_prepare_member_reset(%L)$f$, (select mid from us where role = 'nodob')), '22023', 'this member has no birth date on file; add it first', 'a member with no birth date cannot be reset');
select throws_ok(format($f$select public.admin_prepare_member_reset(%L)$f$, (select id from nl)), '22023', 'this member has no sign-in to reset', 'nor one with no sign-in');
select throws_ok(format($f$select public.admin_prepare_member_reset(%L)$f$, core.ulid()), '22023', 'member not found', 'nor one that does not exist');

-- ---- finishing: the member must change the password and confirm the profile
select public.admin_finish_member_reset((select mid from us where role = 'member'));
reset role;
select is((select must_change_password from public.member_access where member_id = (select mid from us where role = 'member')), true, 'the member must change the password');
select is((select must_confirm_profile from public.member_access where member_id = (select mid from us where role = 'member')), true, 'and confirm their profile');
select ok(exists (select 1 from core.audit_log where action = 'member.password_reset_by_admin' and record_id = (select mid from us where role = 'member')), 'the reset is audited');
select pg_temp.as_user((select u from us where role = 'other')); set local role authenticated;
select throws_ok(format($f$select public.admin_finish_member_reset(%L)$f$, (select mid from us where role = 'member')), '42501', null, 'only an administrator can finish a reset');
reset role;

-- ---- the gate: the member's own state shows it, and saving the profile with an email clears it
select pg_temp.as_user((select u from us where role = 'member')); set local role authenticated;
select is((select must_confirm_profile from public.my_access_state()), true, 'the member sees they must confirm their profile');
select is((select profile_complete from public.my_access_state()), true, 'their profile is already complete');
select lives_ok($f$select public.confirm_my_profile()$f$, 'confirming works when the profile is complete');
select is((select must_confirm_profile from public.my_access_state()), false, 'and clears the flag');
reset role;

-- ---- an email is always required
select is(core.profile_complete((select p.id from public.persons p join public.members m on m.person_id = p.id where m.id = (select mid from us where role = 'noemail'))), false, 'a profile with no email is not complete');
select is(core.profile_complete((select p.id from public.persons p join public.members m on m.person_id = p.id where m.id = (select mid from us where role = 'member'))), true, 'with an email it is');
select pg_temp.as_user((select u from us where role = 'noemail')); set local role authenticated;
select throws_ok($f$select public.confirm_my_profile()$f$, '22023', 'complete your profile, including your email, first', 'a member without an email cannot clear the flag');
select throws_ok(format($f$select public.update_my_profile('Fake Name', '09171234567', null, null, %L)$f$, (select code from public.psgc_areas where level = 'barangay' limit 1)), '22023', 'an email address is required', 'saving the profile without an email is refused');
reset role;

-- ---- profile photo
select pg_temp.as_user((select u from us where role = 'member')); set local role authenticated;
select throws_ok(format($f$select public.set_my_avatar(%L)$f$, (select org_id from public.profiles where auth_user_id = (select u from us where role = 'member')) || '/someone-else/photo.jpg'), '42501', null, 'a photo path in another folder is refused');
select throws_ok(format($f$select public.set_my_avatar(%L)$f$, (select org_id || '/' || id || '/missing.jpg' from public.profiles where auth_user_id = (select u from us where role = 'member'))), '22023', 'the photo was not found; upload it again', 'a photo that was never uploaded is refused');
reset role;
insert into storage.objects (bucket_id, name, owner) values ('avatars', (select org_id || '/' || id || '/mine.jpg' from public.profiles where auth_user_id = (select u from us where role = 'member')), (select u from us where role = 'member'));
select pg_temp.as_user((select u from us where role = 'member')); set local role authenticated;
select lives_ok(format($f$select public.set_my_avatar(%L)$f$, (select org_id || '/' || id || '/mine.jpg' from public.profiles where auth_user_id = (select u from us where role = 'member'))), 'an uploaded photo can be set');
select ok((select avatar_path from public.my_access_state()) like '%/mine.jpg', 'and is part of the member''s own state');
select lives_ok($f$select public.set_my_avatar(null)$f$, 'a photo can be removed from the profile');
select is((select avatar_path from public.my_access_state()), null, 'and then it is empty');
reset role;
select is((select public from storage.buckets where id = 'avatars'), false, 'the photo bucket is private');
select is((select file_size_limit from storage.buckets where id = 'avatars'), 3145728::bigint, 'with a 3 MB limit');
select is((select allowed_mime_types from storage.buckets where id = 'avatars'), array['image/jpeg', 'image/png', 'image/webp'], 'and only image types');

select * from finish();
rollback;
