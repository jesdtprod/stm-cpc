begin;
create extension if not exists pgtap with schema extensions;
-- new functions are private by default (migration 0006); let test roles call pgTAP.
grant execute on all functions in schema extensions to public;
select no_plan();

create temp table fx as select (select id from public.orgs where code = 'cpc') as org;
grant select on fx to public;

-- ---- the seed ran
select cmp_ok((select count(*)::int from public.settings where org_id = (select org from fx) and deleted_at is null), '>=', 25, 'settings are seeded');
select cmp_ok((select count(*)::int from public.lookups where org_id = (select org from fx) and deleted_at is null and type in ('payment_method', 'gender', 'court_surface', 'age_group', 'cancel_reason')), '>=', 21, 'lookup lists are seeded');
select cmp_ok((select count(*)::int from public.scoring_rules where org_id = (select org from fx) and deleted_at is null), '>=', 5, 'scoring rules are seeded');
select cmp_ok((select count(*)::int from public.format_templates where org_id = (select org from fx) and deleted_at is null), '>=', 4, 'format templates are seeded');
select cmp_ok((select count(*)::int from public.categories where org_id = (select org from fx) and code in ('beginner', 'novice', 'intermediate', 'advanced') and deleted_at is null), '>=', 4, 'starter categories are seeded');

-- ---- the defaults the documents promise
select is((select value from public.settings where key = 'timezone' and deleted_at is null), '"Asia/Manila"'::jsonb, 'the business timezone is Asia/Manila');
select is((select value from public.settings where key = 'booking.approval_required' and deleted_at is null), 'true'::jsonb, 'booking approval defaults to on');
select is((select value from public.settings where key = 'payments.required.court_booking' and deleted_at is null), 'false'::jsonb, 'payment for bookings defaults to not required');
select is((select value from public.settings where key = 'booking.request_expiry_hours' and deleted_at is null), '24'::jsonb, 'booking requests expire after 24 hours');
select is((select value from public.settings where key = 'members.auto_approve_imported' and deleted_at is null), 'false'::jsonb, 'imported members are approved manually by default');
select is((select value from public.settings where key = 'members.temp_password_days' and deleted_at is null), '0'::jsonb, 'the first password does not expire (0 days = no expiry)');
select is((select value from public.settings where key = 'session.idle_minutes' and deleted_at is null), '15'::jsonb, 'the idle timeout is 15 minutes');
select ok('CPC-2026-00001' ~ ((select value #>> '{}' from public.settings where key = 'members.id_pattern' and deleted_at is null)), 'the member ID pattern accepts CPC-2026-00001');
select ok('CPC-2026-1' !~ ((select value #>> '{}' from public.settings where key = 'members.id_pattern' and deleted_at is null)), 'and rejects a short number');
select is((select count(*)::int from public.settings where key like 'payments.%' and deleted_at is null and unit_id is null), 5, 'the payment settings are club-wide');

-- ---- ladders: one per category, two ranks each, one starting rank
select is((select count(*)::int from public.rank_ladders l join public.categories c on c.id = l.category_id
  where c.code in ('beginner', 'novice', 'intermediate', 'advanced') and l.deleted_at is null), 4, 'each starter category has one ladder');
select is((select count(*)::int from public.ranks r join public.rank_ladders l on l.id = r.ladder_id join public.categories c on c.id = l.category_id
  where c.code in ('beginner', 'novice', 'intermediate', 'advanced') and r.deleted_at is null), 8, 'with two ranks each');
select is((select count(*)::int from public.ranks r join public.rank_ladders l on l.id = r.ladder_id join public.categories c on c.id = l.category_id
  where c.code in ('beginner', 'novice', 'intermediate', 'advanced') and r.is_starting and r.deleted_at is null), 4, 'and one starting rank per ladder');
select is((select string_agg(r.name, ', ' order by r.sort_order) from public.ranks r join public.rank_ladders l on l.id = r.ladder_id join public.categories c on c.id = l.category_id where c.code = 'novice'),
  'Novice Low, Novice High', 'Novice runs Low then High');
select is((select overflow from public.rank_ladders l join public.categories c on c.id = l.category_id where c.code = 'novice' and l.deleted_at is null), 'chain', 'ladders chain into the next category by default');

-- ---- templates and rules are the club's formats
select is((select jsonb_array_length(stages) from public.format_templates where name = 'Regular (Bracketing)'), 2, 'Regular (Bracketing) is pools then a knockout');
select is((select stages -> 1 -> 'config' ->> 'crossover_method' from public.format_templates where name = 'Regular (Bracketing)'), 'paired_groups_same_rank', 'with the club''s crossover rule');
select is((select stages -> 0 ->> 'stage_type' from public.format_templates where name = 'Split single elimination (H and L)'), 'split_single_elimination', 'the split format is a split single elimination');
select is((select games_to_win from public.scoring_rules where name = 'Best of 3 to 11'), 2::smallint, 'best of 3 needs two games');
select is((select count(*)::int from public.scoring_rules where org_id = (select org from fx) and name = (select value #>> '{}' from public.settings where key = 'events.default_scoring_rule' and deleted_at is null)), 1,
  'the default scoring rule setting names a rule that exists');

-- ---- no people, no member numbers, no courts, no secrets
select is((select count(*)::int from public.settings where value::text ~* '(password|secret|token|service_role|apikey)' and key not like 'members.temp_password_days'), 0, 'no setting holds a secret');
select is((select count(*)::int from public.courts where code in ('beginner', 'novice')), 0, 'the seed adds no courts (the club enters its own)');

-- ---- idempotent: running the seed again changes nothing
create temp table before_counts as select
  (select count(*) from public.settings) as s, (select count(*) from public.lookups) as l,
  (select count(*) from public.scoring_rules) as sr, (select count(*) from public.format_templates) as ft,
  (select count(*) from public.categories) as c, (select count(*) from public.rank_ladders) as rl, (select count(*) from public.ranks) as r;
grant select on before_counts to public;
select lives_ok($$select core.seed_club_defaults()$$, 'the seed can run again');
select lives_ok($$select core.seed_club_defaults()$$, 'and again');
select is((select (s, l, sr, ft, c, rl, r)::text from before_counts),
  (select (
    (select count(*) from public.settings), (select count(*) from public.lookups), (select count(*) from public.scoring_rules),
    (select count(*) from public.format_templates), (select count(*) from public.categories), (select count(*) from public.rank_ladders), (select count(*) from public.ranks)
  )::text), 'row counts are the same after re-running');

-- the seed never overwrites an admin's change
update public.settings set value = '48'::jsonb where key = 'booking.request_expiry_hours' and deleted_at is null;
select core.seed_club_defaults();
select is((select value from public.settings where key = 'booking.request_expiry_hours' and deleted_at is null), '48'::jsonb, 'an admin''s changed setting survives a re-run');

-- ---- access: only service code runs the seed
select is(has_function_privilege('authenticated', 'core.seed_club_defaults()', 'execute'), false, 'clients cannot run the seed');
select is(has_function_privilege('anon', 'core.seed_club_defaults()', 'execute'), false, 'nor anonymous callers');

select * from finish();
rollback;
