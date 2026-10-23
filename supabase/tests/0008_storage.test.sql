begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create function pg_temp.mk(p_role text) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); org text; rid text;
begin
  select id into org from public.orgs where code = 'cpc';
  select id into rid from public.roles where org_id = org and code = p_role;
  insert into auth.users (id, email) values (u, p_role || '-' || u || '@example.test');
  insert into public.persons (id, org_id, display_name) values (per, org, 'Fake ' || p_role);
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (org, pid, rid);
  return u;
end $$;

-- bucket configuration
select is((select public from storage.buckets where id = 'payment-proofs'), false, 'the bucket is private');
select is((select file_size_limit from storage.buckets where id = 'payment-proofs'), 5242880::bigint, 'size limit is 5 MB');
select is(
  (select allowed_mime_types from storage.buckets where id = 'payment-proofs'),
  array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'], 'only images and PDF are allowed');

create temp table fx as select (select id from public.orgs where code = 'cpc') as org;
grant select on fx to public;
create temp table us(role text primary key, u uuid, pid text);
grant select on us to public;
insert into us select r, pg_temp.mk(r), null from unnest(array['member', 'pending_member', 'front_desk', 'admin']) r;
insert into us values ('member2', pg_temp.mk('member'), null);
update us set pid = (select p.id from public.profiles p where p.auth_user_id = us.u);

-- the owner can upload under their own profile folder
select pg_temp.as_user((select u from us where role = 'member'));
set local role authenticated;
select lives_ok(
  format($f$insert into storage.objects (bucket_id, name, owner_id) values ('payment-proofs', %L, %L)$f$,
    (select org from fx) || '/' || (select pid from us where role = 'member') || '/proof-1.png', (select u from us where role = 'member')::text),
  'a member can upload to their own folder');
select throws_ok(
  format($f$insert into storage.objects (bucket_id, name) values ('payment-proofs', %L)$f$,
    (select org from fx) || '/' || (select pid from us where role = 'member2') || '/forged.png'),
  '42501', null, 'a member cannot upload into someone else''s folder');
select throws_ok(
  format($f$insert into storage.objects (bucket_id, name) values ('payment-proofs', %L)$f$,
    core.ulid() || '/' || (select pid from us where role = 'member') || '/other-org.png'),
  '42501', null, 'a member cannot upload under another org');
select is((select count(*)::int from storage.objects where bucket_id = 'payment-proofs'), 1, 'the owner sees their own file');
select throws_ok(
  $$delete from storage.objects where bucket_id = 'payment-proofs'$$, '42501', null, 'the owner cannot delete the file') ;
reset role;
select is((select count(*)::int from storage.objects where bucket_id = 'payment-proofs'), 1, 'the file is still there');

-- others
select pg_temp.as_user((select u from us where role = 'member2'));
set local role authenticated;
select is((select count(*)::int from storage.objects where bucket_id = 'payment-proofs'), 0, 'another member cannot see the file');
reset role;
select pg_temp.as_user((select u from us where role = 'pending_member'));
set local role authenticated;
select throws_ok(
  format($f$insert into storage.objects (bucket_id, name) values ('payment-proofs', %L)$f$,
    (select org from fx) || '/' || (select pid from us where role = 'pending_member') || '/x.png'),
  '42501', null, 'a pending member (no payments.submit) cannot upload');
reset role;
select pg_temp.as_user((select u from us where role = 'front_desk'));
set local role authenticated;
select is((select count(*)::int from storage.objects where bucket_id = 'payment-proofs'), 0, 'front desk (no payments.verify) cannot read proofs');
reset role;
select pg_temp.as_user((select u from us where role = 'admin'));
set local role authenticated;
select is((select count(*)::int from storage.objects where bucket_id = 'payment-proofs'), 1, 'an admin (payments.verify) can read proofs');
update storage.objects set name = name || 'x' where bucket_id = 'payment-proofs';
reset role;
select is((select count(*)::int from storage.objects where bucket_id = 'payment-proofs' and name like '%x'), 0, 'a client update changes nothing (no update policy, so no upsert)');

set local role anon;
select is((select count(*)::int from storage.objects where bucket_id = 'payment-proofs'), 0, 'anon sees nothing in the bucket');
reset role;

select * from finish();
rollback;
