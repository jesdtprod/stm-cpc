---
name: cpc-conventions
description: Short digest of the Capitol Pickleball Club (CPC) web app rules. Use at the start of any task in this repository (database, migrations, RLS, Edge Functions, screens, security, brackets) instead of reading the full documents in docs/. Points to the exact document section when detail is needed.
---

# CPC conventions (digest)

Use this instead of loading the whole documents. Open a `docs/` section only when the task needs its detail.

## Stack and structure
- Plain HTML/CSS/vanilla JS PWA on GitHub Pages, hash routing (`#/path`). Supabase (Postgres, Auth, Edge Functions, Storage). Deno tooling. Cloudflare Turnstile CAPTCHA. Public repository.
- Folders: `docs/`, `web/` (published), `supabase/` (config, migrations, functions, tests), `scripts/`, `templates/`, `agent-skills/`.
- Supabase dev project: `https://ehclozdhfmacetkrcyct.supabase.co`. Only URL + anon key are public. Never handle `service_role`, DB password, Turnstile secret, temp passwords.
- Libraries pinned; self-host where possible; CDN scripts need exact versions and SRI. Turnstile script loads from Cloudflare.

## Database rules (docs/DATABASE.md §4–8, 11)
- Primary key: `id text collate "C"` ULID with format check, default `core.ulid()`, immutable.
- Standard columns: `org_id`, `unit_id` (nullable), `created_at/by`, `updated_at/by`, `version`, `meta jsonb` (small extras only). Master data adds `deleted_at/by`, `delete_reason`.
- Every table has a class comment: **master** (soft delete), **document** (cancel/void, status machine, `payload_hash`, snapshots of names/prices), **ledger/log** (append-only, corrections are reversing rows).
- New table recipe: create table with standard columns, `core.attach_standard`, `core.enable_standard_rls`, class comment, indexes on FKs and RLS columns, partial unique indexes `where deleted_at is null`, tests.
- No hard deletes, no cascades (`on delete restrict`). Writes to documents, ledgers, ranks, scores, and payments go through RPCs only; direct writes are revoked.
- Money `numeric`, instants `timestamptz`, business timezone `Asia/Manila`. Never trust client totals, prices, status, ownership, or timestamps.
- Idempotency, three layers: (1) the document ULID is the key (`insert … on conflict (id) do nothing`, `payload_hash` mismatch = 409); (2) `core.idempotency_keys` for other actions (same key+payload replays the stored response; different payload = 422; in progress = 409); (3) natural unique constraints.
- Contention: exclusion constraints (no double-booking), conditional updates, row locks, unique indexes. Never read-then-write in app code.
- Human-readable numbers come from `counters` under row lock. Member ID: `CPC-YYYY-NNNNN`.

## Access control (docs/DATABASE.md §8, docs/SECURITY.md §1)
- RLS on every table, view, and bucket. Authorization = **permission codes** (`module.action`) via `core.has_permission(org_id, unit_id, code)`. Roles are bundles of permissions.
- Never use `user_metadata` for authorization. `security definer` functions: `set search_path = ''`, check caller inside, revoke from `public`/`anon`. Views use `security_invoker = true`.
- Users cannot change their own role, unit, rank, or status. Inactive/suspended users lose access at once.

## Security musts (docs/SECURITY.md)
- No secrets or real data in the repo. Fake data only. Member import file stays outside the repo.
- Escape all dynamic text; no inline scripts or handlers; meta CSP in every HTML file; URLs validated.
- Login: member ID + password via `member-login` function; Turnstile, rate limit, lockout, generic errors. Public Supabase sign-ups stay disabled; accounts are created by Edge Functions.
- Edge Functions: verify JWT then permission; schema-validate input; CORS allowlist (own origin only); generic errors; audit sensitive actions.
- Service worker caches the app shell only, never authenticated data. Logout clears caches and offline queue. Idle timeout 15 min.

## UI essentials (docs/UI_DESIGN.md)
- Spacing 4/8/12/16/24/32. Control height 40–44px, radius 10px; cards/modals radius 14–16px. Body 13–14px, table heads 11–12px uppercase.
- Page order: header, KPIs, search/filters, date range, table, pagination. Row actions are icon-only with tooltip and accessible label, centered under Action.
- Header, rows, and skeleton share one column definition. Money right-aligned, tabular numerals.
- States are distinct: loading skeleton, empty (with conditional reset), error with retry, refreshing, populated.
- Modals: icon badge header, scrollable body, footer Cancel then primary; focus trapped and restored.
- Contrast ≥ 4.5:1, never color alone, visible focus, reduced motion respected, works at mobile/tablet/desktop.

## Domain quick facts (docs/FEATURES.md)
- Members: imported or new sign-up → pending_approval → active (admin approves); also rejected, suspended, archived.
- Bookings: members only; `pending_approval → confirmed → checked_in → completed`; admin approves; payment proof verified by admin when required (server-enforced setting).
- Categories are skill levels; each has ranked levels (e.g., Novice Low/High); a member has one current rank. Ranks change **once per member after the whole event** (division finalization), never per match.
- Split single elimination rule: won H bracket +1, lost H retain, won L retain, lost L −1.
- Formats are stage pipelines: round robin, single elimination, pool_play (Regular/Bracketing: dynamic brackets A,B,C…, best N advance, crossover A1 v D1 style), split single elimination (Round 1 → H and L brackets). Draws are server-side, seeded, reproducible, idempotent.

## Where detail lives
DATABASE.md §4 ULID, §5 columns/helpers, §6 soft delete/void, §7 idempotency, §8 RLS/permissions, §10 modules, §11 document pattern · SECURITY.md §1 access, §2 auth/sessions, §6 integrity, §9 repo/secrets, §19 tests · FEATURES.md §4 accounts, §7 booking, §8 ranks, §9 tournaments · UI_DESIGN.md §6 tables, §8 states, §9 modals · PLAN.md for the next step.
