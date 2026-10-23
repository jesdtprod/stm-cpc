# migrations/

One file per change, never edited after it is applied. Kit migrations use numbered names
(`0001_...`); project migrations start at `1000` (DATABASE.md section 16). Apply with
`npx supabase@2.118.0 db push --linked` (2.122.0 shipped without its Windows binary; stay on 2.118.0 until fixed).

| File | Plan step | Adds |
| --- | --- | --- |
| `0001_core_ulid.sql` | 1.1 | `core` schema, `core.ulid()`, `core.is_ulid()`, `core.ulid_time()` |
| `0002_core_helpers.sql` | 1.2 | `attach_standard`, `enable_standard_rls`, stamp / immutable / no-delete / audit triggers, `audit_log`, `write_audit` |
| `0003_core_tenancy_people.sql` | 1.3 | `orgs`, `org_units`, `persons`, `person_relations`, `profiles`, `current_profile_id()` |
| `0004_core_rbac.sql` | 1.4 | `permissions`, `roles`, `role_permissions`, `org_members`, `has_permission()`, policies, seeded catalog and roles |
| `0005_core_operations.sql` | 1.5 | `idempotency_keys`, `counters`, `settings`, `lookups`, `files`, `notifications`, `client_errors` |
| `0006_core_access_hardening.sql` | 1.6 | Default privileges revoked, explicit column-level grants, new objects private by default |
| `0007_advisor_fixes.sql` | 1.7 | Advisor findings resolved |
| `0009_my_profile.sql` | 1B | `my_profile()` for the session module |
| `1000_members.sql` | 2.2 | `members`, `member_access`, `member_status_events`, import tables, `consents`, `core.add_permission` |
| `1005_psgc_address.sql` | 2.2 | `psgc_areas` (data loaded by `deno task db:seed-psgc`), address columns on `persons` |
| `1006_persons_address_update.sql`, `1007_persons_address_fix.sql` | 2.2 | Address trigger: re-derive on update; typed-literal fix |
| `1010_categories_ranks.sql` | 2.2 | `categories`, `rank_ladders`, `ranks`, `rank_rules`, `member_ranks`, `rank_history`, rule-condition validator |
| `1020_courts_bookings.sql` | 2.3 | `courts`, `court_hours`, `court_rates`, `court_blackouts`, `bookings` (exclusion constraint), `booking_participants`, `booking_events`, `court_availability()` |
| `1030_payments_ledger.sql` | 2.3 | `payment_submissions`, `ledger_accounts`, `ledger_entries` (append-only), `ledger_balances` and `source_payment_totals` views |
| `1040_events_tournaments.sql` | 2.4 | `events`, `format_templates`, `scoring_rules`, `divisions`, `division_stages`, `registrations`, `entries`, `entry_members`, `entity_events`; foreign keys from the rank tables; event-registration payments |
| `1050_matches_scores.sql` | 2.4 | `draws`, `matches`, `match_games`, `score_events`, `division_results` |
| `1060_seed_defaults.sql` | 2.5 | `core.seed_club_defaults()`: settings, lookup lists, scoring rules, format templates, starter categories and ranks (never overwrites; safe to re-run) |
| `1070_login_throttle.sql` | 3.1 | `core.login_throttle` (hashed failure counters), lockout helpers, `member_login_state`, `member_login_succeeded`; service-only wrappers in `public` |
| `1080_member_import.sql` | 3.2 | Import batch, member and admin creation functions (service-only), `import_authorized` |
| `1090_import_issue_dedupe.sql` | 3.2 | A re-run does not copy open issues |
| `1100_member_account_flow.sql`, `1120_fix_update_my_profile.sql` | 3.4 | `my_access_state()`, `update_my_profile()`, first sign-in -> invited, password-changed hook; pending approval once the password is changed and the profile is complete |
| `1110_import_reassign.sql`, `1130_import_id_conflicts.sql` | 3.2 | Rows that share a member ID get new numbers from the yearly sequence (never one the file uses); a number held by a different person is not skipped |
| `1140_my_access_state_profile.sql` | 3.4 | `my_access_state()` also returns the member's own contact details and address codes for the profile form |
| `1150_profile_details.sql` | 3.4 | Middle name, suffix, gender and emergency contact on `persons`; `update_my_profile` and `my_access_state` carry them (null keeps, empty string clears) |
| `1160_member_signup.sql`, `1170_fix_signup_create.sql` | 3.3 | `member_review_flags` (possible duplicates, minors), `signup_enabled()`, `signup_allocate_member_no()`, `signup_create()`; consent versions in settings |
| `1180_no_password_expiry.sql` | 3.2 | First passwords do not expire (club decision): cleared existing expiries, setting `members.temp_password_days` = 0 |
| `1190_import_enrich.sql` | 3.4 | Fills empty name, gender and emergency-contact fields for imported members without overwriting; finds reassigned members |
| `1200_member_approval.sql` | 3.5 | `decide_member(action, member, reason, key, ...)`: approve, reject, reconsider, suspend, restore; permissioned, idempotent, audited; rejected members can be reconsidered |
| `1210_my_dashboard.sql` | 3.6 | `my_dashboard()`: the figures behind the role-aware home; each section appears only when the caller holds the matching permission |
| `1220_fix_my_dashboard.sql` | 3.6 | Fix to 1210: `events` has no `deleted_at` |
| `1230_settings_rules.sql` | 4.1 | Per-key setting rules (`setting_valid`) and `update_setting(key, value, reason, idem)`: permissioned, idempotent, audited; timezone and member ID format are read-only from the app |
| `1240_settings_readonly_prefix.sql` | 4.1 | Member ID prefix is read-only too |
| `1250_soft_delete_restore.sql` | 4.2 | `soft_delete(table, id, reason, key)` and `restore_row(table, id, key)` for the master tables listed in `core.soft_delete_targets` (permissioned, idempotent, audited) |
| `1260_rank_ladder_functions.sql` | 4.3 | `reorder_ranks(ladder, ids, key)` and `set_starting_rank(rank, key)` (whole-ladder changes in one step) and the club's four split-bracket rank rules, seeded once |
| `1270_courts_admin.sql` | 4.4 | Courts, hours, rates and blackouts join `soft_delete` / `restore_row`; a court with upcoming bookings cannot be deleted |
| `1280_members_admin.sql` | 4.5 | `archive_member`, `resolve_import_issue`; members join `soft_delete` / `restore_row` (only archived, rejected or never-signed-in members with nothing upcoming) |

Tests live in `../tests/` and run with `deno task db:test` (needs a logged-in, linked CLI; no Docker).
