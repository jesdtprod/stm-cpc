# Security Standard — STM-CPC

## Mandatory instruction for Antigravity and all coding agents

Directly edit the existing application and database migrations to implement this standard. Do not stop at recommendations or a report when implementation is requested.

**STRICT: Do not skip a single applicable table, function, page, script, workflow, or configuration. Security applies to the entire system.** A single unprotected table, one unescaped output, or one leaked key defeats everything else.

Preserve business logic, calculations, permissions, routes, data, and working interactions. Do not add dependencies or change authorization rules merely to make a check pass. If a fix would change behavior, report it instead of guessing.

Do not mark the work complete while any applicable item is unverified. Identify blocked items explicitly instead of silently skipping them.

## 0. System context and threat model

| Item | Fact |
| --- | --- |
| Hosting | GitHub Pages (static; **cannot set response headers or run server code**) |
| Repository | **Public**. Every file and every commit in history is readable by anyone |
| Frontend | Plain HTML, CSS, vanilla JavaScript; PWA with service worker |
| Backend | Supabase (Postgres, Auth, Edge Functions) |
| Legacy backend | Google Apps Script + Sheets (`apps-script/Code.gs`), no longer used by the frontend |
| Runtime | Deno (strict) |
| Payments | No online payments; members submit payment proofs (cash, bank, e-wallet reference) and staff verify and record them in a ledger |
| Personal data | Member, staff, and guest names and contacts; may include minors; covered by the Philippine Data Privacy Act (RA 10173) |

**Core assumptions (never violate):**
1. The browser, all JavaScript, and the anon key are **public and untrusted**. Anyone can call the API directly, bypassing the UI.
2. **The database (RLS, constraints, functions) is the only real security boundary.** UI checks are convenience, not security.
3. The public repository means anything ever committed is compromised forever. Secrets must never be committed.
4. Because Pages cannot set headers, protections that normally use headers must use a `<meta>` equivalent or a proxy (see Section 12).

**Main threats:** unauthorized data access (broken RLS, IDOR), privilege escalation, member-ID guessing and credential stuffing, XSS leading to session theft, tampered fees/payment records, double-booked courts, rigged or repeated bracket draws, manipulated scores or ranks, duplicate or lost transactions, leaked member data or secrets from the public repo, compromised third-party scripts, account takeover, and loss of data.

## 1. Access control and Row Level Security (highest priority)

- Enable RLS on **every** table, view, and storage bucket that the API can reach. No exceptions, including lookup and log tables.
- Write explicit policies per role and per operation (`SELECT`, `INSERT`, `UPDATE`, `DELETE`). Never use `using (true)` or `with check (true)` except for intentionally public read-only data, documented in the migration.
- Authorization is based on `auth.uid()` plus a role/unit lookup in a protected table (`org_members`) or `app_metadata`. **Never use `user_metadata` for authorization**; users can edit it.
- Prevent IDOR: a user must not read or modify another user's or unit's record by changing an ID. Filter by ownership or unit membership inside the policy.
- Prevent mass assignment: the client must not be able to write `role`, `org_id`, `unit_id`, `price`, `total`, `status`, `rank`, `created_by`, `approved_by`, balances, or timestamps. Use column-level `GRANT`s, triggers that reject changes, or RPC functions that accept only specific fields.
- Set ownership fields on the server (`default auth.uid()` or trigger), never from client input.
- Users must not be able to change their own role, unit, rank, or active status.
- Views must use `security_invoker = true`.
- `SECURITY DEFINER` functions must: set `search_path = ''`, use fully qualified names, validate the caller's role inside the function, and have `EXECUTE` revoked from `public` and `anon` unless intended.
- Revoke default privileges from `anon` and `authenticated` on new objects, then grant only what each role needs.
- Roles follow least privilege (for example pending member, member, referee, front desk, manager, admin). Document the permission matrix in the repository (see `FEATURES.md` Section 3).
- Inactive or removed users must lose access immediately: policies check an `is_active` flag.
- Reports and exports use the same RLS-protected queries as the screens; an export must never return data the user could not view.

## 2. Authentication and sessions

- **Public Supabase sign-ups stay disabled.** All account creation (imports, new-member sign-up, staff accounts) goes through Edge Functions using the admin API.
- **Member-ID login.** Members sign in with member ID + password. Supabase Auth needs an email, so each member has an internal synthetic address (for example `<member_no>@members.<domain>`) that is never displayed. The `member-login` Edge Function maps the member ID to that address and signs in server-side.
- **Member import** runs through an Edge Function. Each member's first password is the club's rule: the last 5 digits of the member ID followed by the birth date as `MMDDYYYY`. It is computed inside the Edge Function, handed to the Auth Admin API, and never stored, logged or returned; `must_change_password = true`; it does not expire (club decision), and the member must replace it at the first sign-in. **Known trade-off, accepted by the club:** anyone who knows a member's ID and birth date could sign in before the member does, so the compensating controls (Turnstile, per-ID and per-address lockout, generic errors, forced change at first sign-in) are mandatory. The first administrator and any later admin reset use a random password instead. The import file and any password list contain real personal data: never commit them, never store them in shared or public locations, and delete them after distribution.
- Until the first password change and staff approval, an account has no permissions except changing its password and completing its profile.
- Synthetic addresses cannot receive mail, so email confirmation does not apply to them; mark them confirmed at creation through the admin API. Compensating controls are mandatory: strict rate limiting, CAPTCHA, lockout after repeated failures, generic errors, and MFA for staff and admins.
- Member IDs follow `CPC-YYYY-NNNNN`, so a whole year holds only 100,000 possible values and the IDs are sequential. Treat them as public and guessable; never rely on their secrecy. The password, rate limiting, CAPTCHA, and lockout carry the security.
- **New-member sign-up** (`member-signup` Edge Function) is a public endpoint and an abuse target: require CAPTCHA, strict per-IP and per-device rate limits, a honeypot field, and input validation. Reject any attempt to claim an existing member ID. Applicants choose their own password under the standard policy. A new account has no permissions until an admin approves it, and possible duplicates of existing members are flagged for review.
- Password reset is admin-initiated (new temporary password plus forced change) or through an optional verified real email. Resets require `members.reset_password`, re-authentication, and an audit entry.
- Enforce a strong password policy (minimum 12 characters) and enable leaked-password protection if the plan supports it.
- Approval, rejection, suspension, and restore of members are permissioned, idempotent RPCs that record actor, time, and reason.
- Enable **Cloudflare Turnstile** CAPTCHA (Supabase Auth CAPTCHA protection) and Auth rate limits on sign-in, sign-up, and password reset. The site key is public and goes in the page; the secret key is stored only in the Supabase Auth settings, never in the repository or in chat. The Edge Functions `member-login` and `member-signup` pass the Turnstile token through and refuse requests without a valid one.
- Use generic login errors ("Invalid member ID or password"); never reveal whether a member ID or account exists, including through timing or response differences.
- Access token lifetime: short (about 15–60 minutes). Keep refresh-token rotation and reuse detection enabled.
- Require MFA (TOTP) for admin and owner accounts.
- Redirect URL allowlist contains only the exact production Pages URL and `localhost` for development.
- Password reset links are single-use and short-lived. Do not extend their lifetime.
- Logout calls `supabase.auth.signOut()`, clears all cached app data, and clears the offline queue. Provide an admin option for global sign-out of a user.
- Idle timeout: automatically sign out after a period of inactivity (default 30 minutes; configurable).
- Re-authenticate (password prompt) before sensitive actions: payment verification or voiding, refunds, rank overrides, bracket redraws, score corrections, role or permission changes, password resets, member import, data export.
- No shared accounts. Every member and staff user has a unique login.
- Session tokens are never logged, placed in URLs, shown on screen, or sent to third parties.

## 3. Injection (SQL, filter, and command)

- Never concatenate user input into SQL. In database functions, use `EXECUTE ... USING $1`, `format('%I')` for identifiers, and `format('%L')` for literals.
- PostgREST filter strings (`.or()`, `.filter()`, `.ilike()` with interpolated text) are injectable: reject or strip `, ( ) .` and other filter metacharacters from user input, or use separate chained filter calls. Escape `%` and `_` when wildcards are not wanted.
- Sort columns, filter fields, and table names come from an **allowlist**, never directly from user input.
- RPC parameters use strict types (`uuid`, `integer`, `numeric`, `date`, enums) so Postgres rejects bad input.
- Edge Functions that use a Postgres driver must use parameterized queries only.
- No `eval`, `new Function`, `setTimeout(string)`, or dynamic `import()` from user-controlled strings.

## 4. Cross-site scripting (XSS) and output safety

- Escape **every** dynamic value before inserting it into the page. Use `textContent`/`setAttribute`, or a single shared `escapeHtml` helper. Do not build HTML with raw user data.
- Treat names, notes, product descriptions, references, imported data, and URL parameters as untrusted.
- Avoid `innerHTML`, `outerHTML`, `insertAdjacentHTML`, and `document.write` with dynamic data. Where unavoidable, sanitize with a reviewed approach and document why.
- Receipts and reports rendered by `html2pdf.js`/`jsPDF` must escape all dynamic text too.
- No inline event handlers (`onclick=`) and no inline scripts; attach events in JavaScript. This allows a strict CSP.
- Validate URLs before using them in `href`/`src`: allow only `https:` (and `mailto:`/`tel:` where needed); never `javascript:` or `data:` from user input.
- Open external links with `rel="noopener noreferrer"`.
- Do not redirect to a URL taken from a query parameter unless it matches an allowlist.

## 5. Content Security Policy and browser hardening (GitHub Pages)

GitHub Pages cannot send security headers. Use these controls in every HTML file (`index.html`, `report.html`):

- A `<meta http-equiv="Content-Security-Policy">` tag, as strict as the app allows. Starting point:
  - `default-src 'self'`
  - `script-src 'self' https://challenges.cloudflare.com` plus pinned CDN origins only if libraries are not self-hosted (the Turnstile script must load from Cloudflare and cannot be self-hosted)
  - `style-src 'self'` plus the Google Fonts stylesheet origin if used
  - `font-src 'self' https://fonts.gstatic.com`
  - `frame-src https://challenges.cloudflare.com`
  - `img-src 'self' data: blob:`
  - `connect-src 'self' https://iohrwwrkhdkmzxntstuu.supabase.co wss://iohrwwrkhdkmzxntstuu.supabase.co`
  - `object-src 'none'`; `base-uri 'self'`; `form-action 'self'`
  - Do not use `'unsafe-inline'` or `'unsafe-eval'` for scripts.
- `<meta name="referrer" content="strict-origin-when-cross-origin">`.
- Meta CSP **cannot** provide `frame-ancestors`, reporting, or `sandbox`. For clickjacking protection, HSTS, `X-Content-Type-Options`, and `Permissions-Policy`, place the site behind a proxy that can set headers (Cloudflare, Section 12).
- Enable **Enforce HTTPS** in the repository's Pages settings. Prefer a custom domain.
- Never load mixed (HTTP) content.

## 6. Data integrity and business rules

- **Recompute on the server.** Fees, totals, payment status, eligibility, standings, scores, and rank changes are calculated in database functions or Edge Functions, never trusted from the browser.
- Multi-table writes (reservation + hold + audit, registration + payment submission, result + standings + rank change) run in **one transaction** inside an RPC.
- Use `CHECK` constraints, `NOT NULL`, foreign keys, and unique constraints for every business rule. Money uses `numeric`, never `float`.
- **Double-booking is prevented by a database exclusion constraint** on reservations (see `DATABASE.md` Section 10.2), never by a UI check alone.
- **Idempotency:** every booking, registration, payment submission, check-in, cancellation, result, and approval carries a client-generated ULID or idempotency key; retries and offline replays must not create duplicates (`DATABASE.md` Section 7).
- No hard deletes: master data is soft-deleted, documents are cancelled or voided, and ledgers, scores, ranks, and audits are append-only.
- **Payment proofs and settings:** whether payment is required is a server-enforced setting. Uploading a proof never marks anything as paid; only a staff member with `payments.verify` can verify it, which creates an append-only ledger entry. Payment status is derived from the ledger. Booking approval is enforced the same way: a booking becomes `confirmed` only through the approval RPC by a caller with `bookings.approve`, and, when payment is required, only after the payment is verified. Booking is limited to active members; guests and pending members cannot book.
- **Draws and brackets:** run only on the server by a permissioned RPC using a cryptographically secure seed that is stored with the entrant list and result. Draws are reproducible, idempotent, and cannot be rerun by the browser. A redraw requires `draws.redo`, a reason, and an audit entry. Brackets cannot be edited after play starts except through audited, permissioned RPCs.
- **Scores and results:** only authorized roles (referee, scorekeeper, staff) can submit or finalize scores; members cannot edit their own match results. Exactly one final result exists per match. Corrections create new append-only score events and recalculate standings and rank effects through the same RPCs.
- **Ranks:** changed only by the rank-engine RPC when a division (event) is finalized, with history unique per (division, member). Manual overrides need `ranks.override`, a reason, and an audit entry. Members cannot change their own rank, category, role, or status.
- Dates and business days use the `Asia/Manila` timezone consistently on the server.

## 7. Edge Functions and API security

- Verify the JWT in every function, then check the caller's role and unit before acting.
- CORS allowlist: only the exact production origin (and `localhost` in development). Never `*` for authenticated endpoints.
- Validate every request body against a schema (types, ranges, lengths) and cap the body size.
- Return generic errors to the client; log details server-side. Never return stack traces, SQL errors, or secrets.
- Rate-limit expensive or abusable endpoints (login helpers, search, export, email).
- Use only the `service_role` key inside Edge Functions, loaded from secrets. Never return it or log it.
- Do not accept webhooks or callbacks without verifying a signature.

## 8. Supabase project hardening

- Expose only the `public` (or a dedicated `api`) schema through the API. Keep audit logs, helper functions, and internal tables in a private schema.
- Revoke default privileges on new tables and functions for `anon` and `authenticated`.
- Enable only the extensions in use.
- Strong, unique database password; require SSL; restrict direct database access by network allowlist if the plan supports it. Applications use the pooler, never a superuser.
- Disable unused features: anonymous sign-ins, unused OAuth providers, unused APIs.
- If Realtime is used, apply Realtime authorization and do not broadcast sensitive tables to all clients.
- Set `statement_timeout` for `anon` and `authenticated` roles; enforce maximum page sizes and add indexes for filtered columns.
- Run Supabase's **Security Advisor** and **Performance Advisor** after every migration and resolve all findings (especially: RLS disabled, mutable function search_path, security-definer views).
- **Separate projects for development and production**, with different keys and no real member data in development.
- Storage: private buckets by default, RLS on `storage.objects`, restrict file type/size, random file names, short-lived signed URLs, never serve user-uploaded HTML/SVG from the app origin.
- Profile photos: JPG, PNG, or WebP, maximum 3 MB at selection and in the private `avatars` bucket. The browser crops/resizes uploads to JPEG. CSP permits photo display only from this project's Storage object endpoint; failed images show initials.
- The landing member strip returns at most 15 randomly selected active, nondeleted CPC members per request. Its storage policy permits anonymous reads of current photo paths for all eligible active CPC members, so a separate signing request remains valid independently of the next random selection. Unrelated uploads, other clubs, suspended/pending members and removed photos remain private. The bucket stays private; the landing page requests signed links with a five-minute lifetime. Already-issued links may remain usable until they expire.

- The club explicitly permits the public Members directory to show saved first/last names, middle initial, extension and CPC member number alongside the existing photo/category/rank fields. Full middle names, internal IDs, birth dates and contact details stay excluded. The `public.members_enabled` switch gates the complete payload; this exception does not change public leaderboard/results or landing-strip fields.
- Public Members additionally publishes an `is_active` boolean for the requested Active/Not Active card badges. It does not expose detailed membership statuses or status reasons, and does not expand the set of members eligible for publication.

- The explicitly requested court notes and today's slot counts are public through `public_courts()`, restricted to available, nondeleted CPC courts. Its private counting helper has no anonymous/authenticated execution grant. The payload contains only court name/setting/surface/notes/usual hours and the Manila day/vacant/occupied counts, without court IDs, booking identities, occupied time ranges, rates or blackout reasons.

## 9. Public repository and secrets

Because the repository is public, treat it as a published document.

- **Never commit:** `service_role` key, database password, JWT secret, SMTP credentials, any API key, `.env*` files, backups, database dumps, exports, the member import file, real member or payment data, or screenshots showing any of these.
- The only credentials allowed in client code are the Supabase **project URL and anon key**, and the anon key is safe only because RLS is correct.
- Store secrets only in Supabase secrets and GitHub Actions secrets.
- Add a `.gitignore` covering `.env*`, `supabase/.temp`, `*.sql` dumps, `*.bak`, exports, and local config.
- Enable GitHub **secret scanning** and **push protection**.
- Scan the entire Git history once for secrets. If any secret was ever committed, **rotate it immediately**; removing the commit is not enough.
- **Legacy Apps Script:** the code in `apps-script/Code.gs` is public. Confirm it contains no keys, sheet IDs with open sharing, or live web-app URLs with write access. Revoke or undeploy any active deployment, then archive or remove the folder.
- Do not publish `supabase/migrations/` seed data that contains real members, contact details, or payment records. Use fake seed data. The **member import file**, generated temporary passwords, and any export are never committed.
- Deploy only the web files that the app needs (no `scripts/`, `apps-script/`, backups, or notes) via a build/publish folder or a Pages workflow.
- Keep an inventory of every secret: what it is, where it is stored, who can access it, and when it was last rotated.
- Rotate keys on a schedule, after any staff departure, and after any suspected leak.

## 10. Supply chain and dependencies

- Pin every library to an exact version. Never use `latest` or floating majors.
- Prefer **self-hosting** `supabase-js`, `jsPDF`, `jspdf-autotable`, `html2pdf.js`, and the Inter font files (already self-hosted). If loaded from a CDN, add `integrity` (SRI) and `crossorigin="anonymous"`.
- Keep a dependency inventory (name, version, source, date last reviewed) and review for known vulnerabilities monthly.
- Enable Dependabot (or equivalent) for tooling and GitHub Actions.
- Pin GitHub Actions to a full commit SHA; set workflow `permissions` to read-only by default.
- Commit `deno.lock`. Do not import remote modules from unpinned URLs.
- Run Deno scripts with the minimum permissions (`--allow-read=./` etc.), not `-A`, unless justified.
- Adding any dependency requires a documented reason and an update to `TECH_STACK.md`.

## 11. PWA, service worker, and offline data

- The service worker caches the **app shell only**. Never cache authenticated Supabase responses, payment proofs, receipts, or reports containing member or financial data.
- Use network-first for API calls.
- Version the cache name and delete old caches in `activate`, so a bad release can be replaced quickly. Notify users when a new version is ready.
- The offline queue (IndexedDB/localStorage) stores only what is needed to sync, is cleared after a successful sync, and is wiped on logout.
- Every offline action carries a client-generated ULID; the server rejects duplicates, recomputes fees and totals, and re-checks permissions and eligibility on sync.
- Re-validate the session and the user's active status before syncing; a user removed while offline must lose access when reconnected.
- Cached role information is short-lived and never the source of truth.
- Do not store passwords or long-lived secrets on the device. The only stored credential is the Supabase session.

## 12. Hosting limitations and the header-capable upgrade

GitHub Pages limits: no custom headers, no server logic, no IP restrictions, no WAF.

Recommended upgrade for production use: put a custom domain behind **Cloudflare** (free tier) to add:
- HSTS, `Content-Security-Policy` header (including `frame-ancestors`), `X-Content-Type-Options: nosniff`, `Permissions-Policy`, `Referrer-Policy`
- WAF, bot protection, and rate-limiting rules
- DDoS protection and analytics

Until then, rely on the meta CSP, Enforce HTTPS, and a correctly configured Supabase backend.

## 13. Abuse, availability, and resilience

- Rate-limit at several layers: Supabase Auth, Edge Functions, and (when available) Cloudflare.
- Enforce pagination with a maximum page size; cap export row counts; require authentication for all reports.
- Protect email-sending features (password reset, notifications) from being used to spam others.
- Because the app is a PWA, staff can continue offline during an outage; sync must be safe to retry.
- Schedule **backups** of the Supabase database (enable point-in-time recovery if the plan allows). **Test a restore** at least once before launch and after major changes.
- Keep a rollback plan: previous service-worker version, database backup before risky migrations.

## 14. Logging, audit, and monitoring

- Maintain an **insert-only audit table** (no update/delete for anyone, including admins) recording: logins and failed logins, member approvals/rejections/suspensions, role and permission changes, payment verification and voids, refunds, rate changes, rank overrides, draws and redraws, score finalization and corrections, imports/exports, password resets, and account creation/deactivation. Store actor, action, target, old/new values, and timestamp.
- Never log passwords, tokens, or full personal identifiers. Mask personal data in logs.
- Review auth failures, Edge Function errors, and audit entries regularly; alert on spikes in failed logins or unusual bulk reads/exports.
- Add a global `error` / `unhandledrejection` handler that reports failures without exposing sensitive data to the user.

## 15. Privacy and data protection (RA 10173)

- Collect only the personal data the system needs. Record the purpose for each personal-data field.
- Restrict personal data to roles that need it. Mask or hide contact details from roles that do not. Members see other members only by display name, category, and rank.
- Minors: link a guardian, record guardian consent/waiver acceptance (append-only), and limit visibility of their data.
- Payment proof images are personal and financial data: private bucket, signed URLs, role-restricted, and covered by the retention policy.
- Define retention periods for member, booking, payment, result, and audit data, and what is anonymized or deleted afterward.
- Provide a process to access, correct, or delete a person's data on request.
- Never put personal data in URLs, query strings, file names, or analytics.
- Receipts and reports include only what is necessary.
- Prepare a breach-response plan, including notifying affected people and the National Privacy Commission when required.
- Use fake data in development, screenshots, documentation, and the public repository.

## 16. Secure development and release process

- Protect `main`: require pull requests, block force-push and deletion, require status checks to pass.
- A GitHub Actions workflow runs `scripts/check-pos.mjs`, `scripts/check-branch-registration.mjs`, lint, format, and a secret scan on every pull request.
- Any pull request touching RLS, auth, roles, money, or Edge Functions gets a security review against this document.
- Migrations are reviewed like code and applied to development first, then production. Never edit an applied migration; add a new one.
- Add automated **RLS tests** (SQL or Edge Function tests) that assert what each role can and cannot do, so regressions are caught.
- Release checklist: run checks, run Supabase advisors, bump the service-worker cache version, run the manual security tests (Section 19), confirm no secrets in the diff.
- Enable 2FA (passkey preferred) on GitHub, Supabase, the domain registrar, and the admin's email. Limit collaborators to the minimum and review access quarterly.

## 17. Incident response

1. **Detect:** failed-login spikes, unexpected audit entries, user reports.
2. **Contain:** disable the affected account, rotate keys, force global sign-out, disable the affected function or policy if needed.
3. **Recover:** restore from backup if data changed; fix the root cause with a migration.
4. **Notify:** affected users and the National Privacy Commission where required.
5. **Review:** write down what happened, the cause, and what changed.

Keep a written contact list and the steps for rotating the anon key, JWT secret, database password, and Edge Function secrets.

## 18. Operational security

- Unique account per person; remove or deactivate accounts on the day someone leaves; review the account list monthly.
- Front-desk devices use a screen lock, current OS and browser updates, and are not used for personal browsing. Never use shared or public computers for admin work.
- Protect the admin's email and phone, since they are the recovery path for every other account. Store recovery codes offline.
- Keep the permission matrix, secret inventory, dependency inventory, and this document up to date.

## 19. Verification tests (run before every release)

- [ ] As an anonymous user, attempt to read and write every table and RPC: everything is denied unless intentionally public.
- [ ] As each role (pending member, member, referee, front desk, manager, admin), attempt to access another member's data or another unit's data, change your own role, status, or rank, and change a fee/total/payment status/score: all fail unless permitted.
- [ ] Enter `'; drop table x;--`, `%`, `_`, `,`, `)`, `<script>alert(1)</script>`, and `"><img src=x onerror=alert(1)>` into every search box, form field, and note: nothing breaks, nothing executes, and values display as plain text.
- [ ] Replay an expired token and a token from a deactivated user: both are rejected.
- [ ] Submit the same booking twice quickly, replay an offline action, and book the same court and time from two devices: one booking, no duplicates, and a clear "slot taken" result for the loser.
- [ ] Run a bracket draw twice: the second call returns the same draw; a redraw without permission and reason is refused; the stored seed reproduces the draw.
- [ ] Finalize a division twice and correct a result once: rank history changes exactly once per (division, member) and reversals are recorded.
- [ ] Try member IDs that exist and do not exist at login: responses and timing are indistinguishable; repeated failures trigger lockout or CAPTCHA.
- [ ] Sign in as a pending member: only password change and profile completion are reachable.
- [ ] Submit sign-up requests rapidly, and with an existing member ID: rate limiting or CAPTCHA triggers, and the existing-ID claim is rejected.
- [ ] Try to book as a guest, as a pending member, and without admin approval: all refused or left unconfirmed.
- [ ] Try 20 wrong passwords: rate limiting or CAPTCHA triggers.
- [ ] Search the repository, its history, built files, and the browser network tab for `service_role`, passwords, and tokens: none found.
- [ ] Confirm the service worker does not cache authenticated API responses or reports.
- [ ] Confirm CSP blocks an injected inline script and an unlisted external script.
- [ ] Run Supabase Security and Performance Advisors: no unresolved findings.
- [ ] Restore a backup into a test project and confirm the data is intact.

## 20. Strict implementation and acceptance checklist

Before editing, inventory every table, view, function, policy, storage bucket, Edge Function, page, form, search box, script, workflow, secret, and dependency. Include role-specific, hidden, nested, and dynamically rendered surfaces.

Maintain a coverage checklist with each item marked **Updated**, **Verified**, or **Blocked**. A blocked or unverified item is not complete. Do not silently omit anything.

- [ ] RLS enabled with explicit, tested policies on every table, view, and bucket.
- [ ] Roles, ownership, and org/unit rules enforced in the database; no client-writable privilege, rank, or fee/total columns.
- [ ] `SECURITY DEFINER` functions hardened; views use `security_invoker`.
- [ ] Public sign-ups disabled; member-ID login via Edge Function with rate limiting, CAPTCHA, lockout, and generic errors; forced password change and approval gate working; MFA for staff and admins; idle timeout implemented.
- [ ] No SQL or filter injection paths; allowlists for sort and filter fields.
- [ ] All dynamic output escaped; no inline scripts or handlers; meta CSP in every HTML file.
- [ ] Server-side recomputation, transactions, constraints, and idempotency for all booking, payment, registration, draw, result, and rank operations.
- [ ] Edge Functions verify JWT and role, use a CORS allowlist, validate input, and return generic errors.
- [ ] No secrets in the repository or its history; secret scanning and push protection on; legacy Apps Script secured or removed.
- [ ] Libraries pinned and self-hosted (or SRI); lockfile committed; Actions pinned; Dependabot on.
- [ ] Service worker caches the app shell only; offline queue cleared on logout; duplicate-safe sync.
- [ ] Insert-only audit log in place; no sensitive data in logs.
- [ ] Backups configured and a restore tested.
- [ ] Branch protection, required checks, and 2FA enabled on all accounts.
- [ ] Privacy, retention, and breach-response procedures documented.
- [ ] All verification tests in Section 19 pass.

**Completion rule:** Do not claim the system is secure based on a successful build, one reviewed table, or passing syntax checks. Report the files and migrations changed, the surfaces covered, the verification actually performed, and every remaining risk or blocker. No skipped item is acceptable under a claim of completion.
