begin;
create extension if not exists pgtap with schema extensions;
grant execute on all functions in schema extensions to public;
select no_plan();
select is((select count(*)::int from public.roles where code = 'editor' and deleted_at is null), 1, 'one editor role');
select is(
  (select array_agg(pe.code order by pe.code) from public.role_permissions rp
   join public.roles r on r.id = rp.role_id and r.code = 'editor'
   join public.permissions pe on pe.id = rp.permission_id
   where rp.deleted_at is null and pe.code <> 'members.edit_profile'),
  array['members.read', 'ranks.override'], 'the editor can read members and override ratings, nothing else (members.edit_profile is retired and checked by nothing)');
select is(
  (select count(*)::int from public.role_permissions rp
   join public.roles r on r.id = rp.role_id and r.code = 'manager'
   join public.permissions pe on pe.id = rp.permission_id and pe.code = 'ranks.override'
   where rp.deleted_at is null), 1, 'the manager can override ratings');
select is(
  (select count(*)::int from public.role_permissions rp
   join public.roles r on r.id = rp.role_id and r.code = 'member'
   join public.permissions pe on pe.id = rp.permission_id and pe.code = 'ranks.override'
   where rp.deleted_at is null), 0, 'a plain member cannot override ratings');
select * from finish();
rollback;
