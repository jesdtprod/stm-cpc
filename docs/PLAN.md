# Production Plan ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â Capitol Pickleball Club (CPC) Web App

Step-by-step plan from project setup to launch. It starts with the project setup standard, then the shared foundation, then data entry, and ends with the complex features. Read it with the other documents in this folder:

| Document | Covers |
| --- | --- |
| `FEATURES.md` | What the app does |
| `DATABASE.md` | General database kit |
| `SECURITY.md` | Security rules |
| `TECH_STACK.md` | Technologies and conventions |
| `UI_DESIGN.md` | Visual and interaction standard |

## Working rules

1. **One step at a time.** A step is finished only when its "Done when" check passes and the output has been reviewed.
2. **Paste the output.** After each step, paste the terminal or dashboard output used for verification before the next step starts.
3. **Never paste secrets.** Do not share the `service_role` key, database password, Turnstile secret key, or temporary passwords in chat or in the repository. The project URL and anon key are public.
4. **Database changes are migrations only.** Never edit an applied migration; add a new one. Never change the database by hand without a matching migration.
5. **Every step follows the standards:** `DATABASE.md` for tables, `SECURITY.md` for access and secrets, `UI_DESIGN.md` for screens, `FEATURES.md` for scope.
6. **Commits:** one logical change per commit, with a short message that names the step ID (for example `1.4 RBAC tables and seed`).
7. **Blocked steps** are reported with the reason. They are never skipped silently.
8. **Fake data only** in the repository, tests, and screenshots.

## Fixed decisions

| Topic | Decision |
| --- | --- |
| Frontend | Plain HTML, CSS, vanilla JavaScript, PWA; hosted on GitHub Pages; hash-based routing |
| Backend | Supabase (database, Auth, Edge Functions, Storage) |
| Supabase dev project | `https://iohrwwrkhdkmzxntstuu.supabase.co`; used as **development** until a production project is created |
| CAPTCHA | Cloudflare Turnstile |
| Member ID | `CPC-YYYY-NNNNN` |
| Scope | One club: Capitol Pickleball Club |
| Documents | In the `docs/` folder |
| Initial member password | Last 5 digits of the member ID followed by the birth date as `MMDDYYYY`; must change at first sign-in; expires (default 30 days); safeguards in `CLUB_SCHEMA.md` section 2.2. Replaces the random temporary password rule |
| Existing-member import | Import only ID NO, full name (as display name), birth date, mobile, email and RFID code. Rows without an ID are not imported; rows on duplicated IDs are held back until the club fixes them; a six-digit ID with a leading zero is shortened; duplicated RFID codes are cleared (`CLUB_SCHEMA.md` section 2) |

## Open decisions

| Decision | Needed before | Default if unanswered |
| --- | --- | --- |
| UI language: English only, or English plus Filipino | Step 0.5 | English only |
| Member contact data: email or mobile for resets and notices | Step 3.2 | Mobile number optional; admin-initiated resets |
| Member ID sequence restarts yearly; when a new sign-up receives its ID | Step 3.3 | Yearly restart; ID assigned at sign-up |
| Doubles: team entry and per-member ranking | Step 2.1 | Team of two; rank per member |
| Movement across category boundaries | Step 8.1 | Chained ladders |
| Meaning of "won a bracket" for rank movement | Step 8.1 | Bracket champion |
| Rank movement for round robin, single elimination, and Regular (Bracketing) | Step 8.1 | None until defined |
| Semifinal pairing in Regular (Bracketing) | Step 7.5 | Standard tree order |
| Playing in another category | Step 6.2 | Admin may allow, with a reason |
| Notification channel (in-app, SMS, both) | Step 9.3 | In-app only |

---

## Stage 0: Project setup standard (priority)

| ID | Step | Done when |
| --- | --- | --- |
| [x] 0.1 | **Repository hygiene.** `.gitignore` (env files, dumps, exports, member import file, local Supabase files), project `README.md`, remove any leftover legacy code from the public repository. Turn on GitHub secret scanning and push protection, branch protection on `main`, and 2FA | Settings confirmed; a test secret in a branch is blocked or flagged; `git status` shows no ignored files tracked |
| [x] 0.2 | **Folder structure.** `docs/` (these documents), `web/` (everything published to Pages), `supabase/` (config, migrations, functions, tests), `scripts/`, `.github/workflows/` | Tree matches; each folder has a short note on its purpose |
| [x] 0.3 | **Supabase dev project.** Confirm it is empty (list non-system tables, `auth.users` count, extensions); install and log in to the CLI; `supabase init`; link to project `iohrwwrkhdkmzxntstuu`; create `supabase-config.js` with URL and anon key only | SQL results pasted; `supabase --version` and `supabase link` succeed; config file contains no secret |
| [x] 0.4 | **Tooling and checks.** `deno.json` tasks (lint, format, check); review `check-pos.mjs` and `check-branch-registration.mjs` and rename or replace them; database test setup (pgTAP); GitHub Actions workflow for checks and secret scan | Tasks run locally; workflow is green on a test pull request |
| [x] 0.5 | **Frontend foundation.** Design tokens and base CSS from `UI_DESIGN.md`; app shell with hash router; shared components (table, modal, toolbar, empty state, skeleton, pagination, form fields, badges); meta CSP including Turnstile; PWA manifest and service worker (app shell only) | Shell loads on desktop and mobile; an injected inline script is blocked by CSP; offline shell opens; no authenticated data in the cache |
| [x] 0.6 | **Deployment.** GitHub Pages workflow that publishes only `web/`; HTTPS enforced | Live URL loads; the published files contain nothing from `supabase/`, `scripts/`, or `docs/` |

## Stage 1: Core database kit

| ID | Step | Done when |
| --- | --- | --- |
| [x] 1.1 | `core.ulid()` and the ULID format check | Generated IDs match the format and sort by time; test passes |
| [x] 1.2 | Standard helpers: `attach_standard`, `enable_standard_rls`, immutable-ID, audit-stamp, version, and hard-delete-block triggers | Tests: `id` and `created_*` cannot change; client `DELETE` is refused |
| [x] 1.3 | Tenancy and people: `orgs`, `org_units`, `persons`, `person_relations`, `profiles` | Tables exist with standard columns and RLS; migration applies cleanly |
| [x] 1.4 | **RBAC:** `roles`, `permissions`, `role_permissions`, `org_members`; `core.current_profile_id()` and `core.has_permission()`; seed the permission catalog (`FEATURES.md` Section 3) and default roles (pending member, member, referee, front desk, manager, admin) | Seed applies; `has_permission` returns the right answer for each role in tests |
| [x] 1.5 | Operations tables: `audit_log` (insert-only), `idempotency_keys`, `settings`, `counters`, `lookups`, `files`, `notifications`, `client_errors` | Audit and idempotency behavior tests pass (replay returns stored response; changed payload is rejected) |
| [x] 1.6 | **Access hardening.** Revoke default privileges from `anon` and `authenticated`; RLS policies on every table; block privilege escalation (a user cannot change their own role, unit, or status) | Tests: anonymous access denied; user in one org cannot read another; escalation attempts fail |
| [x] 1.7 | Supabase Security and Performance Advisors; enable backups | No unresolved findings; backup setting confirmed |

## Stage 1B: Foundation services (before any screen)

| ID | Step | Done when |
| --- | --- | --- |
| [x] 1B.1 | **Cloudflare Turnstile.** Create the widget (site key public, secret key private); enable CAPTCHA protection in Supabase Auth with the secret key | Auth requests without a valid token are refused |
| [ ] 1B.2 | **Session module** (one file for the whole app): sign-in through `member-login`, token refresh, auth-state events, idle timeout (default 15 minutes), sign-out synced across tabs, logout clears caches and offline queue, gates for forced password change / pending approval / suspended, re-authentication prompt for sensitive actions | Manual and automated checks: idle sign-out works; second tab signs out; gated users reach only allowed pages |
| [x] 1B.3 | **Route guards and `can('code')` helper.** Routes are public, signed-in, or permission-based; menu and buttons read permissions | Each role sees only its own menu; direct URL access to a forbidden page is refused |
| [ ] 1B.4 | **API layer.** One wrapper for `supabase-js` and RPC calls; ULID generated when a form opens and reused on retries; error mapping to clear messages; request ID | Retrying a call with the same ID creates one record; errors show readable messages |
| [ ] 1B.5 | **Error handling and logging.** Global `error` / `unhandledrejection` handler; rate-limited writes to `client_errors`; no personal data in logs | A forced error appears in `client_errors` once; the user sees a friendly message |
| [x] 1B.6 | **Shared utilities.** Client ULID, Asia/Manila date helpers, money formatting, `escapeHtml`, keyset pagination helper, form validation helper | Unit tests pass |
| [ ] 1B.7 | **Test accounts** for each role and a small **fake-data seed** (never real members) | Each role can sign in on the dev project and passes the role tests |
| [ ] 1B.8 | **Storage buckets** for payment proofs: private, size and type limits, RLS on `storage.objects` | Upload by the owner works; another member cannot read the file; wrong file type is refused |

## Stage 2: Club database and seed data

| ID | Step | Done when |
| --- | --- | --- |
| [ ] 2.1 | **Club database design document** (`docs/CLUB_SCHEMA.md`): tables, columns, classes (master, document, ledger), state machines, indexes. **Needs your approval before migrating** | Document approved |
| [ ] 2.2 | Migrate members, categories, rank ladders, ranks, rank rules, member ranks, rank history | Migration applies; tests for uniqueness, soft delete, restore, guards |
| [ ] 2.3 | Migrate courts, rate rules, operating hours, blackouts, reservations (with the no-overlap constraint), payment submissions, ledger | Concurrent booking test yields exactly one success; ledger is append-only |
| [ ] 2.4 | Migrate events, divisions, registrations, stage and format templates, scoring rules, draws, matches, games, score events | Migration applies; constraints and state-machine tests pass |
| [ ] 2.5 | Seed settings defaults and lookup lists (fake data only) | Seed is idempotent; advisors show no findings |

## Stage 3: Accounts and access

| ID | Step | Done when |
| --- | --- | --- |
| [ ] 3.1 | `member-login` Edge Function (member ID to internal account, Turnstile check, rate limit, lockout, generic errors) | Existing and non-existing IDs give indistinguishable responses; lockout triggers |
| [ ] 3.2 | **Member import** function: validates IDs, keeps existing IDs, random temporary passwords, expiry, `must_change_password`; import report | Re-running the import creates no duplicates; the report shows created, skipped, failed |
| [ ] 3.3 | `member-signup` Edge Function for **new members only**: Turnstile, rate limits, honeypot, duplicate flagging, ID assignment, pending status | A claim of an existing ID is rejected; new sign-up lands in pending with no permissions |
| [ ] 3.4 | Pages: sign-in, forced password change, profile completion, pending-approval status | A pending user can reach only these pages |
| [ ] 3.5 | **Approval flow** (approve, reject, suspend, restore) as permissioned, idempotent, audited RPCs, with the approval screen | Approving twice does nothing new; every action is in `audit_log` |
| [ ] 3.6 | **Dashboard with side panel**, menu from permissions, role-aware home | Each role sees the correct home and menu on mobile and desktop |

## Stage 4: Data-entry screens (admin master data)

Each screen has list, create, edit, soft delete, restore, validation, idempotent saves, skeleton/empty/error states, and follows `UI_DESIGN.md`.

| ID | Step | Done when |
| --- | --- | --- |
| [ ] 4.1 | **Settings** (payments, booking, members, events, ranks, general) | Changes are validated, audited, and enforced by the server |
| [ ] 4.2 | **Categories** (skill levels, ordered) | Categories in use cannot be deleted; codes unique among active |
| [ ] 4.3 | **Rank ladders, ranks, rank rules** | Rules editable without code; edge cases tested |
| [ ] 4.4 | **Courts, rates, operating hours, blackouts** | A court with future bookings cannot be archived |
| [ ] 4.5 | **Members management:** import screen with report, list and search, profile, status changes, starting rank, soft delete and restore | Import of the real member file works on a fake copy first; statuses follow the lifecycle |
| [ ] 4.6 | **Staff and role assignment** | Admin can assign roles; users cannot change their own |

## Stage 5: Court booking

| ID | Step | Done when |
| --- | --- | --- |
| [ ] 5.1 | Member booking request; admin approval or rejection; expiry of unapproved requests | State machine tests pass; expired requests free the slot |
| [ ] 5.2 | Payment proof upload and admin verification; ledger entries; payment-required setting enforced on the server | Unverified proof never confirms a booking; setting off removes the requirement |
| [ ] 5.3 | Cancellations, refunds (reversing entries), no-shows, check-in | Cancelling twice is safe; refund appears once in the ledger |
| [ ] 5.4 | Calendar and availability view; concurrency and retry tests | Two simultaneous requests give one success; retry returns the same booking |

## Stage 6: Events and registration

| ID | Step | Done when |
| --- | --- | --- |
| [ ] 6.1 | Events and divisions (category plus attributes), event states | Divisions follow the state machine |
| [ ] 6.2 | Registration, eligibility checks, fees and payment setting, approval | Ineligible members are refused on the server |
| [ ] 6.3 | Waitlist, withdrawals, refunds | Withdrawal is idempotent; waitlist promotes in order |

## Stage 7: Tournament engine, simple to complex

| ID | Step | Done when |
| --- | --- | --- |
| [ ] 7.1 | Scoring rules, score entry, standings, tiebreaks, one final result per match | Tiebreak tests pass; second finalization is refused or idempotent |
| [ ] 7.2 | **Server-side random draw** (secure seed stored, reproducible, idempotent, audited redraw) | Same seed reproduces the same draw; second run returns the existing draw |
| [ ] 7.3 | Round robin stage and its bracketing page | Game counts and standings correct for several sizes |
| [ ] 7.4 | Single elimination stage (byes, rounds) and page | Correct for power-of-two and other sizes |
| [ ] 7.5 | **Regular (Bracketing):** pool play with dynamic bracket count, crossover knockout | 20 entrants in 4 brackets: 40 pool games, quarterfinals A1 v D1, A2 v D2, B1 v C1, B2 v C2 |
| [ ] 7.6 | **Split single elimination** (H and L brackets) | 16 entrants: 8 Round 1 games, 7 games in each bracket, two champions |
| [ ] 7.7 | Multi-stage pipelines and best-of-N playoffs | A configured multi-stage format runs end to end |
| [ ] 7.8 | Bracketing page for each type, mobile layouts, division finalization | Pages verified at mobile, tablet, desktop |

## Stage 8: Rank engine

| ID | Step | Done when |
| --- | --- | --- |
| [ ] 8.1 | Rank movement applied once per member at division finalization, using the rank rules; history; edge limits | Finalizing twice changes ranks once; 16-entrant split example gives 1 up, 7 retain, 1 retain, 7 down |
| [ ] 8.2 | Corrections after finalization (reversing entries, reapply) and admin overrides with reason | Corrected result produces correct final ranks; overrides are audited |
| [ ] 8.3 | Ranking list and member rank history screens | Lists match `rank_history` |

## Stage 9: Public pages and extras

| ID | Step | Done when |
| --- | --- | --- |
| [ ] 9.1 | **Landing / welcome page** | Loads fast; contains no secrets or personal data |
| [ ] 9.2 | Public views and leaderboard (only what is decided public) | Anonymous users see only the approved columns |
| [ ] 9.3 | Notifications (channel per open decision) | Approvals, booking decisions, and schedules reach members |
| [ ] 9.4 | Reports and PDF: brackets, standings, results, schedules, payments | PDF figures match the screen and active filters |
| [ ] 9.5 | Member profile with history | Members see only their own private data |

## Stage 10: Hardening and launch

| ID | Step | Done when |
| --- | --- | --- |
| [ ] 10.1 | Run the full verification list in `SECURITY.md` Section 19 and the acceptance checklists in every document | All items pass; remaining risks listed |
| [ ] 10.2 | Accessibility, mobile and tablet checks; load and concurrency test | Results recorded |
| [ ] 10.3 | Backup and restore test into a separate project | Restored data verified |
| [ ] 10.4 | Create the **production** Supabase project (separate keys); apply all migrations; configure Auth, Turnstile, buckets, backups | Advisors clean on production |
| [ ] 10.5 | Import the real member list (file kept outside the repository); distribute temporary passwords privately | Import report reviewed; the file and password list are deleted after use |
| [ ] 10.6 | Runbook: go-live, key rotation, force sign-out, incident response, contact list | Runbook written and rehearsed once |
| [ ] 10.7 | Go live; monitor auth failures, function errors, and the audit log for the first weeks | No critical findings |

---

## Definition of done for any step

- The "Done when" check passed and its output was reviewed.
- Tests for the step were added and pass.
- Security and UI standards were followed.
- Nothing secret or real was committed.
- The checkbox in this file is ticked and the related document is updated if behavior changed.
