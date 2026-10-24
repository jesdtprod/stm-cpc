# tests/

pgTAP tests, one file per migration (`NNNN_name.test.sql`). Fake data only.
`deno task db:test [filter]` runs them against the linked project; each file
runs in a transaction that ends in ROLLBACK, so nothing is kept.
`supabase test db` (Docker) runs the same files locally. Write assertions as
top-level `select ok(...)`, `select is(...)`, `select throws_ok(...)` statements
(the runner logs each one), and keep `select no_plan();` and
`select * from finish();` in place.
