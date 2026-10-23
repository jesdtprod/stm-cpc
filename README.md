# Capitol Pickleball Club (CPC) Web App

Web app for the Capitol Pickleball Club: member sign-in with admin approval, court booking, skill-level categories and ranks, events and tournaments with configurable brackets, and club settings.

**Status:** early development. Nothing is deployed yet. Progress is tracked in [`docs/PLAN.md`](docs/PLAN.md).

## Stack
- Plain HTML, CSS, and vanilla JavaScript PWA, hosted on GitHub Pages (hash routing)
- Supabase: Postgres, Auth, Edge Functions, Storage
- Deno for tooling and Edge Functions
- Cloudflare Turnstile for CAPTCHA

## Documentation
| Document | Covers |
| --- | --- |
| [`docs/PLAN.md`](docs/PLAN.md) | Step-by-step plan from setup to launch |
| [`docs/FEATURES.md`](docs/FEATURES.md) | What the app does |
| [`docs/DATABASE.md`](docs/DATABASE.md) | General database standard |
| [`docs/SECURITY.md`](docs/SECURITY.md) | Security rules |
| [`docs/TECH_STACK.md`](docs/TECH_STACK.md) | Technologies and conventions |
| [`docs/UI_DESIGN.md`](docs/UI_DESIGN.md) | Visual and interaction standard |
| [`AGENTS.md`](AGENTS.md) | Rules for coding agents |

## Repository layout
```
docs/         project documents
web/          files published to GitHub Pages
supabase/     config, migrations, functions, database tests
scripts/      checks and generators
templates/    examples to copy and adapt
agent-skills/ skills for coding agents
```

## Public repository notice
This repository is public. It must never contain secrets (service keys, database passwords, CAPTCHA secrets), real member data, or the member import file. Only the Supabase project URL and the public anon key may appear in code. See `docs/SECURITY.md`.

## Getting started
Follow `docs/PLAN.md` from the first unchecked step.
