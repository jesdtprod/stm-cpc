# migrations/

One file per change, never edited after it is applied. Kit migrations use numbered names
(`0001_...`); project migrations start at `1000` (DATABASE.md section 16). Apply with
`npx supabase db push --linked`.

| File | Plan step | Adds |
| --- | --- | --- |
| `0001_core_ulid.sql` | 1.1 | `core` schema, `core.ulid()`, `core.is_ulid()`, `core.ulid_time()` |
| `0002_core_helpers.sql` | 1.2 | `attach_standard`, `enable_standard_rls`, stamp / immutable / no-delete / audit triggers, `audit_log`, `write_audit` |
| `0003_core_tenancy_people.sql` | 1.3 | `orgs`, `org_units`, `persons`, `person_relations`, `profiles`, `current_profile_id()` |
| `0004_core_rbac.sql` | 1.4 | `permissions`, `roles`, `role_permissions`, `org_members`, `has_permission()`, policies, seeded catalog and roles |
| `0005_core_operations.sql` | 1.5 | `idempotency_keys`, `counters`, `settings`, `lookups`, `files`, `notifications`, `client_errors` |
| `0006_core_access_hardening.sql` | 1.6 | Default privileges revoked, explicit column-level grants, new objects private by default |
| `0007_advisor_fixes.sql` | 1.7 | Advisor findings resolved |

Tests live in `../tests/` and run with `deno task db:test` (needs a logged-in, linked CLI; no Docker).
