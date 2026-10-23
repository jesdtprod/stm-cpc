# scripts/

Repository checks and generators run locally and in CI. No secrets.

| Script | Task | Purpose |
| --- | --- | --- |
| `check-secrets.mjs`, `check-repo.mjs` | `deno task check` | Secret scan and repo hygiene (also in CI) |
| `run-db-tests.mjs` | `deno task db:test [filter]` | Runs `supabase/tests/*.test.sql` against the linked project, each in a rolled-back transaction |
| (CLI) | `deno task db:advisors` | Supabase security and performance advisors; fails on warnings |
| `backup-db.mjs` | `deno task db:backup` | Free-plan backup: every table to JSON under `~/cpc-backups/<timestamp>/` |
| `make-icons.mjs` | | Generates the PWA icons |

## Backups (free plan)

The schema is the migrations in git; `db:backup` captures the data. Run it before every migration
that changes data and at least weekly once real members exist. Keep the folder outside the repository
(it holds member data) and copy it somewhere off this computer. `auth.users` is exported without password
hashes, so after a restore members reset their passwords. A restore drill (new project, apply
migrations, load the JSON with triggers disabled) is plan step 10.3. Upgrading to the Pro plan adds
daily backups and optional point-in-time recovery.
