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

Tests live in `../tests/` and run with `deno task db:test` (needs a logged-in, linked CLI; no Docker).
