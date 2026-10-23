---
name: cpc-step-runner
description: Run the CPC web app production plan one step at a time. Use when asked what to do next, to start or continue a step, or to implement anything listed in docs/PLAN.md. Takes the next unchecked step, does only that step with minimal edits, gives verification commands, waits for pasted output, then ticks the checkbox.
---

# CPC step runner

Works through `docs/PLAN.md` one step at a time. Goal: correct work, small diffs, low token use.

## Procedure
1. **Find the step.** Search `docs/PLAN.md` for the first unchecked `[ ]` step (or the ID the user names). Read only that row, its "Done when", and the "Working rules" and "Open decisions" tables. Do not read other stages.
2. **Check blockers.** If an open decision listed for this step is unanswered, use its default and say so in one line. Ask only if the work cannot proceed without an answer.
3. **Load the right context.** Use the `cpc-conventions` skill. Open only the document sections it points to for this step (search for the heading; do not read whole files).
4. **Plan briefly.** List the files to create or change (3–8 lines). Prefer existing components, helpers, templates, and migration patterns.
5. **Do the work with minimal edits.**
   - Change only the lines needed. Never rewrite or regenerate a whole file for a small change.
   - Database: new migration files only, never edit an applied one. Tests in the same step.
   - Copy and adapt `templates/` examples when they exist.
   - Fake data only. No secrets. Never ask the user to paste `service_role`, passwords, or the Turnstile secret.
6. **Give verification.** Provide the exact commands (PowerShell on Windows unless stated) or dashboard checks that prove the "Done when" condition. Then **stop** and ask the user to paste the output. Do not start the next step.
7. **After the user pastes output:**
   - If it passes, tick the checkbox in `docs/PLAN.md` (targeted edit), update any document whose behavior changed, and suggest a commit message that begins with the step ID (for example `1.4 RBAC tables and seed`).
   - If it fails, diagnose from the output, fix with a minimal change, and repeat step 6.
8. **Blocked or partial.** Say exactly what is blocked and why. Never mark a step done on a successful build or syntax check alone.

## Response format (keep it short)
- One line: what step and what will be done.
- The change summary (files, one line each).
- The verification commands.
- One line: "Paste the output and I'll continue."

## Token rules
- No re-reading files already in context. Search for headings instead of loading whole documents.
- No long explanations of standards; link to the section instead.
- Reuse and edit; do not regenerate.
- One step per turn.

## Hard stops
Do not proceed if the step would: commit a secret or real member data, skip RLS, hard-delete data, edit an applied migration, or weaken a rule in `docs/SECURITY.md`. Report it instead.
