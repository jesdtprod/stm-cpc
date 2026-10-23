// Imports the club's existing members from the spreadsheet (PLAN 3.2).
//   deno task members:import -- --file "<path to xlsx>" [--dry-run] [--token-file <path>] [--report-dir <dir>]
//
// The file stays where it is and is never copied. This script reads it (through read-members-xlsx.py),
// applies the whole-file rules, and sends only the importable rows, in small batches, to the
// member-import Edge Function, which creates the accounts. Nothing is printed except counts and row
// numbers: no names, IDs, birth dates, numbers or passwords. The first passwords are computed inside the
// Edge Function and never come back here.
//
// --dry-run reads and analyses the file and prints the counts; it sends nothing.
import { analyzeFile } from "../supabase/functions/_shared/member-import-rules.ts";
import { SUPABASE_URL } from "../web/supabase-config.js";

const args = parseArgs(Deno.args);
const file = args.file;
if (!file) fail("missing --file <path to the .xlsx>");
const home = Deno.env.get("USERPROFILE") ?? Deno.env.get("HOME") ?? ".";
const tokenFile = args["token-file"] ?? `${home}/cpc-import-token.txt`;
const reportDir = args["report-dir"] ?? `${home}/cpc-import-reports`;
const BATCH = 40;

function parseArgs(list) {
  const out = {};
  for (let i = 0; i < list.length; i++) {
    if (!list[i].startsWith("--")) continue;
    const key = list[i].slice(2);
    const next = list[i + 1];
    if (next === undefined || next.startsWith("--")) out[key] = true;
    else {
      out[key] = next;
      i++;
    }
  }
  return out;
}

function fail(message) {
  console.error(message);
  Deno.exit(1);
}

// ---- read the file
const read = await new Deno.Command("python", {
  args: [
    decodeURIComponent(
      new URL("./read-members-xlsx.py", import.meta.url).pathname,
    ).replace(/^\/([A-Za-z]:)/, "$1"),
    file,
  ],
  stdout: "piped",
  stderr: "piped",
}).output();
if (read.code !== 0) {
  fail(
    `could not read the file: ${new TextDecoder().decode(read.stderr).trim()}`,
  );
}
const raw = JSON.parse(new TextDecoder().decode(read.stdout));
const analysis = analyzeFile(raw);
const byCode = {};
for (const i of analysis.issues) {
  byCode[i.issue_code] = (byCode[i.issue_code] ?? 0) + 1;
}
const c = analysis.counts;
console.log(
  `file: ${c.total} rows | not imported (no ID): ${c.skipped_no_id} | held back: ${c.held_back} | ` +
    `to import: ${c.importable} (${c.with_account} with an account, ${c.without_account} waiting for a birth date)`,
);
console.log(`issues by kind: ${JSON.stringify(byCode)}`);
if (args["dry-run"]) {
  console.log("dry run: nothing was sent");
  Deno.exit(0);
}

// ---- send it
const token = (await Deno.readTextFile(tokenFile)).trim();
const url = `${SUPABASE_URL}/functions/v1/member-import`;

async function call(body) {
  for (let attempt = 1;; attempt++) {
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-import-token": token,
        },
        body: JSON.stringify(body),
      });
      const json = await res.json().catch(() => ({}));
      if (res.ok && json.ok) return json;
      if (res.status < 500 || attempt === 3) {
        fail(`${body.action} failed: HTTP ${res.status} ${json.code ?? ""}`);
      }
    } catch (e) {
      if (attempt === 3) fail(`${body.action} failed: ${e.message}`);
    }
    await new Promise((r) => setTimeout(r, 1500 * attempt));
  }
}

const bytes = await Deno.readFile(file);
const digest = await crypto.subtle.digest("SHA-256", bytes);
const sha = [...new Uint8Array(digest)].map((b) =>
  b.toString(16).padStart(2, "0")
).join("");

const { batch_id: batchId } = await call({
  action: "begin",
  file_sha256: sha,
  row_count: c.total,
});
console.log(`batch ${batchId} started`);

for (let i = 0; i < analysis.issues.length; i += 400) {
  await call({
    action: "issues",
    batch_id: batchId,
    issues: analysis.issues.slice(i, i + 400),
  });
}

const tally = { created: 0, created_no_account: 0, existing: 0, failed: 0 };
const failures = [];
for (let i = 0; i < analysis.rows.length; i += BATCH) {
  const { results } = await call({
    action: "rows",
    batch_id: batchId,
    rows: analysis.rows.slice(i, i + BATCH),
  });
  for (const r of results) {
    tally[r.outcome]++;
    if (r.outcome === "failed") {
      failures.push({ row: r.source_row, reason: r.reason });
    }
  }
  console.log(
    `  sent ${
      Math.min(i + BATCH, analysis.rows.length)
    }/${analysis.rows.length}`,
  );
}

await call({
  action: "finish",
  batch_id: batchId,
  created: tally.created + tally.created_no_account,
  skipped: c.skipped_no_id + tally.existing,
  held_back: c.held_back,
  failed: tally.failed,
});

const report = {
  batch_id: batchId,
  finished_at: new Date().toISOString(),
  file_sha256: sha,
  counts: c,
  result: tally,
  issues_by_kind: byCode,
  held_back_rows: analysis.issues
    .filter((i) =>
      ["duplicate_member_no", "invalid_member_no", "missing_name"].includes(
        i.issue_code,
      )
    )
    .map((i) => ({ row: i.source_row, code: i.issue_code })),
  failures,
};
await Deno.mkdir(reportDir, { recursive: true });
const reportPath = `${reportDir}/import-${batchId}.json`;
await Deno.writeTextFile(reportPath, JSON.stringify(report, null, 2));
console.log(
  `done: ${tally.created} created with an account, ${tally.created_no_account} created without, ` +
    `${tally.existing} already there, ${tally.failed} failed`,
);
console.log(`report (row numbers and codes only): ${reportPath}`);
Deno.exit(tally.failed ? 2 : 0);
