// Runs the pgTAP files in supabase/tests/ against the linked Supabase project.
// Each file runs inside its own transaction that ends in ROLLBACK, so nothing is kept.
// Local `supabase test db` needs Docker; this runner needs only a logged-in, linked CLI.
//
// The API returns only the last statement's rows, so the runner rewrites each top-level
// assertion (`select ok(...)`, `select is(...)`, ...) to log its output into a temp table,
// and replaces `select * from finish();` with a query that returns the log.
// Run: deno run --allow-read=supabase/tests --allow-write=supabase/.temp --allow-run=npx scripts/run-db-tests.mjs [name-filter]

const filter = Deno.args[0] ?? "";
const files = [];
for await (const entry of Deno.readDir("supabase/tests")) {
  if (
    entry.isFile && entry.name.endsWith(".test.sql") &&
    entry.name.includes(filter)
  ) {
    files.push(entry.name);
  }
}
files.sort();

const ASSERT =
  /^select (ok|is|isnt|throws_ok|lives_ok|results_eq|results_ne|set_eq|bag_eq|is_empty|isa_ok|matches|doesnt_match|cmp_ok|performs_ok|throws_like|throws_matching|has_\w+|hasnt_\w+|col_\w+|fk_ok|is_\w+|isnt_\w+|pass|fail)\(/gm;

function transform(sql) {
  let out = sql.replace(
    /^select no_plan\(\);/m,
    "select no_plan();\ncreate temp table _out(n serial, line text);\ngrant all on pg_temp._out to public;\ngrant all on sequence pg_temp._out_n_seq to public;",
  );
  out = out.replace(ASSERT, "insert into pg_temp._out(line) select $1(");
  out = out.replace(
    /^select \* from finish\(\);/m,
    "select line from pg_temp._out order by n;",
  );
  return out;
}

await Deno.mkdir("supabase/.temp", { recursive: true });
let failed = 0;
for (const name of files) {
  const src = await Deno.readTextFile(`supabase/tests/${name}`);
  const tmp = `supabase/.temp/run-${name}`;
  await Deno.writeTextFile(tmp, transform(src));
  const cmd = new Deno.Command("npx", {
    args: [
      "supabase@2.118.0",
      "db",
      "query",
      "--linked",
      "-f",
      tmp,
      "-o",
      "json",
    ],
    stdout: "piped",
    stderr: "piped",
  });
  const { code, stdout, stderr } = await cmd.output();
  const out = new TextDecoder().decode(stdout);
  const err = new TextDecoder().decode(stderr);
  let lines = [];
  try {
    lines = (JSON.parse(out).rows ?? []).map((r) => String(r.line));
  } catch {
    // reported below
  }
  if (code !== 0 || lines.length === 0) {
    failed++;
    console.error(`FAIL ${name}: could not run\n${out}\n${err}`);
    continue;
  }
  const bad = lines.filter((l) => l.startsWith("not ok"));
  console.log(
    `${bad.length ? "FAIL" : "ok  "} ${name}: ${
      lines.length - bad.length
    }/${lines.length} passed`,
  );
  for (const l of bad) console.error(`  ${l.replaceAll("\n", "\n  ")}`);
  if (bad.length) failed++;
}
Deno.exit(failed ? 1 : 0);
