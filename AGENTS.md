# AGENTS.md — Capitol Pickleball Club (CPC) Web App

Instructions for coding agents working in this repository. Keep this file short. Details live in `docs/` and in the skills under `agent-skills/` (copy them to `.claude/skills/` so Claude Code discovers them automatically; other agents can read the files directly).

## Project in one paragraph
Web app for the Capitol Pickleball Club (one club): member-ID sign-in with admin approval, court booking with admin approval and optional payment proof, skill-level categories and ranks, events and tournaments with configurable brackets (round robin, single elimination, Regular/Bracketing pools, split single elimination), and settings. Stack: plain HTML/CSS/vanilla JS PWA on GitHub Pages (hash routing), Supabase (Postgres, Auth, Edge Functions, Storage), Deno tooling, Cloudflare Turnstile CAPTCHA. The repository is **public**.

## How to work (token rules)
1. **Start with the skill `cpc-conventions`** (`agent-skills/cpc-conventions/SKILL.md`, a short digest). Do **not** read whole documents. Open only the section a task needs (see the table below), using search to find it.
2. **Follow `docs/PLAN.md` one step at a time** with the skill `cpc-step-runner`. Do the next unchecked step only, then stop and ask for the pasted verification output.
3. **Edit, don't rewrite.** Change only the lines that need changing. Never regenerate a whole file to make a small change.
4. **Reuse before writing.** Look for an existing component, helper, template, or migration pattern first. Copy and adapt the golden examples in `templates/` once they exist.
5. Keep answers short. Report what changed, what was verified, and what is blocked.

## Hard rules (never break)
- No secrets in the repository or in chat: `service_role` key, database password, Turnstile secret, temporary passwords, member import file. Only the Supabase URL and anon key are public.
- **Fake data only** in code, seeds, tests, screenshots. Real members are imported later from a file kept outside the repo.
- Database changes are **new migration files only**. Never edit an applied migration.
- Every table: ULID `text` primary key, standard columns, RLS enabled, classified as master / document / ledger.
- No hard deletes. Master data is soft-deleted; documents are cancelled or voided; ledgers and logs are append-only.
- Every create or state change is **idempotent** (client-generated ULID reused on retry, or an idempotency key).
- Authorization uses **permission codes** checked in the database. UI hiding is convenience, not security.
- Escape all dynamic text. No inline scripts, no inline event handlers, no `innerHTML` with raw data.
- Prices, totals, payment status, standings, and rank changes are computed **on the server**, never trusted from the browser.
- All dates and business days use `Asia/Manila`.
- UI follows the shared tokens and components (`docs/UI_DESIGN.md`). Row actions are icon-only with accessible labels.
- Data below a primary value must be smaller, muted subtext using the shared `.sub` class.
- Guest additions, late registration and roster changes are admin-only (`events.admin_roster`); Open/Closed registration does not prevent admin guest management. Preserve draws, match history and payment ownership.

## Where to read more (open only what the task needs)
| Task | Read |
| --- | --- |
| Any table, migration, RLS, soft delete, idempotency | `docs/DATABASE.md` (Sections 4–8, 11) |
| Auth, sessions, secrets, public-repo safety, CSP, tests | `docs/SECURITY.md` (Sections 1–6, 9, 19) |
| What a feature must do, roles, states | `docs/FEATURES.md` (the matching numbered section) |
| Screens, tables, modals, empty and loading states | `docs/UI_DESIGN.md` (Sections 2, 5, 6, 8, 9, 10) |
| Libraries, CDN rules, PWA, tooling | `docs/TECH_STACK.md` |
| What to do next | `docs/PLAN.md` |

## Folder layout
```
docs/        project documents (this set)
web/         everything published to GitHub Pages
supabase/    config, migrations, functions, database tests
scripts/     checks and generators
templates/   golden examples to copy and adapt (migration, RPC, screen)
agent-skills/ project skills (copy to .claude/skills/ for Claude Code)
.github/workflows/  CI and Pages deployment
```

## Definition of done
The step's "Done when" check passed and its output was reviewed; tests were added and pass; security and UI standards followed; nothing secret or real committed; the checkbox in `docs/PLAN.md` is ticked; related documents updated if behavior changed.
