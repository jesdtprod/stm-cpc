# Tech Stack — STM-CPC

Single source of truth for what this project is built with, how the pieces fit, and the rules for changing them. Update this file whenever a technology is added, replaced, or removed.

> Items marked **(confirm)** were inferred from the project description and should be checked against the code before relying on them.

## Project overview and document map

STM-CPC is the web app of the Capitol Pickleball Club (CPC), a single club: member-ID sign-in and approval, court booking with admin approval, skill-level ranks, events and tournaments with configurable brackets, and settings.

| Document | Covers |
| --- | --- |
| `FEATURES.md` | What the app does: features, roles, flows, phases |
| `DATABASE.md` | General database kit: ULID keys, soft delete, idempotency, RLS, modules |
| `SECURITY.md` | Security rules |
| `UI_DESIGN.md` | Visual and interaction standard |
| `TECH_STACK.md` | This file |

## 1. At a glance

| Layer | Technology | Notes |
| --- | --- | --- |
| Frontend | Plain HTML, CSS, vanilla JavaScript | No framework, no bundler |
| App type | Progressive Web App (PWA) | Installable, offline-capable shell |
| Backend (current) | Supabase | Postgres database, Auth, Edge Functions |
| Backend (legacy) | Google Apps Script + Google Sheets | Phase 1 only; no longer loaded by the frontend |
| Runtime / tooling | Deno (strict mode) | Runs the project and the Edge Functions |
| Checks | Node-style `.mjs` scripts | `scripts/check-*.mjs` |
| Typography | Plus Jakarta Sans | Google Fonts |
| Design rules | See `UI_DESIGN.md` | Mandatory for all UI work |
| Database design | See `DATABASE.md` | General core kit; ULID primary keys, soft delete, idempotency |
| Authentication | Supabase Auth with member-ID login | Via the `member-login` Edge Function; public sign-ups disabled |
| File storage | Supabase Storage (private buckets) | Payment proofs and member files; signed URLs only |
| CAPTCHA | Cloudflare Turnstile | Free; protects sign-in, sign-up, and password reset; enabled in Supabase Auth; the widget script loads from Cloudflare and cannot be self-hosted |

## 2. Frontend

### 2.1 Files

| File | Purpose |
| --- | --- |
| `index.html` | Main application shell and markup |
| `app.js` | Application logic: state, rendering, Supabase calls, events |
| `styles.css` | All styling: design tokens first, then shared components, then page-specific rules |
| `report.html` | Printable / exportable report view |
| `manifest.webmanifest` | PWA manifest: name, icons, theme color, display mode |
| `service-worker.js` | Offline caching and update handling |
| `supabase-config.js` | Supabase client configuration (URL and public anon key only) |

### 2.2 Third-party libraries (loaded from CDNs)

| Library | Used for |
| --- | --- |
| `supabase-js` v2 | Database queries, auth, calling Edge Functions |
| `html2pdf.js` | Converting rendered HTML (receipts, reports) to PDF |
| `jsPDF` + `jspdf-autotable` | Programmatic PDF receipts and tabular reports |
| Plus Jakarta Sans (Google Fonts) | UI typeface; the only font family in the app |

**CDN rules**
- Pin an exact version in every URL; never use `latest` or a floating major.
- Add `integrity` (SRI) and `crossorigin="anonymous"` to every CDN `<script>` and `<link>` where the provider supports it.
- Add every CDN asset to the service-worker precache (or a runtime cache) so the PWA still starts offline.
- Adding a new library requires an entry in this table and a reason it cannot be done in vanilla JS.

### 2.3 PWA behavior

- Cache the app shell (`index.html`, `app.js`, `styles.css`, `report.html`, manifest, icons, pinned CDN files).
- Never cache authenticated API responses in the shared cache; use network-first for Supabase calls.
- Version the cache name. On release, bump it so the old cache is deleted in the `activate` handler.
- Show the user when a new version is ready instead of reloading silently mid-task.
- Keep the manifest complete: `name`, `short_name`, `start_url`, `scope`, `display`, `theme_color`, `background_color`, and 192px / 512px (maskable) icons.

### 2.4 Code conventions

- **Vanilla JS only.** Use ES modules or clearly separated sections; no global state leaks outside a single namespace.
- **No inline styles and no inline event handlers.** Styling lives in `styles.css`; events are attached in JavaScript.
- **Design tokens first.** Colors, spacing, radius, and type scale are CSS custom properties defined once at the top of `styles.css` (see `UI_DESIGN.md`).
- **Reusable renderers** for tables, modals, toolbars, empty states, pagination, and skeletons. Never copy-paste markup between screens.
- **Escape all dynamic text** before inserting into HTML (`textContent` or a shared `escapeHtml`). Never build HTML from raw user data.
- **Dates:** always business-date logic in `Asia/Manila`.
- **Money:** store and calculate in integer minor units or fixed-precision values; format only at display time.
- **Accessibility:** semantic HTML, labelled controls, visible focus, keyboard support.

## 3. Backend

### 3.1 Supabase (current)

Project URL: `https://ehclozdhfmacetkrcyct.supabase.co` (project ref `ehclozdhfmacetkrcyct`). The URL and the anon key are public by design; the `service_role` key and database password are not, and never go in the repository or in chat. Until a separate production project exists, treat this project as **development**.

All backend code lives under `supabase/`.

| Path | Contents |
| --- | --- |
| `supabase/config.toml` | Local and project configuration |
| `supabase/migrations/` | Ordered SQL migrations: schema, RLS policies, functions, seeds |
| `supabase/functions/` | Edge Functions (Deno/TypeScript) for server-side logic |

Services in use:
- **Database:** PostgreSQL, accessed through `supabase-js`.
- **Auth:** Supabase Auth for sign-in and sessions.
- **Storage:** private buckets (payment proofs, member files) with RLS on `storage.objects` and signed URLs.
- **Edge Functions:** privileged or multi-step operations that must not run in the browser, including `member-login` (member ID to internal account sign-in), `member-signup` (new members only), the member import, and account creation.

**Database design**
- Follow `DATABASE.md`: ULID text primary keys, standard columns, soft delete for master data, cancel/void for documents, append-only ledgers and logs, three-layer idempotency, permission-code RLS.
- The core kit is project-neutral. Project-specific tables (members, categories, ranks, tournaments, matches) live in the project layer.

**Authentication model**
- Members sign in with member ID (`CPC-YYYY-NNNNN`) + password. Supabase Auth needs an email, so each member has an internal synthetic address that is never shown; the `member-login` Edge Function maps the ID to it.
- Existing members are imported through an Edge Function with random temporary passwords and a forced password change on first login. New members sign up through `member-signup` and wait for admin approval. See `FEATURES.md` Section 4 and `SECURITY.md` Section 2.

**Backend rules**
- **Every schema change is a new migration file.** Never edit an applied migration and never change the database by hand without a matching migration.
- **Row Level Security (RLS) is enabled on every table** exposed to the client, with explicit policies per role.
- The browser only ever holds the **anon key**. The `service_role` key lives only in Edge Function secrets and is never committed or shipped to the client.
- Put business-critical calculations and multi-table writes in database functions (RPC) or Edge Functions so they are atomic and cannot be bypassed from the client.
- Validate input on the server even if the client already validated it.
- Keep secrets in Supabase secrets / environment variables, never in the repository.

### 3.2 Google Apps Script + Google Sheets (legacy)

- Located at `apps-script/Code.gs`; was the Phase 1 backend.
- The frontend **no longer loads it**. The README still describes it for history.
- Treat it as read-only reference. Do not add features to it; if it is no longer needed, archive it and update the README so the docs match reality.

## 4. Tooling and quality checks

### 4.1 Runtime and config

- **Deno** is the project runtime, configured by `deno.json` in **strict mode**.
- Edge Functions also run on Deno, so the same language rules apply to both.

### 4.2 Check scripts

| Script | Purpose |
| --- | --- |
| `scripts/check-pos.mjs` | Existing check script **(confirm)**: its name suggests it was inherited from an earlier project; review what it covers and rename or replace it with this project's checks |
| `scripts/check-branch-registration.mjs` | Existing check script **(confirm)**: same review as above |

Run all checks before every commit and after every change that touches related logic. A change is not done until the checks pass.

Planned project checks: database test suite (pgTAP: RLS, idempotency, soft delete, no double-booking), bracket generation and tiebreak tests, rank-rule tests, and a repository secret scan.

### 4.3 Suggested task shortcuts (confirm in `deno.json`)

```jsonc
{
  "tasks": {
    "check": "deno run -A scripts/check-pos.mjs && deno run -A scripts/check-branch-registration.mjs",
    "lint": "deno lint",
    "fmt": "deno fmt --check"
  }
}
```

## 5. Architecture overview

```
Browser (PWA)
 ├─ index.html / report.html
 ├─ styles.css            ← tokens + shared components
 ├─ app.js                ← state, rendering, events
 ├─ service-worker.js     ← offline shell cache
 └─ supabase-config.js    ← URL + anon key
        │  HTTPS
        ▼
Supabase
 ├─ Auth                  ← sessions, JWT
 ├─ Postgres + RLS        ← data, policies, RPC functions
 ├─ Edge Functions (Deno) ← member-login, import, privileged server logic
 └─ Storage (private)     ← payment proofs, signed URLs
```

PDF generation (receipts, schedules, brackets, and reports) happens in the browser using `html2pdf.js` and `jsPDF` + `jspdf-autotable`; printed and exported figures must match the on-screen data and active filters.

## 6. Environments and configuration

| Concern | Rule |
| --- | --- |
| Public config | `supabase-config.js` holds only the project URL and anon key |
| Secrets | Edge Function secrets only; never in Git |
| Local development | Supabase local stack via `supabase/config.toml` **(confirm)** |
| Deployment | Static hosting for the frontend; Supabase for the backend **(confirm host)** |
| Timezone | `Asia/Manila` for all business dates |

## 7. Security checklist

- [ ] RLS enabled and tested for every client-accessible table
- [ ] No `service_role` key or other secret in client code or Git history
- [ ] All dynamic text escaped before rendering
- [ ] CDN scripts pinned with SRI
- [ ] Edge Functions verify the caller's JWT and role before acting
- [ ] Service worker never caches authenticated responses
- [ ] Permissions enforced on the server, not just hidden in the UI

## 8. Change management

1. Update this file in the same commit as any stack change.
2. Add a migration for any database change.
3. Run the check scripts and fix failures before merging.
4. Follow `UI_DESIGN.md` for any UI change, `DATABASE.md` for any schema change, `SECURITY.md` for anything touching auth, data access, or secrets, and `FEATURES.md` for scope.
5. Bump the service-worker cache version for any release that changes cached files.
6. Keep `README.md` consistent with this file (especially the legacy Apps Script note).

## 9. Recommended improvements

Optional, in rough priority order:

1. **Update the README** to state that Supabase is the current backend and Apps Script is legacy.
2. **Pin CDN versions with SRI** and precache them in the service worker.
3. **Add a `deno task check`** that runs every check script in one command.
4. **Add `deno lint` / `deno fmt`** to the pre-commit routine.
5. **Add RLS tests** (SQL or Edge Function tests) so policy regressions are caught automatically.
6. **Split `app.js`** into ES modules (state, api, views, components) once it grows past a manageable size; this still needs no bundler.
7. **Add basic error reporting** (a global `error` / `unhandledrejection` handler that logs to Supabase) so production failures are visible.
