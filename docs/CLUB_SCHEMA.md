# Club Database Design — Capitol Pickleball Club (CPC)

Plan step 2.1. **Status: draft for approval.** No migration is written until this document is approved (Section 10). It builds on the core kit already applied (migrations `0001`–`0009`): ULID keys, standard columns, `attach_standard`, RLS with permission codes, `audit_log`, idempotency, `settings`, `lookups`, `files`, `notifications`, `client_errors`.

## 1. Conventions (inherited from the core kit)

- Every table: ULID `id`, `org_id` (always the CPC org), `created_*`, `updated_*`, `version`, `meta`; master tables add `deleted_*`. `attach_standard(table, kind)` and RLS are applied in the same migration as the table.
- Class per table: **master** (soft delete), **document** (status machine, cancel/void, `payload_hash`), **ledger/log** (append-only). No hard deletes, no cascades.
- Writes to documents, ledgers, ranks, scores and payments go through RPCs only; clients get no direct `INSERT/UPDATE` there. Master tables edited by admins get column-level grants (`core.grant_client_dml`).
- Money is `numeric(12,2)` in PHP; instants are `timestamptz`; business dates use `Asia/Manila`.
- Migrations for this design use the project range: `1000_…` and up (DATABASE.md section 16).
- Names: `snake_case`, plural tables, `_id` foreign keys. Constraint names include the table.

## 2. Existing-member import

The club's file (kept outside the repository, never committed) is a form-responses sheet with 1,815 rows and 19 columns. **The club decided to import only these fields:**

| Spreadsheet column | Goes to | Notes |
| --- | --- | --- |
| ID NO | `members.member_no` | Pattern `^CPC-\d{4}-\d{5}$` (a setting) |
| Full Name | `persons.display_name` | Used as the display name; the name-part columns are empty in the file |
| Date of Birth | `persons.date_of_birth` | Needed for the initial password (Section 2.2) and kept on the person |
| Mobile Number | `persons.mobile` | Normalized to `09XXXXXXXXX` when possible, otherwise stored as typed |
| Email Address | `persons.email` | Optional; left empty when it does not look like an email |
| RFID CODE | `members.rfid_code` | Unique among active members |

**Not imported:** Gender, Complete Address, Emergency Contact (name, relationship, number), Player Category, Playing Level, PRINTED, Photo, Lastname, Firstname, Middlename, Suffix. They can be added later by members or by another import run.

### 2.1 Import outcomes

The import is an Edge Function run by an admin with `members.import`. It is idempotent: re-running creates nothing twice, and rows the club fixes in Excel are picked up on the next run. Every outcome is audited and listed in a private report that holds row numbers and codes, not member data.

| Row condition (in this sheet) | Outcome |
| --- | --- |
| No `ID NO` (388 rows) | **Not imported**; counted in the report |
| `ID NO` used on more than one row (26 IDs on 53 rows) | **All rows on that ID are held back** and listed as `duplicate_member_no`. The club fixes the IDs in Excel later; the next run imports them |
| `ID NO` with six digits and one leading zero (one row) | Shortened to five digits (`CPC-2026-0nnnnn` → `CPC-2026-nnnnn`) if that ID is free; reported as `member_no_normalized` |
| Any other `ID NO` that does not match the pattern | Held back as `invalid_member_no` |
| RFID code used by more than one row (3 codes, 6 rows) | The code is **removed from every row that holds it**; reported as `duplicate_rfid_cleared`. The club re-enters the right one later |
| Birth date missing, unreadable or outside 1920 to this year (15 rows) | Member created **without an account**; reported as `invalid_birth_date`. An admin enters the date, then the account is created |
| Email that does not look like an email (23 rows) | Imported with no email; reported as `invalid_email` |
| Everything else | Created: person, member (`imported`), profile, auth account, `org_members` link with the pending role |

Birth dates stored as dates are read as is; text dates are read as month/day/year, the club's format. Expected result for this file: **1,374 members imported** (1,359 with an account, 15 waiting for a birth date), 53 rows held back, 388 not imported.

### 2.2 Credentials (decision: club rule with safeguards)

- Username: the member ID, trimmed and uppercased. Initial password: the **last 5 digits of the ID followed by the birth date as `MMDDYYYY`**. Example: `CPC-2026-00001` born 12/21/2025 → `0000112212025` (13 characters).
- The password is computed inside the Edge Function and handed straight to the Supabase Admin API. It is never stored in a table, a log, the import report, or the repository.
- Safeguards, enforced by `member-login` (step 3.1): `must_change_password = true` until the first change; the initial password **expires** after `members.temp_password_days` (default 30) and then only an admin reset works; Turnstile on every attempt; lockout after repeated failures per member ID and per address; generic error messages that do not reveal whether an ID exists.
- This replaces the "random temporary password" rule in FEATURES 4.2 and SECURITY. Both documents are updated when this design is approved. Known trade-off: anyone who knows a member's ID and birth date can sign in before the member does; the safeguards limit that, they do not remove it.
- Internal Auth email: `<member_no lowercased>@members.cpc.app` (decision D6). Never shown, never emailed.

## 3. Changes to core tables

| Table | Change |
| --- | --- |
| `persons` | Add address columns (D10): `street_line`, `barangay_code`, `city_muni_code`, `province_code` (null for Metro Manila), `region_code`, plus a text snapshot `address_text`. Not imported from the file; entered by members and admins |
| `org_members` | None. The pending role (`pending_member`) is the access gate until approval |

## 4. Tables

Permission codes are from the seeded catalog; **new codes** are listed in Section 7.

### 4.1 Members

Migration 1720 adds optional `self_assessed_rank_id` (FK to ranks), `self_assessment_version`, `self_assessment_source`, `self_assessed_at`, `self_assessed_by` (FK to profiles), and `self_assessment_reason` to the existing master `members` table. Existing RLS and RPC-only writes remain. Migration 1730 permits one eligible owner submission; later updates/clears require `ranks.override` and a reason. The getter reports lock/source/origin and shows the existing official rank as a read-only fallback when no estimate was saved, without changing stored data. Members cannot clear or replace a saved/admin assessment; admin clearing keeps the owner locked. The estimate stays independent of `member_ranks`, with versions, idempotency keys and append-only audit entries.

| Table | Class | Purpose and key columns |
| --- | --- | --- |
| `members` | master | One row per club member. `person_id` (unique), `profile_id` (unique, null until the account exists), `member_no` (not null, unique among active), `status` (`imported, invited, pending_approval, active, rejected, suspended, archived`), `status_reason`, `joined_on date`, `rfid_code` (partial unique), `import_batch_id`, `import_row int`. Indexes on `status`, `person_id`, `profile_id`. Minors are found from `persons.date_of_birth` |
| `member_access` | master | 1:1 with `members`, service-written only: `must_change_password`, `temp_password_expires_at`, `last_login_at`, `failed_attempts`, `locked_until`. Holds no password and no secret. Not readable by clients except the member's own `must_change_password` through an RPC |
| `member_status_events` | log | Append-only history: `member_id`, `from_status`, `to_status`, `reason`, `actor`, `occurred_at` |
| `import_batches` | document | One per import run: `file_sha256`, `row_count`, `created_count`, `skipped_count`, `held_back_count`, `failed_count`, `status` (`running, completed, failed`), `started_by`. No member data inside |
| `member_import_issues` | master | `batch_id`, `member_id` (null for held-back rows), `source_row`, `member_no_claimed`, `issue_code` (`duplicate_member_no, invalid_member_no, member_no_normalized, invalid_birth_date, duplicate_rfid_cleared, invalid_email`), `detail` (no personal data), `resolved_at/by`. Drives the admin review screen |
| `consents` | log | Append-only: `person_id`, `kind` (`waiver, privacy`), `doc_version`, `accepted_at`, `accepted_by_person_id` (the guardian for minors) |

Guardians use `person_relations` (`guardian`). RLS: members read only their own `members`, `persons` and consent rows; `members.read` sees all; writes are RPCs (`members.update`, `members.approve`, `members.suspend`).

### 4.2 Categories and ranks

| Table | Class | Purpose and key columns |
| --- | --- | --- |
| `categories` | master | Skill levels: `code` (unique among active), `name`, `description`, `sort_order`, `is_active`, `eligibility_notes`. Retired (not deleted) when in use |
| `rank_ladders` | master | One per category: `category_id` (unique), `overflow` (`chain`, `stop`), `is_active` |
| `ranks` | master | Ordered ranks in a ladder: `ladder_id`, `name`, `code`, `sort_order`, unique `(ladder_id, sort_order)` among active; `is_starting` marks the default start |
| `rank_rules` | master | Movement rules as data: `name`, `conditions jsonb` (validated: `placement`, `bracket_tier`, `bracket_result`, `min_matches`), `action` (`up, down, retain`), `levels int`, `min_rank_id`, `max_rank_id`, `cooldown_days`, `exclude_forfeits`, `priority`, `is_active` |
| `member_ranks` | master | One current rank per member: `member_id` (unique), `rank_id`, `set_by_rule_id`, `source_division_id`. Written only by the rank-engine RPC |
| `rank_history` | log | Append-only: `member_id`, `from_rank_id`, `to_rank_id`, `rule_id`, `division_id`, `event_id`, `reason`, `reverses_id`. **Unique `(division_id, member_id)` where `reverses_id is null`**, so a division cannot move a member twice |

Permissions: `categories.manage`, `ranks.manage`, `ranks.override`. Members read categories, ladders and ranks, and their own rank history.

### 4.3 Courts, bookings and payments

| Table | Class | Purpose and key columns |
| --- | --- | --- |
| `courts` | master | `name`, `code`, `status` (`available, maintenance, closed`), `surface`, `indoor boolean`, `notes`, `file_id` (photo), `sort_order` |
| `court_hours` | master | Operating hours: `court_id` (null = all), `weekday 0–6`, `opens_at time`, `closes_at time`, effective-dated (`valid_from`, `valid_to`) |
| `court_rates` | master | Effective-dated price rules, never edited: `court_id` (null = all), `weekday` (null = all), `from_time`, `to_time`, `rate_per_hour numeric(12,2)`, `valid_from`, `valid_to`. The booking copies the result |
| `court_blackouts` | master | `court_id` (null = all), `during tstzrange`, `reason`. Checked by the booking RPC |
| `bookings` | document | `doc_no` (from `counters`, series `booking-YYYY`), `court_id`, `requested_by_member_id`, `during tstzrange` (half-open), `status` (`pending_approval, confirmed, checked_in, completed, rejected, cancelled, no_show, expired`), `payload_hash`, `rate_snapshot`, `price_snapshot`, `court_name_snapshot`, `expires_at`, `approved_at/by`, `cancelled_at/by/reason`, `checked_in_at/by`. **Exclusion constraint** `(court_id with =, during with &&) where status in ('pending_approval','confirmed','checked_in')` (needs `btree_gist`) |
| `booking_participants` | document | `booking_id`, `member_id`, unique `(booking_id, member_id)`. Every participant must be an active member |
| `booking_events` | log | Append-only state changes with actor and reason (the kit's `entity_events` pattern) |
| `payment_submissions` | document | `doc_no`, exactly one of `payer_member_id` / guest `payer_person_id`, `payer_name_snapshot` for guest review, `source_type` (`booking`, `event_registration`), `source_id`, `method`, `reference_no`, `amount numeric(12,2)`, `file_id` (proof), `status` (`submitted, verified, rejected, void`), `verified_by/at`, `reject_reason`, `payload_hash`. Guest payments are restricted to their event registrations. Unique `(method, reference_no)` where not rejected/void |
| `ledger_accounts` | master | One money account per owner: `owner_type='member'` or `'guest'`, `owner_id` references a member or guest person respectively, `currency='PHP'`. Guest accounts are private to payment staff. |
| `ledger_entries` | ledger | Append-only: `account_id`, signed `amount numeric(18,4)`, `source_type`, `source_id`, `client_ref`, `reverses_entry_id`, `occurred_at`, `recorded_by`, `note`. Unique `(source_type, source_id, client_ref)`; a reversal references the entry once. Payment status and balances are **derived from this table** |

Permissions: `courts.manage`, `bookings.create`, `bookings.read_all`, `bookings.approve`, `bookings.cancel_any`, `bookings.checkin`, `payments.submit`, `payments.verify`, `payments.void`. Members see their own bookings and payments; a narrow `security_invoker` view `court_availability` exposes only occupied ranges.

### 4.4 Events and tournaments

| Table | Class | Purpose and key columns |
| --- | --- | --- |
| `events` | document | `doc_no`, `name`, `starts_on`, `ends_on` (business dates), `location`, `status` (`draft, registration_open, registration_closed, drawn, in_progress, completed, cancelled`), `registration_opens_at/closes_at`, `fee numeric(12,2)`, `settings jsonb` (validated), `payload_hash` |
| `format_templates` | master | Reusable formats: `name`, `stage_type`-ordered `stages jsonb` (validated and versioned), `version`. Copied into a division on creation |
| `scoring_rules` | master | `name`, `games_to_win`, `points_per_game`, `win_by`, `point_cap`, `forfeit_score`, `tiebreak_order text[]` |
| `divisions` | document | `event_id`, `name`, `category_id`, `format` (`singles, doubles`), `gender` (nullable), `age_group` (nullable), `rank_band` (min/max rank ids, nullable), `status` (`open, drawn, in_progress, finalized, cancelled`), `finalized_at`, `format_snapshot jsonb`, `scoring_snapshot jsonb` |
| `division_stages` | document | `division_id`, `stage_no`, `stage_type` (`round_robin, single_elimination, pool_play, best_of_n_playoff, split_single_elimination`), `config jsonb` (validated), `scoring_rule_snapshot jsonb`, `status`. Unique `(division_id, stage_no)` |
| `registrations` | document | `event_id`, `division_id`, `member_id` (the registrant), `status` (`requested, confirmed, waitlisted, withdrawn, rejected`), `fee_snapshot`, `payload_hash`, `status_reason`. Unique active `(division_id, member_id)`. Eligibility is checked server-side |
| `event_participants` | master | Staff-only event/person identity; nullable `member_id` distinguishes guests. One live person per event; no guest Auth profile or membership. |
| `entries` | document | The competing unit in a division: `division_id`, `registration_id`, `seed`, `status`. A doubles entry has two roster rows across `entry_members` and `entry_guests`. |
| `entry_members` | document | `entry_id`, `member_id`; unique `(entry_id, member_id)`; a member is in at most one active entry per division |
| `entry_guests` | document | `entry_id`, `participant_id`, `display_name_snapshot`; immutable guest roster. Guest registrations use `guest_participant_id` instead of `member_id`, plus assessed rank, optional guest partner and name snapshots. They share the existing registration lifecycle. |
| `event_roster_changes` | ledger/log | Append-only admin moves/replacements, source/target registration IDs, reason, server old/new fees and same-payer receipt-credit flag. Unique source/target; the target FK is deferred until commit for atomic same-division place reservation. No in-place roster edits. |
| `draws` | document | `division_stage_id`, `seed` (secure random, stored), `entrant_snapshot jsonb`, `result jsonb`, `run_by`, `run_at`, `superseded_by_id`, `redo_reason`. Unique active per stage, so a second run returns the first |
| `matches` | document | `division_stage_id`, `round_no`, `match_no`, `group_label` (A, B, …; H or L), `entry_a_id`, `entry_b_id` (nullable until known), `feeds_match_id`, `slot`, `court_id` (optional), `scheduled_at`, `referee_member_id`, `status` (`scheduled, in_progress, completed, forfeited, cancelled, void`), `winner_entry_id`. Unique `(division_stage_id, round_no, match_no)` |
| `match_games` | document | `match_id`, `game_no`, `score_a`, `score_b`; unique `(match_id, game_no)`; checked against the scoring rule by the RPC |
| `score_events` | log | Append-only: `match_id`, `kind` (`entered, finalized, corrected, forfeit`), `payload jsonb`, `actor`, `occurred_at`, `reverses_id`. Exactly one final result per match comes from the latest non-reversed `finalized` event |
| `division_results` | document | Final placements written at finalization: `division_id`, `entry_id`, `placement`, `bracket_tier` (`H`, `L`, null), `bracket_result` (`won`, `lost`, null), unique `(division_id, entry_id)` |

Standings are **computed on the server** (SQL functions over finalized matches using the stage's tiebreak order), not stored by clients. Permissions: `events.manage`, `events.register`, `events.approve_registration`, `draws.run`, `draws.redo`, `brackets.manage`, `scores.enter`, `scores.finalize`, `scores.correct`. Members read published events, divisions, brackets and results (display names only); referees write scores only for matches assigned to them.

## 5. Decisions needed from you

| # | Decision | Default if you say "use defaults" |
| --- | --- | --- |
| D1 | Initial password rule | As Section 2.2 (chosen: your rule, and the birth date is imported for it) |
| D2 | Import scope and problem rows | As Section 2 (chosen: six fields; duplicates held back; RFID duplicates cleared) |
| D3 | Starting rank of imported members | Admin assigns ranks after import in bulk; until then members have no rank |
| D4 | Imported members' access before approval | `pending_member` role until an admin approves (setting `members.auto_approve_imported`, default off) |
| D5 | Temporary password expiry | None: first passwords do not expire (club decision, migration 1180) |
| D6 | Domain for internal Auth emails | `members.cpc.app` (never emailed) |
| D7 | Minors (found from birth date) | Guardian link and waiver required before approval |
| D8 | Booking approval and payment requirement defaults | Approval on, payment not required, request expires after 24 hours (all settings) |
| D9 | Open items from FEATURES 15.2 (rank movement for formats other than split, cross-category movement, doubles ranking) | The documented defaults; no rank movement for other formats until defined |
| D10 | Address: Barangay, City/Municipality, Province from the latest Philippine Standard Geographic Code (PSGC) | Seed PSGC into our own reference tables (`psgc_areas`, master, no personal data) with a script, and serve the cascading selects from them, not from a third-party API in the browser. Metro Manila shows as the province. Store codes plus a text snapshot |

## 6. State machines (summary)

| Entity | States and transitions |
| --- | --- |
| `members.status` | `imported → invited → pending_approval → active`; `pending_approval → rejected`; `active ↔ suspended`; any → `archived`. Each change writes `member_status_events` |
| `bookings.status` | `pending_approval → confirmed → checked_in → completed`; `pending_approval → rejected / expired / cancelled`; `confirmed → cancelled / no_show` |
| `payment_submissions.status` | `submitted → verified / rejected`; `verified → void` (reversing ledger entry) |
| `events.status` | `draft → registration_open → registration_closed → drawn → in_progress → completed`; any before `completed` → `cancelled` |
| `registrations.status` | `requested → confirmed / waitlisted / rejected`; `confirmed / waitlisted → withdrawn`; `waitlisted → confirmed` |
| `divisions.status` | `open → drawn → in_progress → finalized` (once); `→ cancelled` |
| `matches.status` | `scheduled → in_progress → completed`; `forfeited`, `cancelled`, `void` |

Transitions happen only in RPCs that check the permission, validate the transition, take an idempotency key, and write the audit and event rows in one transaction.

## 7. New permission codes

Added to the catalog by migration, with the admin role receiving all of them: `members.review_import` (resolve import issues), `consents.read`, `consents.record`, `divisions.manage`, `registrations.manage`, `reports.read`. Existing codes in FEATURES section 3 cover the rest. Members always read their own rows through policies that need no code.

## 8. Migration plan

| Plan step | Migration (project range) | Content |
| --- | --- | --- |
| 2.2 | `1000_members.sql`, `1005_psgc_address.sql`, `1010_categories_ranks.sql` | persons columns, members, member_access, member_status_events, import tables, consents; categories, ladders, ranks, rules, member_ranks, rank_history; tests |
| 2.3 | `1020_courts_bookings.sql`, `1030_payments_ledger.sql` | courts, hours, rates, blackouts, bookings (exclusion constraint), participants, events log; payment_submissions, ledger; concurrent-booking test |
| 2.4 | `1040_events_tournaments.sql`, `1050_matches_scores.sql` | events, templates, scoring rules, divisions, stages, registrations, entries, draws, matches, games, score events, results; constraint and state-machine tests |
| 2.5 | `1060_seed_defaults.sql` | Settings defaults and lookup lists, fake data only, idempotent |

Every migration applies to the development project, runs `deno task db:test` and `deno task db:advisors`, and is committed with its tests.

## 9. Out of scope for stage 2

RPCs and screens (stages 3 to 9), the import Edge Function (3.2), the rank engine and draw generators (stages 7 and 8), notification templates, PDF reports, public pages, and legal text.

## 10. Approval

Reply "approved" (optionally with changes to Section 5) and step 2.2 starts. Until then no club table exists.
