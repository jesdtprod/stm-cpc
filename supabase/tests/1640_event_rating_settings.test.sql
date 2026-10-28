begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as e1, core.ulid() as d1, core.ulid() as d2, core.ulid() as d3, core.ulid() as d4,
  (select id from public.format_templates where stages -> 0 ->> 'stage_type' = 'round_robin' and jsonb_array_length(stages) = 1 and deleted_at is null order by id limit 1) as tpl_rr,
  (select id from public.format_templates where stages -> 0 ->> 'stage_type' = 'pool_play' and deleted_at is null order by id limit 1) as tpl_reg,
  (select id from public.categories where code = 'novice' and deleted_at is null) as cat_novice,
  (select id from public.categories where code = 'advanced' and deleted_at is null) as cat_adv,
  current_date + 30 as day1;
grant select on fx to public;

create function pg_temp.mk(p_role text, p_no text) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := core.ulid(); mid text := core.ulid(); org text := (select id from public.orgs where code = 'cpc');
begin
  insert into auth.users (id, email) values (u, lower(p_no) || '@members.example.test');
  insert into public.persons (id, org_id, display_name) values (per, org, 'Fake ' || p_no);
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (org, pid, (select id from public.roles where org_id = org and code = p_role));
  insert into public.members (id, org_id, person_id, profile_id, member_no) values (mid, org, per, pid, p_no);
  update public.members set status = 'invited' where id = mid;
  update public.members set status = 'pending_approval' where id = mid;
  update public.members set status = 'active' where id = mid;
  return u;
end $$;
create temp table us(role text primary key, u uuid);
grant select on us to public;
insert into us values ('member', pg_temp.mk('member', 'CPC-2026-9701'));
insert into us values ('admin', pg_temp.mk('admin', 'CPC-2026-9702'));
insert into us values ('desk', pg_temp.mk('front_desk', 'CPC-2026-9703'));


select is(has_function_privilege('anon', 'public.create_event(text,text,date,date,text,numeric,timestamptz,timestamptz,boolean,text,boolean)', 'execute'), false, 'anonymous callers cannot create with ranking settings');
select is(has_function_privilege('authenticated', 'core.apply_rank_movement(text,integer)', 'execute'), false, 'members cannot invoke rank movement directly');
select pg_temp.as_user((select u from us where role = 'member')); set local role authenticated;
select throws_ok(format($f$select public.create_event(%L, 'Fake Rating Event', %L, %L, null, 0, null, null, true, %L, false)$f$, (select e1 from fx), (select day1 from fx), (select day1 from fx), (select tpl_rr from fx)), '42501', null, 'members cannot create DUPR events');
reset role;
select pg_temp.as_user((select u from us where role = 'admin')); set local role authenticated;
select lives_ok(format($f$select public.create_event(%L, 'Fake Rating Event', %L, %L, null, 0, null, null, true, %L, false)$f$, (select e1 from fx), (select day1 from fx), (select day1 from fx), (select tpl_rr from fx)), 'admin can create a DUPR draft');
select is((select dupr_rated from public.events where id = (select e1 from fx)), true, 'DUPR setting is saved');
select is((select default_format_template_id from public.events where id = (select e1 from fx)), (select tpl_rr from fx), 'event default template is saved');
select is((select apply_cpc_rank_changes from public.events where id = (select e1 from fx)), false, 'CPC rank setting is independent');
select is((select public.create_event((select e1 from fx), 'Fake Rating Event', (select day1 from fx), (select day1 from fx), null, 0, null, null, true, (select tpl_rr from fx), false) ->> 'replayed'), 'true', 'same settings replay the existing event');
select throws_ok(format($f$select public.create_event(%L, 'Fake Rating Event', %L, %L, null, 0, null, null, false, %L, false)$f$, (select e1 from fx), (select day1 from fx), (select day1 from fx), (select tpl_rr from fx)), 'CP422', null, 'changing DUPR setting under a reused ID is refused');
select throws_ok(format($f$select public.create_event(%L, 'Fake Rating Event', %L, %L, null, 0, null, null, true, %L, true)$f$, (select e1 from fx), (select day1 from fx), (select day1 from fx), (select tpl_rr from fx)), 'CP422', null, 'changing CPC setting under a reused ID is refused');
select throws_ok(format($f$select public.create_event(%L, 'Fake Rating Event', %L, %L, null, 0, null, null, true, %L, false)$f$, (select e1 from fx), (select day1 from fx), (select day1 from fx), (select tpl_reg from fx)), 'CP422', null, 'changing template under a reused ID is refused');
select throws_ok(format($f$select public.create_event(%L, 'Fake Invalid Template', %L, %L, null, 0, null, null, false, %L, true)$f$, core.ulid(), (select day1 from fx), (select day1 from fx), core.ulid()), '22023', null, 'unknown templates are refused');
select throws_ok(format($f$select public.create_event(%L, 'Fake Null Settings', %L, %L, null, 0, null, null, null, null, true)$f$, core.ulid(), (select day1 from fx), (select day1 from fx)), '22023', null, 'null boolean settings are refused');
select lives_ok(format($f$select public.create_division(%L, %L, 'Fake Singles', %L, 'singles', null, null, null, null, 16, %L, null)$f$, (select d1 from fx), (select e1 from fx), (select cat_novice from fx), (select tpl_rr from fx)), 'DUPR draft can have divisions configured');
select throws_ok(format($f$select public.set_event_status(%L, 'registration_open', null)$f$, (select e1 from fx)), '22023', 'DUPR registration is not available yet; account verification must be enabled first', 'DUPR cannot open registration before verification is available');
select lives_ok(format($f$select public.update_event(%L, 'Fake Rating Event', %L, %L, null, 0, null, null, false, %L, false)$f$, (select e1 from fx), (select day1 from fx), (select day1 from fx), (select tpl_reg from fx)), 'draft settings can be changed');
select is((select jsonb_array_length(format_snapshot) from public.divisions where id = (select d1 from fx)), 1, 'changing event default leaves existing division format unchanged');
select is((select public.update_event((select e1 from fx), 'Fake Rating Event', (select day1 from fx), (select day1 from fx), null, 0, null, null, false, (select tpl_reg from fx), false) ->> 'unchanged'), 'true', 'repeated identical updates are no-ops');
select lives_ok(format($f$select public.set_event_status(%L, 'registration_open', null)$f$, (select e1 from fx)), 'normal CPC registration still opens');
select throws_ok(format($f$select public.update_event(%L, 'Fake Rating Event', %L, %L, null, 0, null, null, true, %L, false)$f$, (select e1 from fx), (select day1 from fx), (select day1 from fx), (select tpl_reg from fx)), '22023', 'event ranking and format settings are locked after draft', 'DUPR policy cannot change after draft');
select throws_ok(format($f$select public.update_event(%L, 'Fake Rating Event', %L, %L, null, 0, null, null, false, %L, true)$f$, (select e1 from fx), (select day1 from fx), (select day1 from fx), (select tpl_reg from fx)), '22023', null, 'CPC movement cannot change after draft');
select throws_ok(format($f$select public.update_event(%L, 'Fake Rating Event', %L, %L, null, 0, null, null, false, %L, false)$f$, (select e1 from fx), (select day1 from fx), (select day1 from fx), (select tpl_rr from fx)), '22023', null, 'event default cannot change after draft');
select lives_ok(format($f$select public.update_event(%L, 'Fake Renamed Event', %L, %L, null, 0, null, null, false, %L, false)$f$, (select e1 from fx), (select day1 from fx), (select day1 from fx), (select tpl_reg from fx)), 'other allowed event details remain editable');
select lives_ok(format($f$select public.create_event(%L, 'Fake Legacy Event', %L, %L, null, 0, null, null)$f$, (select d4 from fx), (select day1 from fx), (select day1 from fx)), 'legacy event creation still works');
select is((select dupr_rated from public.events where id = (select d4 from fx)), false, 'legacy events default to CPC only');
select is((select apply_cpc_rank_changes from public.events where id = (select d4 from fx)), true, 'legacy events retain CPC movement');
reset role;
-- Separate fake tenant verifies the template boundary.
create temp table foreign_org as select core.ulid() as id, core.ulid() as tpl;
insert into public.orgs(id, org_id, code, name) select id, id, 'fake_rating_org', 'Fake Rating Organization' from foreign_org;
insert into public.format_templates(id, org_id, name, stages) select tpl, id, 'Fake Foreign Template', '[{"stage_type":"round_robin"}]'::jsonb from foreign_org;
grant select on foreign_org to public;
set local role authenticated;
select throws_ok(format($f$select public.create_event(%L, 'Fake Foreign Template Event', %L, %L, null, 0, null, null, false, %L, true)$f$, core.ulid(), (select day1 from fx), (select day1 from fx), (select tpl from foreign_org)), '22023', null, 'templates from another club are refused');
reset role;
select ok(exists(select 1 from core.audit_log where action = 'event.create' and record_id = (select e1 from fx) and new_values ->> 'dupr_rated' = 'true'), 'DUPR event setup is audited');
select * from finish();
rollback;
