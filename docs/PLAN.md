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
| Initial member password | Last 5 digits of the member ID followed by the birth date as `MMDDYYYY`; must change at first sign-in; does not expire (club decision); safeguards in `CLUB_SCHEMA.md` section 2.2. Replaces the random temporary password rule |
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
| [x] 1B.2 | **Session module** (one file for the whole app): sign-in through `member-login`, token refresh, auth-state events, idle timeout (default 15 minutes), sign-out synced across tabs, logout clears caches and offline queue, gates for forced password change / pending approval / suspended, re-authentication prompt for sensitive actions | Manual and automated checks: idle sign-out works; second tab signs out; gated users reach only allowed pages *Verified live in a browser with temporary fake members (deleted afterwards): idle sign-out after the warning (test switch `?idle=20`), a second tab signed out when the first did and the stored session was cleared, and gated users were checked in 3.4; unit tests cover the rest.* |
| [x] 1B.3 | **Route guards and `can('code')` helper.** Routes are public, signed-in, or permission-based; menu and buttons read permissions | Each role sees only its own menu; direct URL access to a forbidden page is refused |
| [x] 1B.4 | **API layer.** One wrapper for `supabase-js` and RPC calls; ULID generated when a form opens and reused on retries; error mapping to clear messages; request ID | Retrying a call with the same ID creates one record; errors show readable messages *Verified: unit tests show a retry reuses one key and succeeds once; database tests show the same key replays the stored result, a different payload is refused, and approving twice changes nothing (0005 and 1200).* |
| [x] 1B.5 | **Error handling and logging.** Global `error` / `unhandledrejection` handler; rate-limited writes to `client_errors`; no personal data in logs | A forced error appears in `client_errors` once; the user sees a friendly message *Verified live: the same forced error raised twice left exactly one `client_errors` row (no email, page address without parameters) and the member saw the friendly message.* |
| [x] 1B.6 | **Shared utilities.** Client ULID, Asia/Manila date helpers, money formatting, `escapeHtml`, keyset pagination helper, form validation helper | Unit tests pass |
| [x] 1B.7 | **Test accounts** for each role and a small **fake-data seed** (never real members) | Each role can sign in on the dev project and passes the role tests *Dropped by decision: no permanent test accounts in the live project. Role checks use temporary fake members that are deleted afterwards.* |
| [x] 1B.8 | **Storage buckets** for payment proofs: private, size and type limits, RLS on `storage.objects` | Upload by the owner works; another member cannot read the file; wrong file type is refused *Verified live through the Storage API: the owner uploaded and read their own file; a second member could not read, list or sign it; a text file (415), a file over 5 MB (413), a second upload to the same path (409) and an upload into another member's folder (403) were all refused.* |

## Stage 2: Club database and seed data

| ID | Step | Done when |
| --- | --- | --- |
| [x] 2.1 | **Club database design document** (`docs/CLUB_SCHEMA.md`): tables, columns, classes (master, document, ledger), state machines, indexes. **Needs your approval before migrating** | Document approved |
| [x] 2.2 | Migrate members, categories, rank ladders, ranks, rank rules, member ranks, rank history | Migration applies; tests for uniqueness, soft delete, restore, guards |
| [x] 2.3 | Migrate courts, rate rules, operating hours, blackouts, reservations (with the no-overlap constraint), payment submissions, ledger | Concurrent booking test yields exactly one success; ledger is append-only |
| [x] 2.4 | Migrate events, divisions, registrations, stage and format templates, scoring rules, draws, matches, games, score events | Migration applies; constraints and state-machine tests pass |
| [x] 2.5 | Seed settings defaults and lookup lists (fake data only) | Seed is idempotent; advisors show no findings |

## Stage 3: Accounts and access

| ID | Step | Done when |
| --- | --- | --- |
| [x] 3.1 | `member-login` Edge Function (member ID to internal account, Turnstile check, rate limit, lockout, generic errors) | Existing and non-existing IDs give indistinguishable responses; lockout triggers *Verified live: a locked-out real ID and a made-up ID gave the same response; 14 unit tests and the throttle database tests pass.* |
| [x] 3.2 | **Member import** function: validates IDs, keeps existing IDs, first passwords from the club's rule, expiry, `must_change_password`; import report | Re-running the import creates no duplicates; the report shows created, skipped, failed. *Verified live: 1,374 created (1,357 with accounts), re-run created 0; also creates the first admin (`deno task members:create-admin`).* |
| [x] 3.3 | `member-signup` Edge Function for **new members only**: Turnstile, rate limits, honeypot, duplicate flagging, ID assignment, pending status | A claim of an existing ID is rejected; new sign-up lands in pending with no permissions *Verified live: a made-up applicant was created (pending_approval, pending role only, two consents, next member number), signed in with their own password and reached the waiting-for-approval page (then deleted); a request naming a member ID is refused; honeypot, origin, validation and sign-up-off paths covered by tests.* |
| [x] 3.4 | Pages: sign-in, forced password change, profile completion, pending-approval status | A pending user can reach only these pages *Verified live in a browser with a fake member: sign in, forced password change (weak passwords refused), profile with the Province-City-Barangay choices, then the waiting-for-approval page; the old first password stopped working; no horizontal scroll at 375 px.* |
| [x] 3.5 | **Approval flow** (approve, reject, suspend, restore) as permissioned, idempotent, audited RPCs, with the approval screen | Approving twice does nothing new; every action is in `audit_log` *Verified live in a browser with a test admin and a test applicant (both deleted afterwards): the Members page lists and searches by status; approving with an open review flag is refused until the flag is acknowledged, then approves, gives the member role and resolves the flag; suspend and restore switch access off and on; audit_log and the status history hold every step; repeats with the same key replay, and a new key on a member already in the wanted state changes nothing.* |
| [x] 3.6 | **Dashboard with side panel**, menu from permissions, role-aware home | Each role sees the correct home and menu on mobile and desktop *Verified live in a browser with temporary fake members (deleted afterwards): a member sees their own cards and no staff figures or Members menu; an admin sees the approval, proof, booking and event figures and the Members menu; a member held at the password gate sees only Home, profile and password; the side panel becomes a drawer at 375 px (focus moves in, Escape closes, no horizontal scroll); the account menu opens from the keyboard; reloading keeps the current page. Database tests 19/19.* |

## Stage 4: Data-entry screens (admin master data)

Each screen has list, create, edit, soft delete, restore, validation, idempotent saves, skeleton/empty/error states, and follows `UI_DESIGN.md`.

| ID | Step | Done when |
| --- | --- | --- |
| [x] 4.1 | **Settings** (payments, booking, members, events, ranks, general) | Changes are validated, audited, and enforced by the server *Verified live in a browser with a temporary admin (deleted afterwards): the seven tabs load; a value outside the range is stopped by the page and also refused by the database when the page is bypassed (the function and a direct table update); a saved change shows in the audit log with its reason; time zone and member ID format are read-only. Database tests 42/42; the idle timeout setting is read at sign-in (unit tested).* |
| [x] 4.2 | **Categories** (skill levels, ordered) | Categories in use cannot be deleted; codes unique among active *Verified live in a browser with a temporary admin (deleted afterwards): create (code made from the name), a duplicate code refused in plain words, edit (code locked), retire and make active, delete with a reason, restore; a category with a rank ladder has its delete button disabled and the database refuses it. Database tests 19/19 for the new soft delete and restore functions.* |
| [x] 4.3 | **Rank ladders, ranks, rank rules** | Rules editable without code; edge cases tested *Verified live in a browser with a temporary admin and a test category (all deleted afterwards): set up a ladder, add ranks (first one starts), a duplicate code refused in plain words, move a rank, change the starting rank (always exactly one), rename, delete; rules: the club's four H/L bracket rules are listed, create, edit (stay disables the levels box), min above max refused by the database, turn off, delete. Database tests 18/18.* |
| [x] 4.4 | **Courts, rates, operating hours, blackouts** | A court with future bookings cannot be archived *Verified live in a browser with a temporary admin and a test court (all deleted afterwards): court add, edit (status) and delete; opening hours for several days at once, an overlap refused in plain words, ending hours on a date; a rate with centavos; a blackout (Manila times, a backwards range stopped); delete with reason. A court with an upcoming booking cannot be deleted (database tests 13/13).* |
| [x] 4.5 | **Members management:** import screen with report, list and search, profile, status changes, starting rank, soft delete and restore | Import of the real member file works on a fake copy first; statuses follow the lifecycle *Verified live in a browser with temporary members (deleted afterwards; the real import report was left as it was): the Members page now has Archived and Deleted tabs; archive with a reason, delete the record, restore it, and the details window shows the rank and the full status history; the new Member import page shows the last import, the issues that need review (mark one reviewed with a note) and the import history. The member file itself is still imported with the secure import tool, so real data never goes through the browser. Database tests 22/22.* |
| [x] 4.6 | **Staff and role assignment** | Admin can assign roles; users cannot change their own *Verified live in a browser with temporary members (deleted afterwards): the staff list, searching an active member and giving them a role with a reason, changing the role, the roles tab with each role's permissions; the admin's own row has its change button switched off. Database tests 24/24 cover: no self change, the last admin cannot be demoted, inactive members refused, idempotent replay, the audit row with old and new role.* |

## Stage 5: Court booking

| ID | Step | Done when |
| --- | --- | --- |
| [x] 5.1 | Member booking request; admin approval or rejection; expiry of unapproved requests | State machine tests pass; expired requests free the slot *Verified live in a browser with temporary members and a test court (deleted afterwards): a member picks a day and a free time, adds a player, sees the price, and sends the request; the taken slot cannot be clicked; an admin approves it, and the calendar shows it; rules are enforced by the database (hours, window, players, price, slot taken, same ID returns the same booking). Database tests 59/59 + 12/12; an unapproved request expires through a 5-minute job and its slot is freed.* |
| [x] 5.2 | Payment proof upload and admin verification; ledger entries; payment-required setting enforced on the server | Unverified proof never confirms a booking; setting off removes the requirement *Verified live: a GCash payment with a proof photo was uploaded to the private bucket and sent; without the proof the page stops it; the admin opened the proof (signed link), verified the payment and later voided it as a refund; each step is in the ledger. Database tests 38/38: an unverified payment never confirms a booking, the setting makes approval wait for the verified price, no overpaying, no reused reference or proof.* |
| [x] 5.3 | Cancellations, refunds (reversing entries), no-shows, check-in | Cancelling twice is safe; refund appears once in the ledger *Verified live: the member cancelled a request, the admin cancelled a confirmed booking with a reason (its charge was reversed, so the ledger nets to zero), and the payment was voided. Database tests cover cancelling twice (one reversal), the late cancellation fee inside the cut-off, no fee for staff, check-in window, no-show fee and completing.* |
| [x] 5.4 | Calendar and availability view; concurrency and retry tests | Two simultaneous requests give one success; retry returns the same booking *Verified: the day calendar for members (free, taken, closed, past) and for admins (with names), the same slot rules as the server (unit tests 6/6). `deno task db:concurrency` runs the real request function from 4 connections at once: 1 booking succeeds and 3 are refused as just taken, and sending the winner's request again returns the same booking (PASS).* |

## Stage 6: Events and registration

| ID | Step | Done when |
| --- | --- | --- |
| [x] 6.1 | Events and divisions (category plus attributes), event states | Divisions follow the state machine | *Verified: migration 1380 adds the event and division functions (create, edit, open and close registration, complete, cancel; a division copies its format and scoring rule, so a later template edit changes nothing). Database tests 48/48: the state machine refuses invalid moves, a draft cannot open registration without a division, replays return the same row, cancelling twice is safe, an event cancel takes its divisions with it, the app cannot write events directly. Admin Events screen added; not yet checked live in a browser.*
| [x] 6.2 | Registration, eligibility checks, fees and payment setting, approval | Ineligible members are refused on the server | *Verified: migration 1390 adds register_for_event, decide_registration, submit_event_payment and my_event_options. Database tests 60/60 (full suite passes): a member in another category, the wrong gender, under the age group or below the rank band is refused by the server; a staff exception needs a written reason and a member cannot grant one; doubles need an eligible partner who cannot be reused; a full division waitlists or refuses by setting; with the payment setting on, approval waits for the verified fee and a verified payment confirms by itself when approval is off; confirming charges the fee once and creates the entry. Member Events page and admin Registrations list added; not yet checked live in a browser. Staff registering a member has no screen yet (server supports it).*
| [x] 6.3 | Waitlist, withdrawals, refunds | Withdrawal is idempotent; waitlist promotes in order | *Verified: migration 1400 adds withdraw_registration, the waitlist promotion and refund reversals. Database tests 36/36: withdrawing twice is safe (one refund entry pointing at the charge, ledger nets to zero); with c, d, e waiting, each freed place (withdrawal, staff withdrawal, rejection, bigger limit) promotes the oldest first; with approval on, a promoted registration goes back to requested; withdrawal stops once the division is drawn; cancelling a division withdraws and refunds everyone. Member Withdraw button and admin withdraw / waitlist place added; not yet checked live in a browser. Money already paid stays on the account until an admin voids the payment (as for bookings).*

## Stage 7: Tournament engine, simple to complex

| ID | Step | Done when |
| --- | --- | --- |
| [x] 7.1 | Scoring rules, score entry, standings, tiebreaks, one final result per match | Tiebreak tests pass; second finalization is refused or idempotent | *Verified: migration 1410 adds enter_score, finalize_match, forfeit_match, correct_match and stage_standings; 1420 lets scoring rules be deleted with a reason. Database tests 52/52: game rules (win by, cap), only the assigned referee or a scorer can enter, a referee can finalize but not correct, 11-10 is refused as unfinished, finalizing twice returns the same result with one final event, a forfeit gives the rule score 11-0, a correction voids and replaces the match with a reversing event and is refused when it would change an advanced winner, standings split ties by wins then head-to-head among the tied, point difference, points scored and coin toss, and unbroken ties share a place. Scoring rules screen added; match score-entry screens come with the bracket pages (7.3+). Not yet checked live in a browser.*
| [x] 7.2 | **Server-side random draw** (secure seed stored, reproducible, idempotent, audited redraw) | Same seed reproduces the same draw; second run returns the existing draw | *Verified: migration 1430 adds run_draw, redo_draw, verify_draw and the keyed-hash draw order. Database tests 41/41: the order depends only on the seed and entry IDs (same seed, same draw, whatever the listing order; another seed differs); a 256-bit seed is stored with the entrant snapshot; entries are numbered by draw position; a second run returns the existing draw and creates none; the draw waits for registration to close, refuses stage 2, one entry and registrations still waiting for approval; a member cannot run or redo; a redo needs a reason and a key, keeps the old draw as superseded, renumbers entries, voids scheduled matches, is idempotent and audited; once a match has started the draw is final; members cannot read the stored seed. View and run-draw icons and a redo reason window added to the event screen; not yet checked live in a browser.*
| [x] 7.3 | Round robin stage and its bracketing page | Game counts and standings correct for several sizes | *Verified: migration 1460 adds the circle-method schedule, the round robin generator (called by the draw, rebuilt after a redo), stage progress and stage_matches. Database tests 34/34: sizes 2 to 9 give n(n-1)/2 matches with every pair once and nobody twice in a round; five players make 10 matches (each plays 4), four make 6; a redo voids the unplayed matches and rebuilds 10; the first score moves the stage, division and event to in progress and the last result completes the stage; standings for five (wins 4-3-2-1-0, points 44 to 20) and four players (one result by forfeit); members can list matches with names. Bracket page added (standings, matches by round, enter score and finalize, forfeit, correct); not yet checked live in a browser.*
| [x] 7.4 | Single elimination stage (byes, rounds) and page | Correct for power-of-two and other sizes | *Verified: migration 1470 adds the standard bracket order, the layout for any entry count and the single elimination generator (built by the draw, rebuilt after a redo, each winner feeding the next round). Database tests 36/36: sizes 2 to 33 give n-1 matches, ceil(log2 n) rounds, one final and every seed placed once with the byes going to the best seeds; eight players give 4/2/1 matches paired 1v8, 4v5, 2v7, 3v6; five players give 4 matches (one first-round match, three byes); a redo rebuilds the bracket; played through, winners move on round by round and the final completes the stage with the strongest player champion (eight and five players). The bracket page names the rounds and shows the champion; the third-place game is not built yet; not yet checked live in a browser.*
| [x] 7.5 | **Regular (Bracketing):** pool play with dynamic bracket count, crossover knockout | 20 entrants in 4 brackets: 40 pool games, quarterfinals A1 v D1, A2 v D2, B1 v C1, B2 v C2 | *Verified: migration 1480 adds pool play (brackets A, B, C ... by a set count or a target size, round robin in each), set_stage_config, the crossover knockout built when the pools finish (club rule: brackets paired outside in, same finish v same finish, standard tree; any other count falls back to a seeded bracket with byes and says so) and stage_matches with the A1 / D1 labels. Database tests 49/49: 20 entries make 4 brackets of 5 with 40 pool games; the knockout waits for the pools, then has 7 matches with quarterfinals A1 v D1, A2 v D2, B1 v C1, B2 v C2 and the right semifinal pairing; 47 games in all; 6 entries (2 brackets) give A1 v B1, A2 v B2; 9 entries (3 brackets) use the flagged seeded fallback; settings are validated and locked after the draw. Bracket page shows a table and match list per bracket; division settings window added; not yet checked live in a browser. Not built: the admin confirmation of a proposed crossover for odd bracket counts, and the optional third-place game.*
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
