-- 1060_seed_defaults (PLAN 2.5)
-- Club-level defaults: settings, lookup lists, scoring rules, format templates, and a starter set of
-- skill categories with rank ladders. Fake or generic data only: no people, no member numbers, no courts
-- (the club enters its real courts, hours and rates). Every value below is a default the admin can change
-- in the app; the seed never overwrites a row that already exists (ON CONFLICT DO NOTHING), so re-running
-- it, or running it again from a later migration after adding rows here, is safe.

create or replace function core.seed_club_defaults() returns void
language plpgsql set search_path = '' as $$
declare
  org text;
begin
  select id into org from public.orgs where code = 'cpc' and deleted_at is null;
  if org is null then
    raise exception 'the cpc organization does not exist; run core.seed_catalog() first';
  end if;

  -- Settings (FEATURES section 10 and CLUB_SCHEMA decisions D5, D8).
  insert into public.settings (org_id, key, value)
  select org, v.key, v.value from (values
    ('timezone', '"Asia/Manila"'::jsonb),
    ('club.name', '"Capitol Pickleball Club"'),
    ('members.id_prefix', '"CPC"'),
    ('members.id_pattern', '"^CPC-\\d{4}-\\d{5}$"'),
    ('members.signup_enabled', 'true'),
    ('members.auto_approve_imported', 'false'),
    ('members.temp_password_days', '30'),
    ('session.idle_minutes', '15'),
    ('booking.approval_required', 'true'),
    ('booking.slot_minutes', '60'),
    ('booking.advance_days', '14'),
    ('booking.max_participants', '4'),
    ('booking.request_expiry_hours', '24'),
    ('booking.cancel_cutoff_hours', '24'),
    ('booking.cancel_fee', '0'),
    ('booking.no_show_fee', '0'),
    ('payments.required.court_booking', 'false'),
    ('payments.required.event_registration', 'false'),
    ('payments.methods', '["cash", "gcash", "maya", "bank_transfer"]'),
    ('payments.proof_required_non_cash', 'true'),
    ('payments.instructions', '""'),
    ('events.default_scoring_rule', '"Single game to 11"'),
    ('events.registration_approval_required', 'true'),
    ('events.waitlist_enabled', 'true'),
    ('ranks.movement_enabled', 'true')
  ) as v(key, value)
  on conflict (org_id, (coalesce(unit_id, '')), key) where deleted_at is null do nothing;

  -- Lookup lists the pages offer in drop-downs.
  insert into public.lookups (org_id, type, code, label, sort)
  select org, v.type, v.code, v.label, v.sort from (values
    ('payment_method', 'cash', 'Cash', 1),
    ('payment_method', 'gcash', 'GCash', 2),
    ('payment_method', 'maya', 'Maya', 3),
    ('payment_method', 'bank_transfer', 'Bank transfer', 4),
    ('payment_method', 'other', 'Other', 5),
    ('gender', 'male', 'Male', 1),
    ('gender', 'female', 'Female', 2),
    ('court_surface', 'acrylic', 'Acrylic', 1),
    ('court_surface', 'concrete', 'Concrete', 2),
    ('court_surface', 'cushioned', 'Cushioned', 3),
    ('court_surface', 'wood', 'Wood', 4),
    ('age_group', 'open', 'Open', 1),
    ('age_group', 'juniors', 'Juniors (under 18)', 2),
    ('age_group', 'seniors_35', 'Seniors 35+', 3),
    ('age_group', 'seniors_50', 'Seniors 50+', 4),
    ('age_group', 'seniors_60', 'Seniors 60+', 5),
    ('cancel_reason', 'member_request', 'Requested by the member', 1),
    ('cancel_reason', 'weather', 'Weather', 2),
    ('cancel_reason', 'court_maintenance', 'Court maintenance', 3),
    ('cancel_reason', 'club_event', 'Club event', 4),
    ('cancel_reason', 'other', 'Other', 5)
  ) as v(type, code, label, sort)
  on conflict (org_id, type, code) where deleted_at is null do nothing;

  -- Scoring rules (games to win, points per game, win by, cap, forfeit score).
  insert into public.scoring_rules (org_id, name, games_to_win, points_per_game, win_by, point_cap, forfeit_score)
  select org, v.name, v.games_to_win, v.points, v.win_by, v.cap, v.forfeit from (values
    ('Single game to 11', 1, 11, 2, null::integer, 11),
    ('Best of 3 to 11', 2, 11, 2, null, 11),
    ('Single game to 15', 1, 15, 2, null, 15),
    ('Best of 3 to 15', 2, 15, 2, null, 15),
    ('Quick game to 11, win by 1', 1, 11, 1, null, 11)
  ) as v(name, games_to_win, points, win_by, cap, forfeit)
  on conflict (org_id, (lower(name))) where deleted_at is null do nothing;

  -- Format templates: the formats the club described (FEATURES section 9).
  insert into public.format_templates (org_id, name, description, stages)
  select org, v.name, v.description, v.stages::jsonb from (values
    ('Round robin', 'Everyone plays everyone once.',
      '[{"stage_type": "round_robin", "config": {}}]'),
    ('Single elimination', 'Knockout bracket with byes when the count is not a power of two.',
      '[{"stage_type": "single_elimination", "config": {"third_place_game": false}}]'),
    ('Regular (Bracketing)', 'Pools A, B, C... play a round robin, the best two of each advance to a crossover knockout.',
      '[{"stage_type": "pool_play", "config": {"advance_per_group": 2, "group_assignment": "random"}},
        {"stage_type": "single_elimination", "config": {"crossover_method": "paired_groups_same_rank", "advance_tree": "standard", "third_place_game": false}}]'),
    ('Split single elimination (H and L)', 'Round 1 for everyone, then winners continue in the H bracket and losers in the L bracket.',
      '[{"stage_type": "split_single_elimination", "config": {"split_after_round": 1, "bracket_labels": ["H", "L"], "reseed_method": "by_previous_order", "bye_goes_to": "H", "third_place_game": false}}]')
  ) as v(name, description, stages)
  on conflict (org_id, (lower(name))) where deleted_at is null do nothing;

  -- Starter categories (skill levels). The club renames, reorders or replaces them in the app.
  insert into public.categories (org_id, code, name, sort_order)
  select org, v.code, v.name, v.sort from (values
    ('beginner', 'Beginner', 1),
    ('novice', 'Novice', 2),
    ('intermediate', 'Intermediate', 3),
    ('advanced', 'Advanced', 4)
  ) as v(code, name, sort)
  on conflict (org_id, code) where deleted_at is null do nothing;

  -- One ladder per category, chained to the next category by default (FEATURES section 8).
  insert into public.rank_ladders (org_id, category_id, overflow)
  select org, c.id, 'chain' from public.categories c
  where c.org_id = org and c.deleted_at is null and c.code in ('beginner', 'novice', 'intermediate', 'advanced')
  on conflict (category_id) where deleted_at is null do nothing;

  -- Two ranks per ladder (Low, High); Low is the default starting rank.
  insert into public.ranks (org_id, ladder_id, code, name, sort_order, is_starting)
  select org, l.id, c.code || '-' || r.level, c.name || ' ' || r.label, r.ord, r.ord = 0
  from public.rank_ladders l
  join public.categories c on c.id = l.category_id
  cross join (values ('low', 'Low', 0), ('high', 'High', 1)) as r(level, label, ord)
  where l.org_id = org and l.deleted_at is null and c.deleted_at is null
    and c.code in ('beginner', 'novice', 'intermediate', 'advanced')
  on conflict (ladder_id, code) where deleted_at is null do nothing;
end $$;
revoke all on function core.seed_club_defaults() from public, anon, authenticated;
grant execute on function core.seed_club_defaults() to service_role;

select core.seed_club_defaults();
