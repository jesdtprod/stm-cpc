begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create function pg_temp.as_user(u uuid) returns void language sql as
$$ select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

create function pg_temp.mk(p_org text, p_role text, p_person text default null) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); pid text := core.ulid(); per text := coalesce(p_person, core.ulid()); rid text;
begin
  select id into rid from public.roles where org_id = p_org and code = p_role;
  insert into auth.users (id, email) values (u, p_role || '-' || u || '@example.test');
  if p_person is null then
    insert into public.persons (id, org_id, display_name) values (per, p_org, 'Fake ' || p_role);
  end if;
  insert into public.profiles (id, org_id, auth_user_id, person_id) values (pid, p_org, u, per);
  insert into public.org_members (org_id, profile_id, role_id) values (p_org, pid, rid);
  return u;
end $$;

create temp table fx as select (select id from public.orgs where code = 'cpc') as org,
  core.ulid() as cat, core.ulid() as lad, core.ulid() as rk0, core.ulid() as rk1, core.ulid() as rk_other, core.ulid() as lad2, core.ulid() as cat2,
  core.ulid() as ev1, core.ulid() as ev2, core.ulid() as dv1, core.ulid() as dv2, core.ulid() as st1,
  core.ulid() as p1, core.ulid() as p2, core.ulid() as p3, core.ulid() as p4, core.ulid() as p5,
  core.ulid() as m1, core.ulid() as m2, core.ulid() as m3, core.ulid() as m4, core.ulid() as m_pending,
  core.ulid() as reg1, core.ulid() as reg2, core.ulid() as reg3, core.ulid() as reg4, core.ulid() as en1, core.ulid() as en2;
grant select on fx to public;

insert into public.persons (id, org_id, display_name) select p, (select org from fx), 'Fake Person ' || n
  from (values ((select p1 from fx), 1), ((select p2 from fx), 2), ((select p3 from fx), 3), ((select p4 from fx), 4), ((select p5 from fx), 5)) v(p, n);
insert into public.members (id, org_id, person_id, member_no, status) values
  ((select m1 from fx), (select org from fx), (select p1 from fx), 'CPC-2026-93001', 'pending_approval'),
  ((select m2 from fx), (select org from fx), (select p2 from fx), 'CPC-2026-93002', 'pending_approval'),
  ((select m3 from fx), (select org from fx), (select p3 from fx), 'CPC-2026-93003', 'pending_approval'),
  ((select m4 from fx), (select org from fx), (select p4 from fx), 'CPC-2026-93004', 'pending_approval'),
  ((select m_pending from fx), (select org from fx), (select p5 from fx), 'CPC-2026-93005', 'pending_approval');
update public.members set status = 'active' where id in ((select m1 from fx), (select m2 from fx), (select m3 from fx), (select m4 from fx));

insert into public.categories (id, org_id, code, name) values ((select cat from fx), (select org from fx), 't-novice', 'T Novice'), ((select cat2 from fx), (select org from fx), 't-inter', 'T Inter');
insert into public.rank_ladders (id, org_id, category_id) values ((select lad from fx), (select org from fx), (select cat from fx)), ((select lad2 from fx), (select org from fx), (select cat2 from fx));
insert into public.ranks (id, org_id, ladder_id, code, name, sort_order) values
  ((select rk0 from fx), (select org from fx), (select lad from fx), 't-low', 'T Low', 0),
  ((select rk1 from fx), (select org from fx), (select lad from fx), 't-high', 'T High', 1),
  ((select rk_other from fx), (select org from fx), (select lad2 from fx), 't-other', 'T Other', 0);

-- ---- structure
select is((select count(*)::int from pg_class where relnamespace = 'public'::regnamespace and relrowsecurity
  and relname in ('entity_events', 'events', 'format_templates', 'scoring_rules', 'divisions', 'division_stages', 'registrations', 'entries', 'entry_members')), 9, 'RLS is on for all nine tables');
select is((select count(*)::int from pg_class c where c.relnamespace = 'public'::regnamespace
  and c.relname in ('entity_events', 'events', 'format_templates', 'scoring_rules', 'divisions', 'division_stages', 'registrations', 'entries', 'entry_members')
  and obj_description(c.oid, 'pg_class') like 'class: %'), 9, 'every table has a class comment');
select is((select count(*)::int from public.role_permissions rp join public.roles r on r.id = rp.role_id join public.permissions pe on pe.id = rp.permission_id
  where r.code = 'manager' and pe.code in ('divisions.manage', 'registrations.manage', 'reports.read')), 3, 'the manager holds the three new permissions');

-- ---- scoring rules and format templates
select lives_ok(format($f$insert into public.scoring_rules (org_id, name) values (%L, 'T Standard')$f$, (select org from fx)), 'a default scoring rule is valid');
select throws_ok(format($f$insert into public.scoring_rules (org_id, name) values (%L, 't standard')$f$, (select org from fx)), '23505', null, 'scoring rule names are unique ignoring case');
select throws_ok(format($f$insert into public.scoring_rules (org_id, name, games_to_win) values (%L, 'bad1', 9)$f$, (select org from fx)), '23514', null, 'games to win is 1 to 5');
select throws_ok(format($f$insert into public.scoring_rules (org_id, name, points_per_game, point_cap) values (%L, 'bad2', 11, 9)$f$, (select org from fx)), '23514', null, 'a point cap cannot be below the game total');
select throws_ok(format($f$insert into public.scoring_rules (org_id, name, tiebreak_order) values (%L, 'bad3', array['luck'])$f$, (select org from fx)), '23514', null, 'tiebreak names are checked');
select throws_ok(format($f$insert into public.scoring_rules (org_id, name, tiebreak_order) values (%L, 'bad4', array['match_wins','match_wins'])$f$, (select org from fx)), '23514', null, 'a tiebreak appears once');

select lives_ok(format($f$insert into public.format_templates (org_id, name, stages) values (%L, 'T Pools then Playoff', '[{"stage_type":"pool_play","config":{"pools":4}},{"stage_type":"single_elimination"}]')$f$, (select org from fx)), 'a valid template is accepted');
select throws_ok(format($f$insert into public.format_templates (org_id, name, stages) values (%L, 'bad', '[{"stage_type":"swiss"}]')$f$, (select org from fx)), '23514', null, 'an unknown stage type is rejected');
select throws_ok(format($f$insert into public.format_templates (org_id, name, stages) values (%L, 'bad', '[]')$f$, (select org from fx)), '23514', null, 'a template needs at least one stage');
select throws_ok(format($f$insert into public.format_templates (org_id, name, stages) values (%L, 'bad', '{"stage_type":"round_robin"}')$f$, (select org from fx)), '23514', null, 'stages must be a list');

-- ---- events
insert into public.events (id, org_id, name, starts_on, ends_on, fee, payload_hash)
  values ((select ev1 from fx), (select org from fx), 'T Open 2026', '2026-12-05', '2026-12-06', 300, repeat('a', 64));
select matches((select doc_no from public.events where id = (select ev1 from fx)), '^EV-20[0-9]{2}-[0-9]{5}$', 'the event number is assigned by the database');
select is((select status from public.events where id = (select ev1 from fx)), 'draft', 'an event starts as a draft');
select throws_ok(format($f$insert into public.events (org_id, name, starts_on, ends_on, payload_hash) values (%L, 'x', '2026-12-06', '2026-12-05', repeat('a', 64))$f$, (select org from fx)), '23514', null, 'an event cannot end before it starts');
select throws_ok(format($f$insert into public.events (org_id, name, starts_on, ends_on, payload_hash, status) values (%L, 'x', '2026-12-05', '2026-12-05', repeat('a', 64), 'in_progress')$f$, (select org from fx)), '22023', null, 'an event cannot be created in progress');
select throws_ok(format($f$insert into public.events (org_id, name, starts_on, ends_on, payload_hash, fee) values (%L, 'x', '2026-12-05', '2026-12-05', repeat('a', 64), -1)$f$, (select org from fx)), '23514', null, 'a fee cannot be negative');
select throws_ok(format($f$insert into public.events (org_id, name, starts_on, ends_on, payload_hash, registration_opens_at, registration_closes_at) values (%L, 'x', '2026-12-05', '2026-12-05', repeat('a', 64), '2026-11-02', '2026-11-01')$f$, (select org from fx)), '23514', null, 'registration must close after it opens');
select throws_ok(format($f$update public.events set status = 'drawn' where id = %L$f$, (select ev1 from fx)), '22023', null, 'a draft cannot jump to drawn');
select throws_ok(format($f$update public.events set doc_no = 'EV-X' where id = %L$f$, (select ev1 from fx)), '42501', null, 'the event number cannot change');
select lives_ok(format($f$update public.events set status = 'registration_open' where id = %L$f$, (select ev1 from fx)), 'draft -> registration_open');

-- ---- divisions
insert into public.divisions (id, org_id, event_id, name, category_id, format, min_rank_id, max_rank_id, format_snapshot, scoring_snapshot, payload_hash)
  values ((select dv1 from fx), (select org from fx), (select ev1 from fx), 'T Novice Singles', (select cat from fx), 'singles', (select rk0 from fx), (select rk1 from fx),
    '[{"stage_type":"round_robin"}]', '{"games_to_win":1,"points_per_game":11}', repeat('b', 64));
select is((select status from public.divisions where id = (select dv1 from fx)), 'open', 'a division starts open');
select throws_ok(format($f$insert into public.divisions (org_id, event_id, name, category_id, format, format_snapshot, scoring_snapshot, payload_hash)
  values (%L, %L, 't novice singles', %L, 'singles', '[{"stage_type":"round_robin"}]', '{}', repeat('b', 64))$f$, (select org from fx), (select ev1 from fx), (select cat from fx)),
  '23505', null, 'a division name is unique within an event');
select throws_ok(format($f$insert into public.divisions (org_id, event_id, name, category_id, format, min_rank_id, format_snapshot, scoring_snapshot, payload_hash)
  values (%L, %L, 'Wrong band', %L, 'singles', %L, '[{"stage_type":"round_robin"}]', '{}', repeat('b', 64))$f$, (select org from fx), (select ev1 from fx), (select cat from fx), (select rk_other from fx)),
  '22023', null, 'the rank band must come from the category''s ladder');
select throws_ok(format($f$insert into public.divisions (org_id, event_id, name, category_id, format, min_rank_id, max_rank_id, format_snapshot, scoring_snapshot, payload_hash)
  values (%L, %L, 'Backwards band', %L, 'singles', %L, %L, '[{"stage_type":"round_robin"}]', '{}', repeat('b', 64))$f$, (select org from fx), (select ev1 from fx), (select cat from fx), (select rk1 from fx), (select rk0 from fx)),
  '22023', null, 'the minimum rank cannot be above the maximum');
select throws_ok(format($f$insert into public.divisions (org_id, event_id, name, category_id, format, format_snapshot, scoring_snapshot, payload_hash)
  values (%L, %L, 'Bad format', %L, 'triples', '[{"stage_type":"round_robin"}]', '{}', repeat('b', 64))$f$, (select org from fx), (select ev1 from fx), (select cat from fx)),
  '23514', null, 'format is singles or doubles');
select throws_ok(format($f$insert into public.divisions (org_id, event_id, name, category_id, format, format_snapshot, scoring_snapshot, payload_hash)
  values (%L, %L, 'Bad snapshot', %L, 'singles', '[{"stage_type":"swiss"}]', '{}', repeat('b', 64))$f$, (select org from fx), (select ev1 from fx), (select cat from fx)),
  '23514', null, 'the format snapshot is validated');
insert into public.divisions (id, org_id, event_id, name, category_id, format, format_snapshot, scoring_snapshot, payload_hash)
  values ((select dv2 from fx), (select org from fx), (select ev1 from fx), 'T Novice Doubles', (select cat from fx), 'doubles', '[{"stage_type":"round_robin"}]', '{}', repeat('c', 64));
select throws_ok(format($f$update public.divisions set format = 'singles' where id = %L$f$, (select dv2 from fx)), '42501', null, 'a division''s format cannot change');
select throws_ok(format($f$update public.divisions set format_snapshot = '[{"stage_type":"pool_play"}]' where id = %L$f$, (select dv2 from fx)), '42501', null, 'the format snapshot is frozen');
select throws_ok(format($f$update public.divisions set status = 'finalized', finalized_at = now() where id = %L$f$, (select dv2 from fx)), '22023', null, 'open cannot jump to finalized');

-- ---- stages
insert into public.division_stages (id, org_id, division_id, stage_no, stage_type, scoring_rule_snapshot)
  values ((select st1 from fx), (select org from fx), (select dv1 from fx), 1, 'round_robin', '{"games_to_win":1}');
select throws_ok(format($f$insert into public.division_stages (org_id, division_id, stage_no, stage_type, scoring_rule_snapshot) values (%L, %L, 1, 'single_elimination', '{}')$f$, (select org from fx), (select dv1 from fx)),
  '23505', null, 'a stage number is unique within a division');
select throws_ok(format($f$insert into public.division_stages (org_id, division_id, stage_no, stage_type, scoring_rule_snapshot) values (%L, %L, 2, 'ladder', '{}')$f$, (select org from fx), (select dv1 from fx)),
  '23514', null, 'the stage type is checked');
select throws_ok(format($f$update public.division_stages set stage_type = 'pool_play' where id = %L$f$, (select st1 from fx)), '42501', null, 'a stage type cannot change');
select throws_ok(format($f$update public.division_stages set status = 'completed' where id = %L$f$, (select st1 from fx)), '22023', null, 'a pending stage cannot be completed');

-- ---- registrations
insert into public.registrations (id, org_id, event_id, division_id, member_id, fee_snapshot, payload_hash)
  values ((select reg1 from fx), (select org from fx), (select ev1 from fx), (select dv1 from fx), (select m1 from fx), 300, repeat('d', 64));
select is((select status from public.registrations where id = (select reg1 from fx)), 'requested', 'a registration starts as requested');
select throws_ok(format($f$insert into public.registrations (org_id, event_id, division_id, member_id, fee_snapshot, payload_hash) values (%L, %L, %L, %L, 300, repeat('d', 64))$f$,
  (select org from fx), (select ev1 from fx), (select dv1 from fx), (select m1 from fx)), '23505', null, 'a member registers once per division while live');
select throws_ok(format($f$insert into public.registrations (org_id, event_id, division_id, member_id, fee_snapshot, payload_hash) values (%L, %L, %L, %L, 300, repeat('d', 64))$f$,
  (select org from fx), (select ev1 from fx), (select dv1 from fx), (select m_pending from fx)), '22023', null, 'only an active member can register');
select throws_ok(format($f$insert into public.registrations (org_id, event_id, division_id, member_id, fee_snapshot, payload_hash) values (%L, %L, %L, %L, 300, repeat('d', 64))$f$,
  (select org from fx), core.ulid(), (select dv1 from fx), (select m2 from fx)), '22023', null, 'the event must be the division''s event');
select throws_ok(format($f$update public.registrations set status = 'rejected' where id = %L$f$, (select reg1 from fx)), '23514', null, 'a rejection needs a reason');
select throws_ok(format($f$update public.registrations set fee_snapshot = 0 where id = %L$f$, (select reg1 from fx)), '42501', null, 'the fee snapshot cannot change');
select lives_ok(format($f$update public.registrations set status = 'withdrawn', status_reason = 'injury' where id = %L$f$, (select reg1 from fx)), 'requested -> withdrawn');
select throws_ok(format($f$update public.registrations set status = 'confirmed' where id = %L$f$, (select reg1 from fx)), '22023', null, 'withdrawn is final');
select lives_ok(format($f$insert into public.registrations (id, org_id, event_id, division_id, member_id, fee_snapshot, payload_hash) values (%L, %L, %L, %L, %L, 300, repeat('e', 64))$f$,
  (select reg2 from fx), (select org from fx), (select ev1 from fx), (select dv1 from fx), (select m1 from fx)), 'after withdrawing, the member can register again');
insert into public.registrations (id, org_id, event_id, division_id, member_id, fee_snapshot, payload_hash)
  values ((select reg3 from fx), (select org from fx), (select ev1 from fx), (select dv1 from fx), (select m2 from fx), 300, repeat('f', 64)),
         ((select reg4 from fx), (select org from fx), (select ev1 from fx), (select dv2 from fx), (select m3 from fx), 300, repeat('0', 64));
update public.registrations set status = 'confirmed' where id in ((select reg2 from fx), (select reg3 from fx), (select reg4 from fx));

-- ---- entries and entry members
select throws_ok(format($f$insert into public.entries (org_id, division_id, registration_id) values (%L, %L, %L)$f$, (select org from fx), (select dv2 from fx), (select reg2 from fx)),
  '22023', null, 'an entry must sit in the same division as its registration');
select throws_ok(format($f$insert into public.entries (org_id, division_id, registration_id) values (%L, %L, %L)$f$, (select org from fx), (select dv1 from fx), (select reg1 from fx)),
  '22023', null, 'an entry needs a confirmed registration');
insert into public.entries (id, org_id, division_id, registration_id, seed) values ((select en1 from fx), (select org from fx), (select dv1 from fx), (select reg2 from fx), 1);
insert into public.entries (id, org_id, division_id, registration_id, seed) values ((select en2 from fx), (select org from fx), (select dv1 from fx), (select reg3 from fx), 2);
select throws_ok(format($f$insert into public.entries (org_id, division_id, registration_id) values (%L, %L, %L)$f$, (select org from fx), (select dv1 from fx), (select reg2 from fx)),
  '23505', null, 'a registration yields one entry');
select throws_ok(format($f$update public.entries set seed = 1 where id = %L$f$, (select en2 from fx)), '23505', null, 'a seed is unique among active entries in a division');
select throws_ok(format($f$update public.entries set registration_id = %L where id = %L$f$, (select reg3 from fx), (select en1 from fx)), '42501', null, 'an entry''s registration cannot change');

insert into public.entry_members (org_id, entry_id, member_id) values ((select org from fx), (select en1 from fx), (select m1 from fx));
select is((select division_id from public.entry_members where entry_id = (select en1 from fx)), (select dv1 from fx), 'the division is copied from the entry');
select throws_ok(format($f$insert into public.entry_members (org_id, entry_id, member_id) values (%L, %L, %L)$f$, (select org from fx), (select en1 from fx), (select m4 from fx)),
  '22023', null, 'a singles entry has one member');
insert into public.entry_members (org_id, entry_id, member_id) values ((select org from fx), (select en2 from fx), (select m2 from fx));
select throws_ok(format($f$insert into public.entry_members (org_id, entry_id, member_id) values (%L, %L, %L)$f$, (select org from fx), (select en2 from fx), (select m_pending from fx)),
  '22023', null, 'entry members must be active (and singles are full)');
select throws_ok($$update public.entry_members set member_id = member_id$$, '42501', null, 'an entry member row cannot be edited');

-- a doubles entry with two members, and the one-active-entry-per-division rule
create temp table dbl as select core.ulid() as en, core.ulid() as en_b;
grant select on dbl to public;
insert into public.entries (id, org_id, division_id, registration_id) values ((select en from dbl), (select org from fx), (select dv2 from fx), (select reg4 from fx));
insert into public.entry_members (org_id, entry_id, member_id) values ((select org from fx), (select en from dbl), (select m3 from fx));
select lives_ok(format($f$insert into public.entry_members (org_id, entry_id, member_id) values (%L, %L, %L)$f$, (select org from fx), (select en from dbl), (select m4 from fx)), 'a doubles entry takes a second member');
select throws_ok(format($f$insert into public.entry_members (org_id, entry_id, member_id) values (%L, %L, %L)$f$, (select org from fx), (select en from dbl), (select m1 from fx)),
  '22023', null, 'a doubles entry has two members at most');
update public.entries set status = 'withdrawn' where id = (select en from dbl);
select throws_ok(format($f$update public.entries set status = 'active' where id = %L$f$, (select en from dbl)), '22023', null, 'a withdrawn entry cannot be reactivated');

-- ---- status history
select cmp_ok((select count(*)::int from public.entity_events where entity_type = 'event' and entity_id = (select ev1 from fx)), '>=', 2, 'event status changes are logged');
select is((select count(*)::int from public.entity_events where entity_type = 'registration' and entity_id = (select reg1 from fx)), 2, 'registration status changes are logged');
select is((select reason from public.entity_events where entity_type = 'registration' and entity_id = (select reg1 from fx) and to_status = 'withdrawn'), 'injury', 'with the reason');
select throws_ok($$update public.entity_events set reason = 'x'$$, '42501', null, 'the history cannot be edited');
select throws_ok(format($f$delete from public.events where id = %L$f$, (select ev1 from fx)), '42501', null, 'an event cannot be hard-deleted');

-- ---- rank tables now point at divisions and events
select is((select count(*)::int from pg_constraint where conname in ('rank_history_division_fk', 'rank_history_event_fk', 'member_ranks_division_fk')), 3, 'rank_history and member_ranks have their foreign keys');
select throws_ok(format($f$insert into public.rank_history (org_id, member_id, to_rank_id, division_id) values (%L, %L, %L, %L)$f$, (select org from fx), (select m1 from fx), (select rk0 from fx), core.ulid()),
  '23503', null, 'rank history must point at a real division');

-- ---- payments can now point at registrations
select lives_ok(format($f$insert into public.payment_submissions (org_id, payer_member_id, source_type, source_id, method, amount, payload_hash) values (%L, %L, 'event_registration', %L, 'cash', 300, repeat('a', 64))$f$,
  (select org from fx), (select m2 from fx), (select reg3 from fx)), 'a payment for a registration is accepted');
select throws_ok(format($f$insert into public.payment_submissions (org_id, payer_member_id, source_type, source_id, method, amount, payload_hash) values (%L, %L, 'event_registration', %L, 'cash', 300, repeat('a', 64))$f$,
  (select org from fx), (select m2 from fx), core.ulid()), '22023', null, 'a payment for a missing registration is refused');

-- ---- row-level security
create temp table us(role text primary key, u uuid);
grant select on us to public;
insert into us values ('admin', pg_temp.mk((select org from fx), 'admin'));
insert into us values ('manager', pg_temp.mk((select org from fx), 'manager'));
insert into us values ('front_desk', pg_temp.mk((select org from fx), 'front_desk'));
insert into us values ('u1', pg_temp.mk((select org from fx), 'member', (select p1 from fx)));
insert into us values ('u2', pg_temp.mk((select org from fx), 'member', (select p2 from fx)));
update public.members set profile_id = (select p.id from public.profiles p where p.auth_user_id = (select u from us where role = 'u1')) where id = (select m1 from fx);
update public.members set profile_id = (select p.id from public.profiles p where p.auth_user_id = (select u from us where role = 'u2')) where id = (select m2 from fx);

insert into public.events (id, org_id, name, starts_on, ends_on, payload_hash) values ((select ev2 from fx), (select org from fx), 'T Draft Event', '2027-01-10', '2027-01-10', repeat('9', 64));

select pg_temp.as_user((select u from us where role = 'u1'));
set local role authenticated;
select is((select count(*)::int from public.events where id = (select ev1 from fx)), 1, 'a member sees a published event');
select is((select count(*)::int from public.events where id = (select ev2 from fx)), 0, 'a member does not see a draft event');
select is((select count(*)::int from public.divisions where event_id = (select ev1 from fx)), 2, 'a member sees the published event''s divisions');
select is((select count(*)::int from public.division_stages), 1, 'and its stages');
select cmp_ok((select count(*)::int from public.scoring_rules), '>=', 1, 'a member reads scoring rules');
select cmp_ok((select count(*)::int from public.format_templates), '>=', 1, 'and format templates');
select is((select count(*)::int from public.registrations where member_id <> (select m1 from fx)), 0, 'a member sees no one else''s registrations');
select is((select count(*)::int from public.registrations where member_id = (select m1 from fx)), 2, 'but sees their own');
select is((select count(*)::int from public.entity_events), 0, 'a member does not read the staff history');
select is((select count(*)::int from public.entries where division_id = (select dv1 from fx)), 0, 'entries are hidden until the draw');
select is((select count(*)::int from public.entry_members where member_id = (select m1 from fx)), 1, 'but a member sees their own entry membership');
select throws_ok(format($f$insert into public.events (org_id, name, starts_on, ends_on, payload_hash) values (%L, 'sneaky', '2027-01-01', '2027-01-01', repeat('1', 64))$f$, (select org from fx)), '42501', null, 'a member cannot create an event');
select throws_ok($$update public.events set status = 'cancelled'$$, '42501', null, 'a member cannot change an event');
select throws_ok(format($f$insert into public.scoring_rules (org_id, name) values (%L, 'sneaky')$f$, (select org from fx)), '42501', null, 'a member cannot add a scoring rule');
reset role;

-- after a draw the entries become visible
update public.divisions set status = 'drawn' where id = (select dv1 from fx);
select pg_temp.as_user((select u from us where role = 'u2'));
set local role authenticated;
select is((select count(*)::int from public.entries where division_id = (select dv1 from fx)), 2, 'entries are visible once the division is drawn');
reset role;

select pg_temp.as_user((select u from us where role = 'manager'));
set local role authenticated;
select is((select count(*)::int from public.events where id = (select ev2 from fx)), 1, 'a manager sees draft events');
select cmp_ok((select count(*)::int from public.registrations), '>=', 4, 'and every registration');
select cmp_ok((select count(*)::int from public.entity_events), '>=', 5, 'and the status history');
select lives_ok(format($f$insert into public.scoring_rules (org_id, name, games_to_win) values (%L, 'T Best of 3', 2)$f$, (select org from fx)), 'a manager adds a scoring rule');
select lives_ok(format($f$insert into public.format_templates (org_id, name, stages) values (%L, 'T Simple RR', '[{"stage_type":"round_robin"}]')$f$, (select org from fx)), 'a manager adds a format template');
select throws_ok($$update public.registrations set status = 'confirmed'$$, '42501', null, 'registrations are changed through RPCs only');
reset role;

select pg_temp.as_user((select u from us where role = 'front_desk'));
set local role authenticated;
select is((select count(*)::int from public.events where id = (select ev2 from fx)), 0, 'front desk does not see draft events');
select throws_ok(format($f$insert into public.scoring_rules (org_id, name) values (%L, 'desk rule')$f$, (select org from fx)), '42501', null, 'front desk cannot add scoring rules');
reset role;

select is((select has_any_column_privilege('authenticated', 'public.events', 'insert') or has_any_column_privilege('authenticated', 'public.divisions', 'update')
  or has_any_column_privilege('authenticated', 'public.registrations', 'insert') or has_any_column_privilege('authenticated', 'public.entries', 'update')), false, 'clients cannot write the document tables');

select * from finish();
rollback;
