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

Tests live in `../tests/` and run with `deno task db:test` (needs a logged-in, linked CLI; no Docker).
