# Features and Requirements — Capitol Pickleball Club (CPC) Web App

This file defines **what the application does**. How it is built is defined elsewhere:

| Document | Covers |
| --- | --- |
| `TECH_STACK.md` | Technologies and conventions |
| `DATABASE.md` | General database kit (ULID keys, soft delete, idempotency, RLS, modules) |
| `SECURITY.md` | Security rules |
| `UI_DESIGN.md` | Visual and interaction standard |

## Mandatory instruction for Antigravity and all coding agents

Implement the features below directly in the application, using the standards in the documents above. Do not skip a feature, state, role, or page. Where a requirement depends on an item under "Defaults in use, to confirm" in Section 2, implement the stated default but keep it configurable and report it as an open decision.

Features are built in the phases of Section 12, one phase at a time. A phase is not complete until its verification list passes and the results are reported.

Project-specific tables live in the project layer of `DATABASE.md`. Do not add pickleball-specific structure to the general core kit.

## 1. Overview

The web app of the **Capitol Pickleball Club (CPC)**, a single club. Members sign in with a member ID, are approved by an admin, book courts (with admin approval and optional payment), join events, and are ranked within skill-level categories. The admin manages members, courts, categories, ranks, events, brackets, results, payments, and settings.

**Core capabilities**
1. Member sign-in and sign-up by member ID with approval
2. Dashboard with side panel
3. Categories (skill levels)
4. Court registration
5. Rank registration with dynamic promotion/demotion per category, evaluated after the whole event
6. Configurable elimination types, each with its own bracketing page and dynamic scoring
7. Events/tournaments
8. Court booking (members only) with admin approval and optional payment attachment
9. Event qualifiers and random bracketing by category
10. Landing/welcome page
11. Settings (including whether payment is required)

## 2. Decisions and assumptions

**Confirmed by the club**

| # | Topic | Decision |
| --- | --- | --- |
| 1 | Member ID | Format `CPC-YYYY-NNNNN`, for example `CPC-2026-00001` |
| 2 | Sign-up | For **new members only**; existing members are imported and sign in with a first password built from their ID and birth date |
| 3 | Categories | Skill levels: Beginner, Novice, Advanced, and so on |
| 4 | Rank movement timing | After the **whole event** (division finalization), not per match |
| 5 | Court booking | Members with accounts only; payment verified by the admin; booking approved by the admin |
| 6 | Scope | One club only: Capitol Pickleball Club |
| 7 | Split single elimination | Defined in Section 9.2.1 |

**Defaults in use, to confirm**

| # | Topic | Default assumption |
| --- | --- | --- |
| 8 | Contact data | A real email is not required; collect a mobile number; password resets are admin-initiated |
| 9 | Doubles | Singles and doubles are supported; a doubles entry is a team of two; rank is tracked per member |
| 10 | Rank across categories | Ladders are chained in category order: moving up from the top rank of a category continues into the lowest rank of the next, and down likewise |
| 11 | Meaning of "winning" and "losing" a bracket | The rank rule for split brackets is defined (Section 8.3). "Winning" a bracket is read as **winning the bracket (its champion)**, and "losing" as not winning it; confirm this reading |
| 12 | Member ID sequence | `NNNNN` restarts each year, with a separate sequence per year |
| 13 | ID for new sign-ups | Assigned at sign-up and shown once; IDs of rejected requests are not reused |
| 14 | Playing in another category | Members compete in their current category; an admin may allow another category with a reason |
| 15 | Split bracket details | An odd entrant count gives a Round 1 bye that counts as a win and joins H; H and L keep Round 1 match order |
| 16 | Division attributes | Singles/doubles, gender, and age group are division attributes, not categories |
| 17 | Semifinal pairing in Regular (Bracketing) | Standard tree order (QF1 + QF2 feed SF1, QF3 + QF4 feed SF2); the `avoid_same_group` alternative is available |
| 18 | Odd bracket counts or other advancer counts | The system proposes a crossover table and the admin confirms or edits it before play; byes go to the best-seeded advancers |
| 19 | Rank movement for Regular (Bracketing) | None until the club defines a rule |

## 3. Roles and permission codes

Roles are bundles of permission codes (`DATABASE.md` Section 8). Defaults below; admins can adjust bundles without code changes.

| Role | Typical purpose |
| --- | --- |
| Pending member | Imported or newly signed up, not yet approved: password change and profile completion only |
| Member | Book courts, register for events, view own data |
| Referee / scorekeeper | Enter and finalize match scores for assigned matches |
| Front desk (optional) | Day-to-day check-in and booking support; approvals stay with Admin unless granted |
| Manager | Courts, categories, ranks, events, brackets, settings |
| Admin | Approves members, bookings, and payments; manages everything else, including roles, imports, password resets, and audits |

| Area | Permission codes (examples) |
| --- | --- |
| Members | `members.read`, `members.approve`, `members.suspend`, `members.import`, `members.reset_password` |
| Categories and ranks | `categories.manage`, `ranks.manage`, `ranks.override` |
| Courts and bookings | `courts.manage`, `bookings.create`, `bookings.read_all`, `bookings.approve`, `bookings.cancel_any`, `bookings.checkin` |
| Payments | `payments.submit`, `payments.verify`, `payments.void` |
| Events | `events.manage`, `events.register`, `events.approve_registration` |
| Brackets and results | `draws.run`, `draws.redo`, `brackets.manage`, `scores.enter`, `scores.finalize`, `scores.correct` |
| Settings and audit | `settings.manage`, `audit.read` |

Members only ever see their own personal, booking, and payment data. Other members appear to them only by display name, category, and rank.

## 4. Member accounts, sign-in, and approval

### 4.1 Member ID and sign-in
- Member IDs follow `CPC-YYYY-NNNNN`: club prefix, year joined, and a five-digit sequence, for example `CPC-2026-00001`. The prefix and the validation pattern (`^CPC-\d{4}-\d{5}$`) are settings.
- Members sign in with **member ID + password**. Input is trimmed and uppercased before lookup.
- Supabase Auth requires an email, so each member has a synthetic internal address derived from the ID (for example `cpc-2026-00001@members.<domain>`). The `member-login` Edge Function maps the ID to that address and signs in server-side. The address is never shown to the user.
- Errors are generic ("Invalid member ID or password"). Rate limiting, CAPTCHA, and lockout apply (see `SECURITY.md` Section 2).

### 4.2 Import of existing members
- Existing members are imported through an Edge Function using the Supabase admin API, never by editing `auth.users` directly.
- **Existing member IDs are kept exactly as given.** Each is validated against the ID pattern, and duplicates are rejected.
- Each import row creates a `persons` row, a `members` row, a `profiles` row, an auth account, and an `org_members` link with the pending role.
- Each imported member gets a **first password** built by the club's rule: the last 5 digits of the member ID followed by the birth date as `MMDDYYYY` (for example `0000112212025`). It is computed on the server, never stored or logged, and `must_change_password = true` until it is changed. It does **not** expire (club decision); it is replaced at the first sign-in. Members without a readable birth date get no account until an admin enters it. The first administrator gets a random 24-character password instead. Safeguards: Turnstile, lockout, generic errors (`CLUB_SCHEMA.md` section 2.2).
- The import is idempotent: `member_no` is unique, so re-running skips or updates existing members and never duplicates.
- The import file and any generated password list contain real personal data. They are **never committed to the repository** and are stored and shared privately.
- Import results are reported (created, skipped, failed with reason) and audited.

### 4.3 Member lifecycle

```
imported → invited → pending_approval → active
                         │                 │
                         ├→ rejected       ├→ suspended → active (restore)
                         └─────────────────┴→ archived (soft delete)
```

Imported members start at `imported`. New sign-ups start directly at `pending_approval`.

| State | Meaning | Access |
| --- | --- | --- |
| `imported` | Record created, account not yet used | None |
| `invited` | Credentials issued | Sign-in, forced password change, profile completion |
| `pending_approval` | Waiting for the admin | Same as invited; sign-up applicants can see their status |
| `active` | Approved | Full member access |
| `rejected` | Denied with a reason | None; can be reconsidered |
| `suspended` | Temporarily blocked | None; history kept |
| `archived` | Soft-deleted | None; history kept |

### 4.4 Sign-up (new members only)
- Sign-up is for people who are **not** already members. Existing members never use it; they are imported and sign in with their first password. A sign-up that claims an existing member ID is rejected.
- The public form is handled by the `member-signup` Edge Function: full name, mobile number (recommended), optional email, date of birth (needed for minors and age groups), a password chosen by the applicant (same policy as all passwords), consent, and CAPTCHA.
- The function creates the person, member, profile, and auth account, assigns the next member ID from the `member-YYYY` counter, and sets the status to `pending_approval`. The new ID is shown once on screen (and sent by SMS or email if a contact was given), because the applicant needs it to sign in.
- Possible duplicates of existing members (same name and birth date, or same mobile number) are flagged for the admin instead of silently creating a second record.
- The applicant has no permissions beyond viewing their own status and completing their profile until approved.
- Approval and rejection are permissioned RPCs that record actor, time, and reason; they are idempotent and audited. A setting controls auto-approval of imported members after first login (default: manual approval). New sign-ups are never auto-approved.
- Public Supabase sign-ups remain disabled; every account is created by an Edge Function.

### 4.5 Profile
- Members may save or clear an optional, self-reported DUPR ID (letters and numbers, up to 32 characters). IDs are trimmed, stored uppercase, and unique among active person records within the club. Saving an ID does not verify ownership, fetch ratings, or change CPC ranks.
- Members edit limited fields (display name, contact, preferences). They cannot edit member ID, status, official CPC rank, role, or approval data.
- Members without a saved assessment or current official club rank may submit an optional Rank Assessment once using active club ranks. After saving, only an admin with `ranks.override` may update or clear it, with a reason and audit entry. Existing saved admin assessments load directly; when no estimate was saved, the current official CPC rank loads as a read-only, club-assigned assessment without a backfill. Clearing an estimate does not reopen member submission. Assessment updates never change official CPC rank, rank history, eligibility, or DUPR. Idempotent retries still succeed after the lock, and expected versions protect against stale edits.
- Minors require a guardian link and recorded consent/waiver acceptance (append-only).

## 5. Dashboard and side panel

- Layout: persistent side panel navigation, header with account menu, content area, following `UI_DESIGN.md`.
- Menu items are generated from the user's permission codes; unauthorized items are not shown (the server enforces access regardless).
- Role-aware home: members see upcoming bookings, registered events, current ranks, and notices; staff see pending approvals, pending payment proofs, today's bookings, and active events.
- The side panel collapses on mobile into an accessible menu.
- All lists follow the shared table standard: skeleton loading, empty states, pagination, icon-only row actions.

## 6. Categories

- **Categories are skill levels**: Beginner, Novice, Advanced, and so on, defined by the admin and ordered by `sort_order`.
- Each category owns a rank ladder (Section 8) with levels such as Novice Low and Novice High. A member's current category comes from their current rank.
- Fields: name, code, description, sort order, active flag, optional eligibility notes.
- Class: master data (soft delete). A category in use by active ranks, members, or events cannot be deleted, only retired (no new use).
- Category codes are unique among active categories (partial unique index).
- Format (singles/doubles), gender, and age group are attributes of an event **division**, not categories (assumption 16).
- Eligibility for an event division (category, attributes, approval status) is enforced on the server at registration.

## 7. Court registration and booking

### 7.1 Courts
- Courts are `resources` (reservation module) with a small project table for details (surface, indoor/outdoor, notes, photo).
- Fields: name, status (`available`, `maintenance`, `closed`), operating hours, rate rules, active flag.
- Class: master data (soft delete). A court with future active bookings cannot be archived until they are cancelled or moved.
- Blackouts (maintenance, events) block booking for a time range.
- Public court cards show saved court notes and today's Vacant/Occupied slot counts from `public_courts()`. Counts use Asia/Manila, configured slot duration and effective hours; vacant excludes elapsed times, live reservations and blackouts. Occupied counts slots overlapping pending, confirmed or checked-in bookings, matching the booking calendar. No booking identities or times are published. The member booking calendar also shows court notes; empty notes remain hidden.

### 7.2 Booking (members only, admin-approved)
- Only **signed-in, active members** can book. There are no guest bookings, and every participant on a booking must be a member.
- A member selects a court, date, and slot; the system shows availability from a narrow public-safe view (occupied ranges only, no names).
- The booking ULID is generated when the form opens and reused on retries (`DATABASE.md` Section 7).
- Overlaps are prevented by the database exclusion constraint. A request in `pending_approval` holds its slot. A conflict returns a clear "slot just taken" result and refreshes availability.
- The price comes from the effective rate rule and is copied into the booking as a snapshot.

State machine: `pending_approval → confirmed → checked_in → completed`, with `rejected`, `cancelled`, `no_show`, and `expired` as terminal states.

| Transition | Who | Notes |
| --- | --- | --- |
| Request | Member | Creates `pending_approval` and holds the slot |
| Approve | Admin (`bookings.approve`) | Moves to `confirmed`. When payment is required, only after the payment is verified |
| Reject | Admin | Reason recorded; the slot is released |
| Expire | System | An unapproved request passes its time limit (setting) and frees the slot |
| Check-in | Admin or front desk | Recorded with actor and time |
| Cancel | Member (within policy) / Admin | Reason recorded; refund entry if applicable |
| No-show | Admin or front desk | Reason recorded; fee optional by setting |

Booking approval can be turned off in settings (bookings then confirm automatically), but the club default is **on**. Cancellation policy (cut-off hours, fees) is a setting enforced in the cancel RPC.

Each requesting member may make only one booking of up to 60 minutes per Asia/Manila calendar day across all courts. Pending, confirmed, checked-in, completed, and no-show bookings consume that allowance. Cancelled, rejected, and expired requests do not. Quote and request RPCs enforce this rule; requests by the same member are serialized before the replay check so concurrent submissions cannot bypass it and retries remain idempotent. Existing bookings are retained.
Clicking a free time slot checks the member's existing bookings for the selected Manila day before opening the request form. If the allowance is already used, a warning toast explains the daily limit and the form stays closed. Failed checks show an error and allow retry.

### 7.3 Optional payment attachment
- Whether payment is required is a setting (`payments.required.court_booking`). The server enforces it; hiding a field in the UI is not enough.
- A member may attach payment: proof image and/or reference number, method, and amount. This creates a `payment_submissions` row (`submitted`).
- The **admin** (`payments.verify`) marks it `verified` or `rejected` with a reason. Verification creates an append-only ledger entry. An unverified submission never marks anything as paid and never confirms a booking by itself.
- Payment approval and booking approval are separate steps with separate audit entries, which an admin can do from one screen.
- Proof files are stored in a private bucket with type and size limits, random names, and signed URLs.
- Payment status on a booking is **derived from the ledger**, never typed in.
- Refunds and corrections are reversing ledger entries.
- When payment is not required, attachment is optional and the booking only needs approval.

## 8. Ranks

### 8.1 Concepts
- A **category** is a skill level (Section 6). Each category has a **rank ladder**: ordered ranks such as Novice Low → Novice High.
- Ladders are chained in category order (Beginner → Novice → Advanced …). A member holds **one current rank**, and its category is the member's current category. By default, moving up from the top rank of a category continues into the lowest rank of the next category, and moving down from the lowest rank continues into the highest rank of the previous one. A ladder setting can stop movement at the edge instead (assumption 10).
- New members start at the starting rank chosen by the admin at approval, or the default starting rank from settings.

### 8.2 Tables (project layer)
| Table | Purpose |
| --- | --- |
| `rank_ladders` | One per category: name, order, overflow behavior, active flag |
| `ranks` | Ordered ranks within a ladder: name, `sort_order`, and an optional club skill-rating reference band |
| `rank_rules` | Dynamic movement rules |
| `member_ranks` | The member's current rank (one row per member) |
| `rank_history` | **Append-only** record of every change |

### 8.3 When ranks change: after the whole event

The club has accepted a replacement based on numerical CPC points, delivered in
PLAN 8.4a–8.4d. See [CPC points specification](CPC_RATING.md) for starting values,
unrated status, bands and the cpc-v1 score/strength formula. Until that rollout is
verified and activated, the existing H/L rules below remain the active engine.

Rank movement is evaluated **once per member per division, when the division is finalized**, from the member's final result. Individual match results do not change ranks.

Rules are data, editable by the admin without code changes. Each rule defines:

| Field | Examples |
| --- | --- |
| Conditions | final placement (champion, runner-up, semifinalist, and so on); bracket tier (H or L, for split single elimination); bracket result (won or lost); furthest round reached; minimum matches played |
| Action | move up or down by N levels |
| Limits | minimum and maximum rank; maximum movement per event; cooldown |
| Exclusions | withdrawals, forfeits, and no-shows can be excluded from movement |

**Rank rule for split single elimination (set by the club):**

| Result in the division | Rank movement |
| --- | --- |
| Won in the **H bracket** | **Up 1 level** |
| Lost in the H bracket | **Retain** (no change) |
| Won in the **L bracket** | **Retain** (no change) |
| Lost in the L bracket | **Down 1 level** |

- "Won" a bracket means winning that bracket: the bracket champion. "Lost" means not winning it, that is, being eliminated somewhere in that bracket (assumption 11, to be confirmed).
- Effect with 16 entrants: of the 8 in the H bracket, 1 moves up and 7 stay; of the 8 in the L bracket, 1 stays and 7 move down.
- Movement stops at the edges of the chain: the lowest rank of the lowest category cannot go down, and the highest rank of the highest category cannot go up.
- The rule is stored as data. Conditions used: `bracket_tier` (`H` or `L`) and `bracket_result` (`won` or `lost`). The admin can change the movement (up, retain, down, and how many levels) without code changes.
- A movement rule can also select a Format Template or All Formats (the default for existing rules). New divisions retain the exact source template ID; restricted rules match that ID even if the template is later renamed or edited. Older divisions without a recorded source template match only All Formats rules. This filter applies during finalization and score corrections.
- Divisions that do not use a split bracket (for example pure round robin or one single-elimination bracket) have no bracket tier. They get no rank movement until the admin defines a rule for that format, for example by final placement.
- Example of the original idea: a Novice Low player who wins the H bracket moves up to Novice High; a Novice High player who loses in the L bracket moves down to Novice Low.

### 8.4 Integrity
- Rank changes are applied **only** by the rank-engine RPC when a division is finalized, never from the browser.
- `rank_history` has a unique constraint on `(division_id, member_id)`, so a division cannot change a member's rank twice, even if finalization is retried.
- A result corrected after finalization creates reversing history entries, then applies the corrected outcome.
- Manual overrides require `ranks.override`, a reason, and an audit entry. Members cannot change their own rank.
- CPC reference bands are: Beginner Low 2.000–2.249; Beginner High 2.250–2.499; Novice Low 2.500–2.749; Novice High 2.750–2.999; Intermediate Low 3.000–3.499; Intermediate High 3.500–3.999; Advanced Low 4.000–4.499; Advanced High 4.500–4.999; and Open/Professional 5.000–8.000. They are club reference values only and do not verify or synchronize a DUPR account.
- Every change records: member, from, to, rule, and source division/event.

## 9. Tournament engine

### 9.1 Events and divisions
- An **event** (tournament) has dates, location, status, registration window, fee (if any), and settings.
- Draft event settings include a DUPR-rated flag (default off), an optional default format template for new divisions, and an independent Apply CPC rank changes flag (default on). These settings lock after draft. Changing a default never changes existing division snapshots.
- DUPR-rated currently records event intent only: registration stays closed until verified-account eligibility is implemented. It does not submit results or retrieve ratings. Disabling CPC rank changes still records placements and score corrections but creates no CPC rank movement.
- An event contains **divisions**: a skill category plus optional attributes (singles/doubles, gender, age group, rank band). Registration, draw, bracket, results, and rank movement happen per division.
- Event states: `draft → registration_open → registration_closed → drawn → in_progress → completed`, plus `cancelled`. Each division is **finalized** when its last stage ends; finalization records final placements and applies rank movement once.
- Undrawn divisions display Draft, Open, or Closed to match the parent event's registration state (Cancelled if the event is cancelled). Drawn, In Progress, Finalized, and Cancelled division states retain their own labels. The database continues to enforce event registration and division tournament states separately.
- Registrations: `requested → confirmed → waitlisted → withdrawn / rejected`. Eligibility (category, rank band, approval status) is checked on the server. A payment requirement follows the setting.

### 9.1.1 Guest participation and roster changes (requested; phased implementation)

- One event participant references one existing person, optionally an active club member. Guest persons have no membership or Auth profile. Reuse the participant across divisions rather than creating a new identity per entry. Names alone are not unique: different people may share a name.
- Step 6.2a supplies a staff-only identity registry (`events.manage`), not a registration or eligibility approval. Participant setup is permitted before the draw; a retry returns the original participant, but a changed payload under the same ID is rejected.
- Step 6.2b (migration 1670 applied; awaiting browser verification): events default to members only. Guest Registration toggles Allow Guest Players. Migration 1690 extends this control to open/closed registration and makes guest setup, registration and roster changes administrator-only through `events.admin_roster`, initially granted only to the admin permission bundle. Add Guest creates an identity without an account, and Add Existing Player searches existing guests or active members without returning contact data. Register Guest creates an entry request for an existing guest participant. A guest can enter different divisions, but cannot be reused as a registrant or partner in one division, including pending and waitlisted registrations. Mixed guest/member and all-guest doubles are supported.
- Staff must assess a guest's rank for each division registration (and for a guest partner). The server checks the rank's category/band, gender, age, registration window, capacity, and waitlist setting. An assessment is not a CPC membership rank. Members' ranks come from their profiles. DUPR-rated guest entry remains unavailable pending verification.
- With club ratings enabled, guest partner search uses each guest's stored Doubles rating and the division's category/rank range, gender and age checks, just as saving does. Unrated lead guests and partners may join only Beginner divisions starting at Beginner Low; this does not assign numerical ratings. Ineligible lead guests receive no partner choices. Caller-supplied ranks cannot override stored ratings; both players must fit the division but need not have identical numerical ratings.
- Member division registration can select an existing event guest as a Doubles partner under the same eligibility rules, including the NR Beginner Low allowance. Guest profiles and assessments remain admin-managed. The member owns the registration and payment; confirmation creates one member and one guest roster row and rechecks guest eligibility.
- Admin Register Guest partner search also includes eligible active club members who are not yet event participants. Saving prepares or reuses their event identity; existing division entries still exclude a player from partner search.
- Add Guest allows both rating fields to remain blank (Unrated), even with club ratings enabled. Supplied ratings still require valid assessed values. Creating a guest does not change division eligibility or assign default points.
- Guest partner search explains when the selected guest fails the division's eligibility checks, including the current rating classification, instead of showing a misleading no-matches result. Changing the guest or division rechecks eligibility.
- Member event divisions show Waiting for Approval, Waitlisted or Approved for both registration owners and member partners. Existing entries replace Register with View Registration and suppress new-entry eligibility warnings. Partner entries appear in My Registrations; payment and withdrawal controls stay with the owner.
- Admin and member event pages refresh after registration, event and division realtime changes, reconnecting, or returning to the tab. Member partners can read their own team registration (including withdrawn/rejected history) for live status updates; other teams remain private and mutation permissions remain unchanged.
- Guest fees are snapshotted server-side per division/team registration, matching existing member entry fees. Staff submit guest receipts using the club's accepted methods and private payment-proof rules; normal payment verification and registration approval apply. Guest fee charges, receipts, withdrawal reversals and payment voids use the guest's own ledger account. Paid funds remain on that account after withdrawal until the receipt is voided when returned.
- During rollout before migration 1670 is applied, Events, Registrations, Draw and Payments retry their existing member queries only when the server reports missing guest fields or relationships. Guest setup controls remain hidden until the event's guest policy field exists. Permission, network and unrelated schema errors remain errors.
- Entry guest rosters store names as historical snapshots separately from `entry_members`. Brackets, standings and results include guest names; guest contact data stays private. Only real members in `entry_members` receive CPC rank history or movement. Moving players and replacing rosters remain disabled until 6.2c/6.2d.
- Guest creation accepts an optional self-reported DUPR ID (migration 1680). IDs are trimmed, uppercased, limited to 1–32 letters/numbers and unique among active people in the club, matching member-profile rules. The participant records an immutable ID snapshot when added to the event, also when reusing an existing guest; older snapshots remain empty. Staff registration rows show the recorded ID as subtext. This does not verify account ownership, retrieve ratings, submit results, or unlock DUPR-rated registration.
- Step 6.2c (migration 1690 applied; database tests verified, browser checks pending): administrators can add and register guests while registration is Open or Closed without reopening the event. Guest eligibility, rank assessment, capacity and payment rules still apply. Admin registration can occur outside the public registration window. The guest policy cannot be disabled while guest registrations are active.
- For requested/confirmed guest-led entries in undrawn divisions, Move Guest Entry transfers the guest to a different division; Replace Players changes the guest or their partner within the same division. Both require an admin reason and preserve the withdrawn registration, entry and original roster in history. The new registration receives the current server fee. Full destinations, pending receipts, ineligible players and duplicate entries are refused atomically; a failed change leaves the current entry intact. Waitlisted entry changes and changes to drawn/started/completed divisions are not part of this step.
- `event_roster_changes` is append-only. A move or replacement with the same guest payer carries verified receipt credit along the recorded chain, including later receipt voids. The original receipt and ledger entries are retained. An increased fee requires any mandatory top-up; replacing the payer never transfers another person's money. Funds remaining with an outgoing payer are returned by the normal payment-void flow. Replacements reserve the original place rather than promoting another waitlisted entry into that place; moving out frees the old division's place normally.
- Planned 6.2c.1: replacements after the draw but before play retain bracket position and require a separate audited roster-version workflow. Do not alter existing draw snapshots or match records through a division transfer.
- Planned 6.2d: emergency substitutions require explicit event policy and official authorization, a reason, outgoing/incoming identities, score, time and effective match. Preserve completed results and original participants. Before enabling in-match substitution, specify singles/doubles handling, continue/restart/retirement decisions and rank-credit treatment; do not assume these unresolved policies.

### 9.2 Stage pipeline
A division runs an ordered list of **stages**. Each stage has a type, parameters, a scoring rule, and an advancement rule to the next stage.

| Stage type | Description | Status |
| --- | --- | --- |
| `round_robin` | Everyone in a group plays everyone | Phase 6 |
| `single_elimination` | Knockout bracket | Phase 6 |
| `pool_play` | Entrants split into a dynamic number of pools (called Brackets A, B, C … by the club); round robin in each pool; best N advance. Used by **Regular (Bracketing)**, see Section 9.2.2 | Phase 6 |
| `best_of_n_playoff` | Series between advancers (for example best of 2) | Phase 6 |
| `split_single_elimination` | Round 1 for everyone; winners continue in the H bracket and losers in the L bracket, each single elimination (Section 9.2.1) | Phase 6 |
| `double_elimination`, others | Future | Open |

**Example format from the brief:** Stage 1 bracket/pool play → Stage 2 round robin among advancers → best-of-2 deciders → Stage 4 single-elimination playoff. Each step is one stage; "top N from each group advance" is the advancement rule.
**Pure round robin** is a single stage.

- Stage parameters are validated configuration (group count, group size, advancers per group, seeding method, tiebreak order, third-place match, byes). This is the one place `jsonb` configuration is acceptable, and it must be validated and versioned.
- A new tournament **copies (snapshots) the format template**, so later template edits never change a running event.
- A new elimination type is added by implementing one generator (creates matches and advancement) and one bracketing page component. It requires no change to the core schema.

### 9.2.1 Split single elimination

**Definition (from the club):** every entrant plays Round 1. Winners continue in the **H Bracket** and losers continue in the **L Bracket**. Each bracket then runs ordinary single elimination through the quarterfinals, semifinals, and final to its own champion.

**Worked example, 16 entrants**

| Step | Games | Notes |
| --- | --- | --- |
| Round 1 (everyone plays) | 8 | Random draw within the division |
| H Bracket: 8 winners | Quarterfinals 4, Semifinals 2, Final 1 | H champion |
| L Bracket: 8 losers | Quarterfinals 4, Semifinals 2, Final 1 | L champion |
| Total | 22 | Plus an optional third-place game per bracket |

**Parameters** (validated stage configuration, set per division):

| Parameter | Default | Meaning |
| --- | --- | --- |
| `split_after_round` | 1 | Round after which winners and losers are separated |
| `bracket_labels` | `H`, `L` | Names shown on the pages |
| `reseed_method` | `by_previous_order` | How each bracket is arranged after the split: `by_previous_order` (keep Round 1 match order), `random` (new server-side draw), or `by_score` |
| `bye_goes_to` | `H` | An entrant with a Round 1 bye counts as a winner and joins the H bracket |
| `third_place_game` | off | Optional play-off between semifinal losers in each bracket |
| `scoring_rule` | per round | Games to win, points, win-by (Section 9.4); different rules per round are allowed |

**Rules**
- If the entrant count is not a power of two, byes are used in Round 1 and in each bracket's first round, awarded by the seeding method and recorded on the bracket.
- A forfeit or walkover counts as a win for the other side and moves them (and the forfeiting side) exactly like a played game.
- **Placements** are computed per bracket, with H-bracket finishers ranked above L-bracket finishers. For 16 entrants: H champion 1st, H runner-up 2nd, H semifinal losers tied 3rd, H quarterfinal losers tied 5th; L champion 9th, L runner-up 10th, L semifinal losers tied 11th, L quarterfinal losers tied 13th. The bracket tier (H or L) and whether the entrant won that bracket feed the rank rules (Section 8.3).
- Draws follow Section 9.5: the Round 1 draw is random, server-side, reproducible from the stored seed, and idempotent.

### 9.2.2 Regular (Bracketing): pool play into a crossover knockout

**Definition (from the club):** two rounds.
- **Round 1:** the entrants are split into **Brackets A, B, C, D …**; the number of brackets is dynamic. Each bracket plays a round robin, and the **best 2 of each bracket** advance.
- **Round 2:** a single-elimination knockout (quarterfinals, semifinals, final) in which the advancers are paired **across brackets**.

In the app these pools are shown as "Brackets A, B, C …", as the club calls them. This document says "pool" where needed to avoid confusion with the knockout bracket. Internally the format is two stages: a `pool_play` stage followed by a `single_elimination` stage whose entry pairings come from the crossover table.

**Worked example (from the club): 20 entrants, 4 brackets of 5, best 2 advance**

| Step | Games | Notes |
| --- | --- | --- |
| Round 1: round robin in each bracket | 10 per bracket, 40 total | 5 players each play the other 4 |
| Advancers | 8 | A1, A2, B1, B2, C1, C2, D1, D2 (bracket and finish) |
| Quarterfinals | 4 | A1 v D1, A2 v D2, B1 v C1, B2 v C2 |
| Semifinals | 2 | Per the semifinal tree (below) |
| Final | 1 | Optional third-place game |
| Total | 47 | Plus the optional third-place game |

With the club's example players: Bracket A sends Player 1 and Player 2, B sends 3 and 4, C sends 5 and 6, D sends 7 and 8. The quarterfinals are Player 1 v Player 7, Player 2 v Player 8, Player 3 v Player 5, and Player 4 v Player 6.

**Parameters** (validated stage configuration, set per division):

| Parameter | Default | Meaning |
| --- | --- | --- |
| `group_count` or `target_group_size` | set by admin | Number of brackets (dynamic). With a target size the count is `ceil(entrants / size)` |
| `group_assignment` | `random` | `random` (server-side draw; bracket sizes differ by at most 1) or `snake_by_rank` (seeded by current rank) |
| `advance_per_group` | 2 | How many from each bracket advance |
| `group_scoring_rule` | division default | Games to win, points, win-by (Section 9.4) |
| `tiebreak_order` | wins → head-to-head → game differential → point differential → drawn by lot | The last step is a server-side draw that is logged |
| `crossover_method` | `paired_groups_same_rank` | `paired_groups_same_rank` (club rule), `standard_cross` (A1 v B2 style), or `manual` (admin edits the slot table) |
| `advance_tree` | `standard` | How quarterfinal winners meet: `standard` or `avoid_same_group` |
| `knockout_scoring_rule` | per round | Different rules per round are allowed |
| `third_place_game` | off | Optional play-off between semifinal losers |

**Crossover rule `paired_groups_same_rank` (the club's rule):** brackets are paired from the outside in: the first with the last, the second with the second-to-last, and so on (A with D, B with C). Within a pair of brackets, the same finishing positions meet: first v first, second v second (A1 v D1, A2 v D2, B1 v C1, B2 v C2). With more than two advancers per bracket, finish *n* meets finish *n*.

**Semifinal tree:**
- `standard` (default): QF1 and QF2 winners meet in SF1, and QF3 and QF4 winners meet in SF2. In the example, SF1 is (A1/D1 winner) v (A2/D2 winner), so two players from the same original bracket can meet again before the final.
- `avoid_same_group`: QF1 and QF3 winners meet in SF1, and QF2 and QF4 winners meet in SF2, which keeps players from the same original bracket apart until the final.

**Dynamic cases**
- The number of knockout rounds follows from the number of advancers (final, semifinals, quarterfinals, round of 16, and so on).
- With an **odd number of brackets** or an advancer count that is not a power of two, the system generates a proposed crossover table and flags it; an admin must confirm or edit it before the knockout starts. Byes go to the best-seeded advancers (ranked by finish in the bracket, then record).
- The crossover table is generated when the last Round 1 game is finalized and is locked after the first knockout game.
- A tie for the last advancing place is resolved with `tiebreak_order`; the final step is a logged server-side draw.

**Placements:** champion 1st, runner-up 2nd, semifinal losers tied 3rd (or decided by a third-place game), quarterfinal losers tied 5th. Players eliminated in Round 1 rank after the knockout players, ordered by finish in their bracket and then by record, with equal finishes tied.

**Draw and fairness:** the assignment of entrants to brackets follows Section 9.5: random within the division, server-side, reproducible from the stored seed, and idempotent.

### 9.3 Bracketing pages
Each stage type has its own page, built from shared components and following `UI_DESIGN.md`:
- Round robin and pools: group tables (played, wins, losses, game/point differential, rank), match list per round.
- Elimination: bracket tree with rounds, byes, match cards, and advancement lines; mobile fallback as a round-by-round list.
- Split single elimination: a Round 1 column that feeds two bracket trees labelled **H Bracket** and **L Bracket**, with two champions.
- Regular (Bracketing): a card per bracket (A, B, C …) with standings and match list, then the crossover table (for example A1 v D1) and the knockout tree.
- Pages show live standings, schedule, court assignment (optional), and result status.

### 9.4 Dynamic scoring
`scoring_rules` are configured per stage (and optionally per round, for example finals best-of-3):

| Setting | Examples |
| --- | --- |
| Games to win / best of | 1, 3, 5 |
| Points per game | 11, 15, 21 |
| Win by | 1 or 2 |
| Point cap | none, or a value |
| Tiebreak order | head-to-head, game differential, point differential, random |
| Forfeit / walkover | score applied (for example 11–0) |

- Standings are calculated on the server from finalized results using the stage's tiebreak order.
- Score entry stores each game's score (`match_games`). Results are finalized by a permissioned RPC; there is exactly one final result per match.
- Score changes after finalization use `scores.correct`, create new append-only score events, and recalculate standings and rank effects through the same RPCs.
- Match states: `scheduled → in_progress → completed`, with `forfeited`, `cancelled`, and `void` variants.

### 9.5 Qualifiers and random bracketing
- Qualifier stages are ordinary stages whose advancers fill the main event.
- Draws are **random within a category/division**, run on the server by an RPC with `draws.run`. The browser cannot rerun a draw to pick a favorite.
- The server generates a secure random seed, stores it in `draws` together with the entrant list and the resulting placement, and records who ran it and when. The result is reproducible from the stored seed (for example entrants ordered by a keyed hash of the seed and entry ID).
- Running the draw twice returns the existing draw (idempotent). A redraw needs `draws.redo`, a reason, and an audit entry, and keeps the superseded draw for the record.
- Later stages can seed by standings or rank, per the stage's seeding method.
- Brackets cannot be edited after play starts except through audited, permissioned RPCs.

## 10. Settings

Scoped to the club (organization) and validated, audited, and enforced on the server.

| Group | Examples |
| --- | --- |
| Payments | `payments.required.court_booking`, `payments.required.event_registration`, accepted methods, instructions text, proof requirements |
| Booking | `booking.approval_required` (default on), slot length, advance-booking window, cancellation cut-off and fee, request expiry time (unapproved requests) |
| Members | member ID prefix (`CPC`) and validation pattern, yearly ID sequence, new-member sign-up on/off, auto-approval of imported members, temporary password expiry |
| Events | default scoring rule, registration approval required, waitlist enabled |
| Ranks | rank movement enabled per category, default starting rank, overflow behavior between categories |
| General | business timezone (`Asia/Manila`), club name and branding, contact details |

## 11. Landing / welcome page

- The public Members directory uses the same shared name formatter as staff Members: Last Name, First Name, middle initial and extension when saved; otherwise the proper-case display name. Show the actual CPC member number beneath the name, as explicitly requested by the club. Publish only the middle initial, never the full middle name, internal IDs or contact details. Existing publication settings and membership eligibility still apply.
- The public Members total includes every eligible member, without a 1,000-member cap; pagination still displays 12 cards at a time and search covers the complete directory. Admin's All total can differ because it also includes statuses excluded from public publication.
- Each public member card shows a white check in a solid green circle at the right of its identity header when the server-provided `is_active` flag is true; imported/invited members show a white clock in the same green circle. Accessible labels and tooltips identify Active/Not Active. Detailed status/reasons remain private and other statuses remain excluded.
- Public member cards show Club Rank without its numeric range, plus current Club Singles and Doubles ratings to three decimal places (Unrated when absent). Ratings follow the same publication switch and member eligibility; assessment details and history stay private.
- Public, static page on GitHub Pages: club introduction, upcoming events, court information, how to join, and a sign-in entry.
- The member strip draws a fresh random sample of at most 15 active, nondeleted CPC members whenever the welcome page opens or refreshes. It uses uploaded profile photos, falling back to initials when absent, unavailable or broken; smaller clubs show all eligible members and empty clubs show no placeholder person. The total remains the full active-member count. The payload exposes only selected photo paths and initials; names, contact details and member numbers are not added. Current photos of all eligible active members can receive five-minute signed links from the private avatar bucket so signing is independent of the next random draw.
- Public data comes only from narrow `security_invoker` views exposing the minimum columns. No personal data is shown unless explicitly decided (for example published results with display names).
- Follows `UI_DESIGN.md`, loads fast, works as a PWA entry, and contains no secrets.

## 12. Build phases

Each phase ends with a verification list. Run the checks, record the outputs, and fix failures before starting the next phase.

| Phase | Deliverable | Verification (examples) |
| --- | --- | --- |
| 1 | Repository setup; core kit migrations; `core.ulid()`; helpers; portable tests | Migrations apply cleanly; pgTAP suite passes; Supabase advisors show no findings |
| 2 | Auth: member import, `member-login`, `member-signup` (new members), forced password change, approval, pending-member restrictions | Import is idempotent; login errors are generic; pending users reach nothing else; approval audited |
| 3 | Dashboard shell, settings, categories, courts | Menu follows permissions; RLS tests per role; shared UI components verified at mobile/tablet/desktop |
| 4 | Court booking and payment attachment | Concurrent booking test yields one success; retry returns same booking; payment setting enforced server-side |
| 5 | Rank ladders, ranks, rules, history | Rule changes need no code; double-processing blocked; overrides audited |
| 6 | Tournament engine: round robin, single elimination, split single elimination (H/L), Regular (Bracketing) pool play with crossover knockout, then multi-stage pipelines; bracketing pages; dynamic scoring | Standings and tiebreaks tested; draw reproducible; redraw audited |
| 7 | Rank engine wired to division finalization; event qualifiers; landing page; hardening pass | Finalizing a division updates each member's rank once; corrections reverse and reapply; full security checklist passes |

### 12.1 Phase 1 setup (development project)

- Supabase project: `https://iohrwwrkhdkmzxntstuu.supabase.co` (project ref `iohrwwrkhdkmzxntstuu`). It is treated as the **development** project until a separate production project is created; the same migrations are then applied to production.
- The project URL and anon key are public by design. The `service_role` key and database password are never pasted into chat or committed.

| Step | Action | Verification (record the output) |
| --- | --- | --- |
| 1 | Confirm the project is empty. In the SQL Editor run: list non-system tables (`information_schema.tables` excluding system schemas), `select count(*) from auth.users`, and `select extname from pg_extension` | No unexpected tables; `auth.users` count is 0; extensions listed |
| 2 | In the `stm-cpc` folder run `npx supabase --version`, `npx supabase login`, `npx supabase init`, `npx supabase link --project-ref iohrwwrkhdkmzxntstuu` | Version printed; `supabase/config.toml` exists; link succeeds (the database password is typed in the terminal only) |
| 3 | Review, then apply the first migration: `core.ulid()` and the standard helpers | Migration applies; ULID format test passes |
| 4 | Remaining core kit migrations and the portable test suite | All tests pass; Supabase Security and Performance Advisors show no findings |

## 13. Non-functional requirements (summary)

- **Security:** all rules in `SECURITY.md`, including RLS on every table, server-side authorization, private storage, and no secrets in the public repository.
- **Idempotency:** every create/state-change operation follows the three layers in `DATABASE.md` Section 7.
- **Soft delete and history:** master data is soft-deleted, documents are cancelled or voided, ledgers, ranks, scores, and audits are append-only.
- **Time:** all instants stored as `timestamptz`; business dates in `Asia/Manila`.
- **Accessibility and responsiveness:** per `UI_DESIGN.md`; brackets and tables must remain usable on mobile.
- **Performance:** keyset pagination, indexed filters, skeleton loading, minimal layout shift.
- **Privacy:** minimal personal data, guardian handling for minors, retention and anonymization per `DATABASE.md` Section 15.

## 14. Acceptance checklist

- [ ] Members sign in with member ID (`CPC-YYYY-NNNNN`); imports are idempotent and keep existing IDs; first passwords follow the club's rule, are computed on the server, expire, and are never stored or committed; sign-up works for new members only.
- [ ] Pending, rejected, suspended, and archived members have no access beyond what their state allows.
- [ ] Approval, rejection, suspension, and restore are permissioned, idempotent, and audited.
- [ ] Dashboard side panel follows permission codes; every list uses the shared table standard.
- [ ] Categories, courts, ranks, and settings are fully admin-configurable without code changes.
- [ ] Court booking is members-only, cannot double-book under concurrent requests, is confirmed only by admin approval (and verified payment when required), and retries are safe.
- [ ] Payment requirement settings are enforced on the server; proofs are private; verification creates ledger entries.
- [ ] Rank movement follows configurable rules per category, is evaluated after the whole event, is applied once per member per division, and keeps full history.
- [ ] For a split division with 16 entrants: the H champion moves up 1, the other 7 in H retain, the L champion retains, and the other 7 in L move down 1 (floors and ceilings respected).
- [ ] Each implemented elimination type has its own bracketing page and uses dynamic scoring rules.
- [ ] Split single elimination with 16 entrants produces 8 Round 1 games, then 7 games in each of the H and L brackets, and two bracket champions.
- [ ] Regular (Bracketing) with 20 entrants in 4 brackets of 5 produces 40 round-robin games, advances the best 2 per bracket, and pairs the quarterfinals as A1 v D1, A2 v D2, B1 v C1, B2 v C2, then semifinals and a final. The number of brackets can be changed without code changes.
- [ ] Draws are server-side, random within category, reproducible from the stored seed, and idempotent.
- [ ] Results have one final record per match, with auditable corrections and consistent standings.
- [ ] Landing page shows only public-safe data.
- [ ] All open decisions in Section 2 are confirmed or recorded as accepted defaults.
- [ ] Every phase's verification list passed and results were reported.

**Completion rule:** Do not claim a feature or phase complete based on a successful build or one passing screen. Report the files and migrations changed, the surfaces covered, the verification actually performed, and every remaining blocker or open decision.

## 15. Status and remaining work

### 15.1 Status
- Documentation set written: `FEATURES.md`, `DATABASE.md`, `SECURITY.md`, `TECH_STACK.md`, `UI_DESIGN.md`.
- Phase 1 not started. The repository contains no application code yet.
- Supabase development project chosen (Section 12.1).

### 15.2 Decisions still needed from the club
| Decision | Needed before |
| --- | --- |
| Semifinal pairing for Regular (Bracketing): `standard` or `avoid_same_group` (Section 2, item 17) | Phase 6 |
| Rank movement for Regular (Bracketing), pure round robin, and single elimination (Section 2, item 19) | Phase 5 |
| Whether "won a bracket" means only the bracket champion (Section 2, item 11) | Phase 5 |
| Movement across category boundaries, for example Novice High to Intermediate Low (item 10) | Phase 5 |
| Doubles: team entry and per-member ranking (item 9) | Phases 3 to 6 |
| Member contact data: email or mobile number, and how password resets and notices are delivered (item 8) | Phase 2 |
| Member ID sequence: yearly restart, and when a new sign-up receives its ID (items 12 and 13) | Phase 2 |
| Playing in another category (item 14) | Phase 6 |

### 15.3 Not yet designed
1. **Project table design** for the club (members, categories, ranks, events, divisions, matches, bookings, payments), built on the core kit. To be written before Phase 2.
2. **Notifications:** how members learn about approvals, booking decisions, and schedules (in-app, SMS, or both).
3. **Tournament scheduling:** assigning games to courts and times, referees, and live score entry.
4. **Reports and print:** PDF brackets, standings, results, schedules, payment reports.
5. **Event registration fees:** amounts, refunds, withdrawals.
6. **Court rates and hours:** pricing rules, peak and off-peak, operating hours.
7. **Public pages:** leaderboard or ranking list, event results, member profile and history, and exactly what is public.
8. **Legal material:** waiver text, privacy notice, consent for minors.
9. **First UI reference page** that all other pages follow (`UI_DESIGN.md` Section 1); the dashboard or members list is the suggested start.

### 15.4 Repository and setup tasks
- [ ] Production Supabase project created (separate keys) when the app is ready for real use
- [ ] GitHub protections on: secret scanning, push protection, branch protection on `main`, 2FA
- [ ] GitHub Pages deployment workflow, with only the web files published
- [ ] Review `scripts/check-pos.mjs` and `scripts/check-branch-registration.mjs`; rename or replace with this project's checks
- [ ] Write `README.md` for this project; remove any legacy Apps Script code from the public repository
- [ ] Prepare the member import file (CSV) and keep it outside the repository
- [ ] Add `.gitignore` entries for `.env*`, local Supabase files, dumps, exports, and the import file
