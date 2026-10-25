-- 1420_scoring_rules_admin (PLAN 7.1): the scoring rules screen deletes and restores rules, and (for the formats screen
-- that comes with the bracket pages) format templates, through the shared soft-delete functions.
-- A division and its stages copy a rule when they are created, so deleting a rule never changes a running event.
insert into core.soft_delete_targets (table_name, permission) values
  ('scoring_rules', 'events.manage'),
  ('format_templates', 'brackets.manage')
on conflict (table_name) do nothing;
