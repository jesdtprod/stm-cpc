# Club Database Design — Capitol Pickleball Club (CPC)

Plan step 2.1. **Status: draft for approval.** No migration is written until this document is approved (Section 10). It builds on the core kit already applied (migrations `0001`–`0009`): ULID keys, standard columns, `attach_standard`, RLS with permission codes, `audit_log`, idempotency, `settings`, `lookups`, `files`, `notifications`, `client_errors`.

## 1. Conventions (inherited from the core kit)

- Every table: ULID `id`, `org_id` (always the CPC org), `created_*`, `updated_*`, `version`, `meta`; master tables add `deleted_*`. `attach_standard(table, kind)` and RLS are applied in the same migration as the table.
- Class per table: **master** (soft delete), **document** (status machine, cancel/void, `payload_hash`), **ledger/log** (append-only). No hard deletes, no cascades.
- Writes to documents, ledgers, ranks, scores and payments go through RPCs only; clients get no direct `INSERT/UPDATE` there. Master tables edited by admins get column-level grants (`core.grant_client_dml`).
- Money is `numeric(12,2)` in PHP; instants are `timestamptz`; business dates use `Asia/Manila`.
- Migrations for this design use the project range: `1000_…` and up (DATABASE.md section 16).
- Names: `snake_case`, plural tables, `_id` foreign keys. Constraint names include the table.

## 2. Existing-member spreadsheet and import rules

The club's file (kept outside the repository, never committed) is a form-responses sheet with 1,815 rows and these columns. Mapping:

| Spreadsheet column | Goes to | Notes |
| --- | --- | --- |
| ID NO | `members.member_no` | Kept exactly. Pattern `^CPC-\d{4}-\d{5}$` (a setting) |
| Full Name | `persons.display_name` | `Lastname`, `Firstname`, `Middlename`, `Suffix` columns are empty in the file; they stay nullable in `persons` |
| Date of Birth | `persons.date_of_birth` | Also used for the initial password (Section 2.2) |
| Gender | `persons.gender` | New column. Values `male`, `female`, `other`, `unspecified`; the file has 3 distinct values |
| Complete Address | `persons.address` | New column. Personal data |
| Mobile Number | `persons.mobile` | Normalized to `09XXXXXXXXX`; original kept only if it cannot be normalized |
| Email Address | `persons.email` | Optional (about 5% blank) |
| Emergency Contact Name / Relationship / Number | a second `persons` row (`kind = 'contact'`) linked by `person_relations` (`emergency_contact`) | In 127 rows the "name" holds a phone number; it is stored as the contact's mobile and the name left as "Emergency contact" |
| Player Category (Singles / Doubles / Both, multi-select) | `members.play_formats text[]` | `Both` becomes `{singles,doubles}` |
| Playing Level (Beginner / Intermediate / Advanced, multi-select) | `members.declared_levels text[]` | Informational. The starting rank is set by an admin (Section 5, decision D3) |
| PRINTED | `members.card_printed boolean` | `YES` / `yes` → true |
| RFID CODE | `members.rfid_code` | Unique among active members |
| Photo | not imported | The column is empty |

### 2.1 Import outcomes (decision: import with flags)

The import is an Edge Function run by an admin with `members.import`. It is idempotent: re-running changes nothing that already exists. Every outcome is audited and written to a private import report.

| Row condition (in this sheet) | Outcome |
| --- | --- |
| No `ID NO` (388 rows) | **Not imported.** Counted in the report only |
| Clean row | Created: person, member (`imported`), profile, auth account, `org_members` link (pending role), emergency contact |
| Duplicate `ID NO` (26 IDs on 53 rows) | The **first** row keeps the ID. Later rows are created as members with `member_no` empty and status `needs_review`, no account, and an issue `duplicate_member_no` pointing at the ID. An admin assigns a new ID or merges |
| `ID NO` not matching the pattern (one has six digits) | Created as `needs_review`, no `member_no`, issue `invalid_member_no` |
| Birth date unreadable or ambiguous (text dates, impossible years) | Created with a `member_no` but **no auth account**, status `needs_review`, issue `invalid_birth_date`. The admin enters the date, then the account is created |
| Duplicate RFID code (3) | First keeps the code; later rows get none and an issue `duplicate_rfid` |
| Member under 18 (about 63) | Imported normally, flagged `minor`; a guardian link and consent are required before approval (FEATURES 4.5) |

### 2.2 Credentials (decision: club rule with safeguards)

- Username: the member ID, trimmed and uppercased. Initial password: the **last 5 digits of the ID followed by the birth date as `MMDDYYYY`**. Example: `CPC-2026-00001` born 12/21/2025 → `0000112212025`. It has 13 characters.
- The password is computed inside the Edge Function and handed straight to the Supabase Admin API. It is never stored in a table, a log, the import report, or the repository.
- Safeguards, enforced by `member-login` (step 3.1): `must_change_password = true` until the first change; the initial password **expires** after `members.temp_password_days` (default 30) and then only an admin reset works; Turnstile on every attempt; lockout after repeated failures per member ID and per address; generic error messages that do not reveal whether an ID exists.
- This replaces the "random temporary password" rule in FEATURES 4.2 and SECURITY. Both documents are updated when this design is approved. Known trade-off: anyone who knows a member's ID and birth date can sign in before the member does; the safeguards limit that, they do not remove it.
- Internal Auth email: `<member_no lowercased>@members.cpc.app` (decision D6). Never shown, never emailed.

## 3. Changes to core tables

| Table | Change |
| --- | --- |
| `persons` | Add `gender text` (check in `male, female, other, unspecified`, nullable) and `address text` |
| `org_members` | None. The pending role (`pending_member`) is the access gate until approval |

## 4. Tables

Permission codes are from the seeded catalog; **new codes** are listed in Section 7.

### 4.1 Members

| Table | Class | Purpose and key columns |
| --- | --- | --- |
| `members` | master | One row per club member. `person_id` (unique), `profile_id` (unique, null until the account exists), `member_no` (unique among active, nullable only for `needs_review`), `status` (`needs_review, imported, invited, pending_approval, active, rejected, suspended, archived`), `status_reason`, `joined_on date`, `card_printed`, `rfid_code` (partial unique), `play_formats text[]`, `declared_levels text[]`, `is_minor` (derived on write from birth date, re-checked by RPC), `import_batch_id`, `import_row int`. Indexes on `status`, `person_id`, `profile_id` |
| `member_access` | master | 1:1 with `members`, service-written only: `must_change_password`, `temp_password_expires_at`, `last_login_at`, `failed_attempts`, `locked_until`. Holds no password and no secret. Not readable by clients except the member's own `must_change_password` through an RPC |
| `member_status_events` | log | Append-only history: `member_id`, `from_status`, `to_status`, `reason`, `actor`, `occurred_at` |
| `import_batches` | document | One per import run: `file_sha256`, `row_count`, `created_count`, `skipped_count`, `review_count`, `failed_count`, `status` (`running, completed, failed`), `started_by`. No member data inside |
| `member_import_issues` | master | `batch_id`, `member_id` (nullable), `source_row`, `issue_code` (`duplicate_member_no, invalid_member_no, invalid_birth_date, duplicate_rfid, minor, missing_contact`), `detail` (no personal data), `resolved_at/by`. Drives the admin review screen |
| `consents` | log | Append-only: `person_id`, `kind` (`waiver, privacy`), `version`, `accepted_at`, `accepted_by_person_id` (the guardian for minors) |

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
| `payment_submissions` | document | `doc_no`, `payer_member_id`, `source_type` (`booking`, `event_registration`), `source_id`, `method`, `reference_no`, `amount numeric(12,2)`, `file_id` (proof), `status` (`submitted, verified, rejected, void`), `verified_by/at`, `reject_reason`, `payload_hash`. Unique `(method, reference_no)` where not rejected/void |
| `ledger_accounts` | master | One money account per member: `owner_type='member'`, `owner_id`, `currency='PHP'` |
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
| `entries` | document | The competing unit in a division: `division_id`, `registration_id`, `seed`, `status`. A doubles entry has two `entry_members` |
| `entry_members` | document | `entry_id`, `member_id`; unique `(entry_id, member_id)`; a member is in at most one active entry per division |
| `draws` | document | `division_stage_id`, `seed` (secure random, stored), `entrant_snapshot jsonb`, `result jsonb`, `run_by`, `run_at`, `superseded_by_id`, `redo_reason`. Unique active per stage, so a second run returns the first |
| `matches` | document | `division_stage_id`, `round_no`, `match_no`, `group_label` (A, B, …; H or L), `entry_a_id`, `entry_b_id` (nullable until known), `feeds_match_id`, `slot`, `court_id` (optional), `scheduled_at`, `referee_member_id`, `status` (`scheduled, in_progress, completed, forfeited, cancelled, void`), `winner_entry_id`. Unique `(division_stage_id, round_no, match_no)` |
| `match_games` | document | `match_id`, `game_no`, `score_a`, `score_b`; unique `(match_id, game_no)`; checked against the scoring rule by the RPC |
| `score_events` | log | Append-only: `match_id`, `kind` (`entered, finalized, corrected, forfeit`), `payload jsonb`, `actor`, `occurred_at`, `reverses_id`. Exactly one final result per match comes from the latest non-reversed `finalized` event |
| `division_results` | document | Final placements written at finalization: `division_id`, `entry_id`, `placement`, `bracket_tier` (`H`, `L`, null), `bracket_result` (`won`, `lost`, null), unique `(division_id, entry_id)` |

Standings are **computed on the server** (SQL functions over finalized matches using the stage's tiebreak order), not stored by clients. Permissions: `events.manage`, `events.register`, `events.approve_registration`, `draws.run`, `draws.redo`, `brackets.manage`, `scores.enter`, `scores.finalize`, `scores.correct`. Members read published events, divisions, brackets and results (display names only); referees write scores only for matches assigned to them.

## 5. Decisions needed from you

| # | Decision | Default if you say "use defaults" |
| --- | --- | --- |
| D1 | Initial password rule | As Section 2.2 (already chosen) |
| D2 | Import problem rows | As Section 2.1 (already chosen: import with flags) |
| D3 | Starting rank of imported members. The sheet only has multi-select "Playing Level" | Admin assigns ranks after import in bulk; until then members have no rank. The declared levels are shown to the admin as a hint |
| D4 | Imported members' access before approval | `pending_member` role until an admin approves, or auto-approve after first login (setting `members.auto_approve_imported`) | Manual approval, as FEATURES 4.3 |
| D5 | Temporary password expiry | 30 days |
| D6 | Domain for internal Auth emails | `members.cpc.app` (never emailed) |
| D7 | Minors (about 63) | Import normally; require a guardian link and waiver before approval |
| D8 | Booking approval and payment requirement defaults | Approval on, payment not required, request expires after 24 hours (all settings) |
| D9 | Open items from FEATURES 15.2 (rank movement for formats other than split, cross-category movement, doubles ranking) | The documented defaults; no rank movement for other formats until defined |

## 6. State machines (summary)

| Entity | States and transitions |
| --- | --- |
| `members.status` | `needs_review → imported → invited → pending_approval → active`; `pending_approval → rejected`; `active ↔ suspended`; any → `archived`. Each change writes `member_status_events` |
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
| 2.2 | `1000_members.sql`, `1010_categories_ranks.sql` | persons columns, members, member_access, member_status_events, import tables, consents; categories, ladders, ranks, rules, member_ranks, rank_history; tests |
| 2.3 | `1020_courts_bookings.sql`, `1030_payments_ledger.sql` | courts, hours, rates, blackouts, bookings (exclusion constraint), participants, events log; payment_submissions, ledger; concurrent-booking test |
| 2.4 | `1040_events_tournaments.sql`, `1050_matches_scores.sql` | events, templates, scoring rules, divisions, stages, registrations, entries, draws, matches, games, score events, results; constraint and state-machine tests |
| 2.5 | `1060_seed_defaults.sql` | Settings defaults and lookup lists, fake data only, idempotent |

Every migration applies to the development project, runs `deno task db:test` and `deno task db:advisors`, and is committed with its tests.

## 9. Out of scope for stage 2

RPCs and screens (stages 3 to 9), the import Edge Function (3.2), the rank engine and draw generators (stages 7 and 8), notification templates, PDF reports, public pages, and legal text.

## 10. Approval

Reply "approved" (optionally with changes to Section 5) and step 2.2 starts. Until then no club table exists.
