// Free-plan backup: exports every table of the linked Supabase project to JSON files
// under ~/cpc-backups/<timestamp>/ (outside the repository: the files hold real data once
// members exist). The schema itself is the migrations in git; this captures the data.
// auth.users is exported WITHOUT password hashes: after a restore, members reset passwords.
// Run: deno task db:backup
import { join } from "node:path";

const home = Deno.env.get("USERPROFILE") ?? Deno.env.get("HOME");
if (!home) throw new Error("no home directory");
const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\..*/, "")
  .replace("T", "-");
const dir = join(home, "cpc-backups", stamp);
await Deno.mkdir(dir, { recursive: true });

async function run(cmd, args) {
  const p = await new Deno.Command(cmd, {
    args,
    stdout: "piped",
    stderr: "piped",
  }).output();
  const out = new TextDecoder().decode(p.stdout);
  if (p.code !== 0) {
    throw new Error(
      `${cmd} ${args.join(" ")} failed:\n${
        new TextDecoder().decode(p.stderr)
      }\n${out}`,
    );
  }
  return out;
}

async function query(sql) {
  const out = await run("npx", [
    "supabase",
    "db",
    "query",
    "--linked",
    sql,
    "-o",
    "json",
  ]);
  return JSON.parse(out.slice(out.indexOf("{"))).rows;
}

async function sha256(text) {
  const d = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(text),
  );
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

const tables = (await query(
  "select table_schema||'.'||table_name as t from information_schema.tables " +
    "where table_type = 'BASE TABLE' and table_schema in ('public', 'core') order by 1",
)).map((r) => r.t);

const manifest = {
  created_at: new Date().toISOString(),
  project_ref: null,
  git_commit: null,
  migrations: [],
  tables: {},
};
manifest.project_ref = (await Deno.readTextFile("supabase/.temp/project-ref"))
  .trim();
manifest.git_commit = (await run("git", ["rev-parse", "HEAD"])).trim();
try {
  manifest.migrations = (await query(
    "select version from supabase_migrations.schema_migrations order by 1",
  )).map((r) => r.version);
} catch {
  // no migration table: leave empty
}

const jobs = [
  ...tables.map((
    t,
  ) => [
    t,
    `select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) as data from ${t} x`,
  ]),
  [
    "auth.users",
    "select coalesce(jsonb_agg(jsonb_build_object('id', id, 'email', email, 'phone', phone, 'created_at', created_at, 'email_confirmed_at', email_confirmed_at, 'raw_app_meta_data', raw_app_meta_data, 'raw_user_meta_data', raw_user_meta_data)), '[]'::jsonb) as data from auth.users",
  ],
];

for (const [name, sql] of jobs) {
  const rows = await query(sql);
  const data = rows[0].data;
  const text = JSON.stringify(data, null, 1);
  await Deno.writeTextFile(join(dir, `${name}.json`), text);
  manifest.tables[name] = { rows: data.length, sha256: await sha256(text) };
  console.log(`${name}: ${data.length} rows`);
}

await Deno.writeTextFile(
  join(dir, "manifest.json"),
  JSON.stringify(manifest, null, 2),
);
console.log(`\nBackup written to ${dir}`);
