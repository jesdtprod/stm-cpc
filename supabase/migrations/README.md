# migrations/

One file per change, never edited after it is applied. Kit migrations use
numbered names (`0001_...`); project migrations start at `1000` (DATABASE.md
section 16). Apply with `npx supabase@2.118.0 db push --linked` (2.122.0 shipped
without its Windows binary; stay on 2.118.0 until fixed).

| File                                                              | Plan step | Adds                                                                                                                                                                                                        |
| ----------------------------------------------------------------- | --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `0001_core_ulid.sql`                                              | 1.1       | `core` schema, `core.ulid()`, `core.is_ulid()`, `core.ulid_time()`                                                                                                                                          |
| `0002_core_helpers.sql`                                           | 1.2       | `attach_standard`, `enable_standard_rls`, stamp / immutable / no-delete / audit triggers, `audit_log`, `write_audit`                                                                                        |
| `0003_core_tenancy_people.sql`                                    | 1.3       | `orgs`, `org_units`, `persons`, `person_relations`, `profiles`, `current_profile_id()`                                                                                                                      |
| `0004_core_rbac.sql`                                              | 1.4       | `permissions`, `roles`, `role_permissions`, `org_members`, `has_permission()`, policies, seeded catalog and roles                                                                                           |
| `0005_core_operations.sql`                                        | 1.5       | `idempotency_keys`, `counters`, `settings`, `lookups`, `files`, `notifications`, `client_errors`                                                                                                            |
| `0006_core_access_hardening.sql`                                  | 1.6       | Default privileges revoked, explicit column-level grants, new objects private by default                                                                                                                    |
| `0007_advisor_fixes.sql`                                          | 1.7       | Advisor findings resolved                                                                                                                                                                                   |
| `0009_my_profile.sql`                                             | 1B        | `my_profile()` for the session module                                                                                                                                                                       |
| `1000_members.sql`                                                | 2.2       | `members`, `member_access`, `member_status_events`, import tables, `consents`, `core.add_permission`                                                                                                        |
| `1005_psgc_address.sql`                                           | 2.2       | `psgc_areas` (data loaded by `deno task db:seed-psgc`), address columns on `persons`                                                                                                                        |
| `1006_persons_address_update.sql`, `1007_persons_address_fix.sql` | 2.2       | Address trigger: re-derive on update; typed-literal fix                                                                                                                                                     |
| `1010_categories_ranks.sql`                                       | 2.2       | `categories`, `rank_ladders`, `ranks`, `rank_rules`, `member_ranks`, `rank_history`, rule-condition validator                                                                                               |
| `1020_courts_bookings.sql`                                        | 2.3       | `courts`, `court_hours`, `court_rates`, `court_blackouts`, `bookings` (exclusion constraint), `booking_participants`, `booking_events`, `court_availability()`                                              |
| `1030_payments_ledger.sql`                                        | 2.3       | `payment_submissions`, `ledger_accounts`, `ledger_entries` (append-only), `ledger_balances` and `source_payment_totals` views                                                                               |
| `1040_events_tournaments.sql`                                     | 2.4       | `events`, `format_templates`, `scoring_rules`, `divisions`, `division_stages`, `registrations`, `entries`, `entry_members`, `entity_events`; foreign keys from the rank tables; event-registration payments |
| `1050_matches_scores.sql`                                         | 2.4       | `draws`, `matches`, `match_games`, `score_events`, `division_results`                                                                                                                                       |
| `1060_seed_defaults.sql`                                          | 2.5       | `core.seed_club_defaults()`: settings, lookup lists, scoring rules, format templates, starter categories and ranks (never overwrites; safe to re-run)                                                       |
| `1070_login_throttle.sql`                                         | 3.1       | `core.login_throttle` (hashed failure counters), lockout helpers, `member_login_state`, `member_login_succeeded`; service-only wrappers in `public`                                                         |
| `1080_member_import.sql`                                          | 3.2       | Import batch, member and admin creation functions (service-only), `import_authorized`                                                                                                                       |
| `1090_import_issue_dedupe.sql`                                    | 3.2       | A re-run does not copy open issues                                                                                                                                                                          |
| `1100_member_account_flow.sql`, `1120_fix_update_my_profile.sql`  | 3.4       | `my_access_state()`, `update_my_profile()`, first sign-in -> invited, password-changed hook; pending approval once the password is changed and the profile is complete                                      |
| `1110_import_reassign.sql`, `1130_import_id_conflicts.sql`        | 3.2       | Rows that share a member ID get new numbers from the yearly sequence (never one the file uses); a number held by a different person is not skipped                                                          |
| `1140_my_access_state_profile.sql`                                | 3.4       | `my_access_state()` also returns the member's own contact details and address codes for the profile form                                                                                                    |
| `1150_profile_details.sql`                                        | 3.4       | Middle name, suffix, gender and emergency contact on `persons`; `update_my_profile` and `my_access_state` carry them (null keeps, empty string clears)                                                      |
| `1160_member_signup.sql`, `1170_fix_signup_create.sql`            | 3.3       | `member_review_flags` (possible duplicates, minors), `signup_enabled()`, `signup_allocate_member_no()`, `signup_create()`; consent versions in settings                                                     |
| `1180_no_password_expiry.sql`                                     | 3.2       | First passwords do not expire (club decision): cleared existing expiries, setting `members.temp_password_days` = 0                                                                                          |
| `1190_import_enrich.sql`                                          | 3.4       | Fills empty name, gender and emergency-contact fields for imported members without overwriting; finds reassigned members                                                                                    |
| `1200_member_approval.sql`                                        | 3.5       | `decide_member(action, member, reason, key, ...)`: approve, reject, reconsider, suspend, restore; permissioned, idempotent, audited; rejected members can be reconsidered                                   |
| `1210_my_dashboard.sql`                                           | 3.6       | `my_dashboard()`: the figures behind the role-aware home; each section appears only when the caller holds the matching permission                                                                           |
| `1220_fix_my_dashboard.sql`                                       | 3.6       | Fix to 1210: `events` has no `deleted_at`                                                                                                                                                                   |
| `1230_settings_rules.sql`                                         | 4.1       | Per-key setting rules (`setting_valid`) and `update_setting(key, value, reason, idem)`: permissioned, idempotent, audited; timezone and member ID format are read-only from the app                         |
| `1240_settings_readonly_prefix.sql`                               | 4.1       | Member ID prefix is read-only too                                                                                                                                                                           |
| `1250_soft_delete_restore.sql`                                    | 4.2       | `soft_delete(table, id, reason, key)` and `restore_row(table, id, key)` for the master tables listed in `core.soft_delete_targets` (permissioned, idempotent, audited)                                      |
| `1260_rank_ladder_functions.sql`                                  | 4.3       | `reorder_ranks(ladder, ids, key)` and `set_starting_rank(rank, key)` (whole-ladder changes in one step) and the club's four split-bracket rank rules, seeded once                                           |
| `1270_courts_admin.sql`                                           | 4.4       | Courts, hours, rates and blackouts join `soft_delete` / `restore_row`; a court with upcoming bookings cannot be deleted                                                                                     |
| `1280_members_admin.sql`                                          | 4.5       | `archive_member`, `resolve_import_issue`; members join `soft_delete` / `restore_row` (only archived, rejected or never-signed-in members with nothing upcoming)                                             |
| `1290_staff_roles.sql`                                            | 4.6       | `assign_role`, `staff_directory`, `role_catalog` (roles.manage): nobody changes their own role, the last admin cannot be demoted, audited with old and new role                                             |
| `1300_booking_requests.sql`                                       | 5.1, 5.3  | `request_booking`, `decide_booking` (approve, reject, check in, no-show, complete), `cancel_booking`, `expire_bookings`; hours, price, ledger charge, late and no-show fees                                 |
| `1310_booking_payments.sql`                                       | 5.2       | `submit_payment`, `decide_payment` (verify, reject), `void_payment` (refund): proof file, methods, no overpaying, ledger credit and reversal                                                                |
| `1311_payment_proof_checks.sql`                                   | 5.2       | Clearer refusals for a reused reference number or proof file                                                                                                                                                |
| `1320_booking_helpers.sql`                                        | 5.1, 5.4  | `find_players`, `quote_booking`, and the 5-minute expiry job (pg_cron)                                                                                                                                      |
| `1340_login_by_email.sql`                                         | 3.1       | `member_no_for_email`: lets sign-in accept the profile email (only when exactly one member uses it; service role only)                                                                                      |
| `1360_admin_password_reset.sql`                                   | 3.2       | `admin_reset_target` and `admin_reset_done` (service role): the database half of the secure admin password reset                                                                                            |
| `1370_member_password_reset.sql`                                  | 3.2       | `member_reset_target` and `member_reset_done` (service role): a new password for an ordinary active member who forgot theirs; the member must choose their own at the next sign-in                          |

`1570_booking_midnight.sql` aligns booking requests and quotes with the
calendar: closing times of `23:59`, `23:59:59`, or `24:00` permit an end at the
following midnight in Asia/Manila. Earlier closing times still apply normally.

`1590_override_unranked_member.sql` fixes `override_member_rank` for a member
with no rank yet: it now creates the current rank instead of recording only the
history row.

`1620_session_idle_30_minutes.sql` sets the inactivity timeout to 30 minutes.
The app reads the setting at the next sign-in.

`1630_profile_dupr_id.sql` adds the optional self-reported DUPR ID to the private
profile read/save RPCs, with validation and uniqueness among active person records.

`1640_event_rating_settings.sql` adds draft event ranking settings and a default
format template. CPC rank opt-out is enforced on finalization and correction;
DUPR registration remains closed until verified-account eligibility is available.

`1650_rank_rule_format_template.sql` adds an optional template restriction to rank
rules and saves the source template ID on new divisions. Older divisions retain
an unknown source and match All Formats rules only.

Tests live in `../tests/` and run with `deno task db:test` (needs a logged-in,
linked CLI; no Docker).

`1661_landing_member_photos.sql` adds photo paths to the public landing member
badges and permits reads only for those selected active members' photos. The
avatar bucket stays private; the page uses short-lived signed URLs and initials
when a photo is missing or fails to load.
The test runner accepts both CLI JSON result formats: an array of rows or an
object containing `rows`. Missing or malformed results still fail verification.

`1660_event_participants.sql` (6.2a) adds a staff-only event participant registry,
reusing existing persons for active members and guests without creating accounts.
This is the identity foundation; guest registrations, transfers, substitutions,
fees and rank-credit changes are separate later steps. Verify with the matching
`1660_event_participants.test.sql`; do not enable guest entries before 6.2b.

`1670_guest_event_registration.sql` (6.2b) adds the draft-only Allow Guest Players
policy, staff guest registration, rank assessment and member/guest doubles.
Guest registrations use the existing approval/waitlist/withdrawal lifecycle;
payment receipts and ledger entries reference the real guest payer. Immutable
`entry_guests` snapshots supply names to draws, brackets, standings and results,
while only `entry_members` are considered for CPC rank movement. This migration
also closes null-member ownership checks in member payment/withdrawal RPCs.
Apply before deploying `event-guests.js` and the event/payment screen changes.

`1680_guest_dupr_id.sql` adds optional guest DUPR IDs using the existing person ID
validation/uniqueness and a staff-only immutable event participant snapshot. It
does not verify DUPR accounts, fetch ratings or permit DUPR-rated registration.

`1690_admin_guest_roster.sql` grants `events.admin_roster` to the admin bundle
only and requires it on guest identity/policy/registration writes. Admins can add
guests in open or closed registration without reopening the event. Pre-draw Move
and Replace actions retain original registrations/rosters in append-only change
history and calculate new fees server-side. Verified credit follows a change only
for the same payer; pending receipts must be resolved first. Drawn records remain
immutable. Reload permissions after applying this migration to see admin actions.


`1700_public_landing_event_details.sql` enriches the public events payload in
`public_landing_info` with tournament registration opening and closing timestamps,
DUPR and CPC ranking flags, format template name and division counts.

`1710_member_menu_settings.sql` adds four Settings switches (`member_menu.book`,
`member_menu.bookings`, `member_menu.events`, `member_menu.ranking`, all on by
default) that show or hide those links in the member side menu, dashboard quick
links and shortcut tabs. Hiding is a convenience only; routes, RLS and
permission codes are unchanged.

`1720_member_self_assessment.sql` adds an optional estimate to the existing master
members record, with owner/staff read access, permissioned admin corrections,
reason and actor audit, idempotent saves and optimistic versions. Official CPC
ranks, rank history, event eligibility and DUPR are unchanged. Apply before using
the profile/member-details Self-Assessed Rank card; verify with `deno task db:test 1720`.

`1730_lock_member_self_assessment.sql` makes a member's first assessment final for
that member. Later updates/clears require `ranks.override` and a reason. Existing
official club ranks load read-only when no estimate exists; no backfill is made.
Completed retries still replay after locking. Verify with `deno task db:test 1730`
and the updated `deno task db:test 1720` regression suite.

`1740_rank_movement_switch_restore.sql` puts back the `ranks.movement_enabled`
check in `core.apply_rank_movement`, lost when 1640 and 1650 rewrote the rank
engine. With the switch off, divisions finalize and results are kept, but no
rank moves.

`1750_public_members.sql` adds the public Members page data: `public_members()`
returns display name, photo path and CPC rank/category for active, imported and
invited members (never member IDs or contact data), behind the Settings switch
`public.members_enabled` (on by default). A storage policy lets visitors sign
only those members' photos while the page is published.

`1760_random_active_member_strip.sql` draws up to 15 distinct active, nondeleted
CPC members at random for each `club_home_stats()` request, preserving the full
active count and the initials/photo-path payload. It replaces 1661's selection-
dependent storage policy with eligibility checks for current active CPC photos,
so a separate signing request cannot lose access because another draw differs.
The avatar bucket stays private; unrelated uploads and inactive members remain
excluded. Verify with `deno task db:test 1760` and `deno task db:test 1661`.

`1770_public_member_names_and_numbers.sql` adds the explicitly approved CPC
member number and saved name parts to `public_members()`. The browser reuses
the staff Members formatter; only the middle initial leaves the database.
Internal IDs and contact data remain excluded, and disabling publication hides
the complete payload. Verify with `deno task db:test 1770` and `deno task db:test 1750`.

`1780_public_members_full_directory.sql` removes the old 1,000-member truncation
from `public_members()`. The payload includes every eligible public member, so
the browser's total, search and 12-card pagination cover the complete directory.
Publication settings, status exclusions, ordering and approved fields remain
the same. Verify with `deno task db:test 1780` (1,005 fake imported members in a
rolled-back transaction), plus the 1770 and 1750 regressions.

`1781_public_member_active_badges.sql` adds an `is_active` boolean to the public
Members payload for Active/Not Active badges. Detailed statuses and reasons stay
private; existing publication, eligibility and full-directory behavior stay the
same. Verify with `deno task db:test 1781_public_member_active_badges` and the
1750/1770/1780 regressions.

`1782_public_court_notes_and_counts.sql` adds `public_courts()` for public court
cards: notes, usual hours and today's vacant/occupied slot counts, using Manila
time, configured slot duration, effective court hours, live reservations and
blackouts. The counting helper remains private. Booking identities, time ranges,
rates and blackout reasons are excluded; closed/deleted courts stay hidden.
The member calendar reads the existing court notes field. Verify with
`deno task db:test 1782_public_court_notes_and_counts` (18 assertions).

`1790_public_event_divisions.sql` adds a `divisions` array to each event in
`public_landing_info()`: name, format, gender, age group, category, rank range,
entry limit and the count of requested/confirmed entries. Counts only; no
registrant names or ids. Verify with `deno task db:test 1790` and the 1700
regression.

`1830_cpc_rating_calculation.sql` adds private, deterministic cpc-v1 points
helpers for PLAN 8.4a. It does not initialize members or change finalization.
Verify with `deno task db:test 1830_cpc_rating_calculation`; formula, bands and
the remaining integration steps are documented in `docs/CPC_RATING.md`.

`1840_cpc_rating_storage_snapshots.sql` (PLAN 8.4b) stores CPC points: current
member state (NULL = unrated), append-only `member_cpc_rating_history`, guest
assessments, and frozen per-division player/team-strength snapshots. RPCs:
`set_member_cpc_rating`, `set_event_participant_cpc_rating` (`ranks.override`,
reason, version, idempotency key), `initialize_member_cpc_ratings` (adds unrated
rows only, never changes existing points or ranks) and
`snapshot_division_cpc_ratings` (`scores.finalize`, after the draw). Nothing calls
them from finalization yet (8.4c). Verify with
`deno task db:test 1840_cpc_rating_storage_snapshots`. `1841_cpc_rating_rpc_grants.sql`
grants the core functions to `authenticated` so the public wrappers can run.

`1850_cpc_points_finalization.sql` (PLAN 8.4c) activates CPC points behind the
setting `ranks.cpc_points_enabled` (default false). While it is on, a division's
rating inputs are frozen at the draw (every player, guests included, needs assessed
points or the draw is refused; events with the CPC opt-out are skipped). A division
with frozen inputs is rated by points at finalization instead of H/L movement:
`core.cpc_division_outcomes` computes the result from the played matches,
`core.apply_cpc_points` writes append-only points history and moves the rank to the
exact band. Corrections (including score-only ones) reverse each changed player's
earlier delta relative to their current points and apply the new one. Divisions
without frozen inputs keep the legacy rules. Verify with
`deno task db:test 1850_cpc_points_finalization`, plus the 1500, 1510 and 1840 suites.

`1860_retire_single_elimination_template.sql` soft-deletes the seeded plain "Single
elimination" format template (inactive, with a reason); divisions and events that
used it keep their history. The club's templates are Openplay, Split Single
Elimination and Tournament. `1470_single_elimination` now creates its own template.

`1870_rank_names_cpc_bands.sql` renames the eight Low/High ranks to "Beginner Low" ...
"Advanced High" (the Novice names had swapped ranges typed into them). Names only: ids,
codes, order, bands and starting flags are unchanged, and Open/Professional keeps its
label. Verify with `deno task db:test 1870_rank_names_cpc_bands`.

`1880_cpc_points_screens.sql` (PLAN 8.4d) adds `cpc_ranking_list` (every active member by points, unrated
last; points visible to staff and to the member only), `cpc_points_history_view`, `cpc_points_status`, a
guard that refuses turning `ranks.cpc_points_enabled` on until every active member has a points record, and puts
the generated band back into the eight Low/High rank names (the screens read it from the name). Verify with
`deno task db:test 1880_cpc_points_screens`.

`1890_singles_doubles_ratings.sql` (PLAN 8.4e) gives every player a Singles and a Doubles rating: a `discipline`
column on ratings, guest assessments, history and snapshots; assessment functions take the discipline; preparing
members creates both records; a division's format picks the rating it uses; the club rank follows the higher
rating; the list shows both. Verify with `deno task db:test 1890`-related suites: 1840, 1850, 1851, 1880.
