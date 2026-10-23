// Fills in details for members who are already imported, from the club's spreadsheet: last, first and middle
// name, extension (suffix), gender and the emergency contact (PLAN 3.4 follow-up).
//   deno task members:enrich -- --file "<path to xlsx>" [--dry-run] [--token-file <path>]
//
// Only EMPTY fields are filled: anything a member or an admin has entered is never overwritten, and the
// display name is never touched. The file is read in place; nothing is printed except counts.
import {
  analyzeFile,
} from "../supabase/functions/_shared/member-import-rules.ts";
import { SUPABASE_URL } from "../web/supabase-config.js";

const args = {};
for (let i = 0; i < Deno.args.length; i++) {
  if (!Deno.args[i].startsWith("--")) continue;
  const next = Deno.args[i + 1];
  if (next === undefined || next.startsWith("--")) {
    args[Deno.args[i].slice(2)] = true;
  } else {
    args[Deno.args[i].slice(2)] = next;
    i++;
  }
}
const file = args.file;
if (!file) {
  console.error("missing --file <path to the .xlsx>");
  Deno.exit(1);
}
const home = Deno.env.get("USERPROFILE") ?? Deno.env.get("HOME") ?? ".";
const tokenFile = args["token-file"] ?? `${home}/cpc-import-token.txt`;
const BATCH = 40;

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
  console.error(
    `could not read the file: ${new TextDecoder().decode(read.stderr).trim()}`,
  );
  Deno.exit(1);
}
const raw = JSON.parse(new TextDecoder().decode(read.stdout));
const analysis = analyzeFile(raw);
const withDetails = analysis.rows.filter((r) =>
  r.details && Object.values(r.details).some((v) => v !== null)
);
const has = (key) => withDetails.filter((r) => r.details[key] !== null).length;
console.log(
  `rows to look at: ${withDetails.length} of ${analysis.rows.length} | with last name: ${
    has("last_name")
  }, first name: ${has("first_name")}, ` +
    `middle name: ${has("middle_name")}, extension: ${has("suffix")}, gender: ${
      has("gender")
    }, emergency contact: ${has("emergency_phone")}`,
);
if (args["dry-run"]) {
  console.log("dry run: nothing was sent");
  Deno.exit(0);
}

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
        console.error(
          `${body.action} failed: HTTP ${res.status} ${json.code ?? ""}`,
        );
        Deno.exit(1);
      }
    } catch (e) {
      if (attempt === 3) {
        console.error(`${body.action} failed: ${e.message}`);
        Deno.exit(1);
      }
    }
    await new Promise((r) => setTimeout(r, 1500 * attempt));
  }
}

const tally = { updated: 0, unchanged: 0, not_found: 0, failed: 0 };
for (let i = 0; i < withDetails.length; i += BATCH) {
  const rows = withDetails.slice(i, i + BATCH).map((r) => ({
    source_row: r.source_row,
    member_no: r.member_no,
    display_name: r.display_name,
    dob: r.dob,
    needs_new_id: r.needs_new_id,
    details: r.details,
  }));
  const { results } = await call({ action: "enrich", rows });
  for (const r of results) tally[r.outcome]++;
  console.log(
    `  sent ${Math.min(i + BATCH, withDetails.length)}/${withDetails.length}`,
  );
}
console.log(
  `done: ${tally.updated} updated, ${tally.unchanged} already complete, ${tally.not_found} not found, ${tally.failed} failed`,
);
Deno.exit(tally.failed ? 2 : 0);
