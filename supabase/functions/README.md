# functions/

Edge Functions. Each one validates input, returns generic errors, and checks the caller before acting.

| Function | Step | Purpose |
| --- | --- | --- |
| `member-login` | 3.1 | Member ID + password sign-in. Public (no JWT): protected by Turnstile (verified by Auth), lockout per ID and per address, origin check, generic errors. `handler.ts` holds the rules and is unit-tested (`tests/unit/member-login.test.js`); `index.ts` wires the Supabase clients. |
| `member-import` | 3.2 | Creates member accounts from the spreadsheet and the first admin. Server-to-server: called by `scripts/import-members.mjs` and `scripts/create-admin.mjs`. Access: a signed-in user with `members.import`, or a temporary bootstrap token (secret `IMPORT_BOOTSTRAP_TOKEN`). The token is removed after use; to import again, create a new random token, set it with `supabase secrets set --env-file <file outside the repo>`, keep a copy outside the repo, and unset it afterwards. The rules are in `_shared/member-import-rules.ts` (unit-tested in `tests/unit/member-import.test.js`). |

Deploy (no Docker): `npx supabase@2.118.0 functions deploy <name> --use-api --project-ref <ref>`.
