// Creates the first administrator account (PLAN 3.2), or gives an existing administrator a new password (--reset).
//   deno task members:create-admin -- --member-no CPC-2026-00000 --name "Club Administrator" --password-file "<path outside the repo>"
//
// The Edge Function makes the account with a random password and returns it once. This script writes
// it to --password-file and prints only the member ID and the file's location, never the password.
// The file must be outside the repository; the script refuses a path inside it.
import { SUPABASE_URL } from "../web/supabase-config.js";

const reset = Deno.args.includes("--reset");
const args = Object.fromEntries(
  Deno.args.flatMap((
    a,
    i,
    all,
  ) => (a.startsWith("--") && a !== "--reset"
    ? [[a.slice(2), all[i + 1]]]
    : [])
  ),
);
const home = Deno.env.get("USERPROFILE") ?? Deno.env.get("HOME") ?? ".";
const memberNo = args["member-no"];
const name = args.name;
const passwordFile = args["password-file"];
const tokenFile = args["token-file"] ?? `${home}/cpc-import-token.txt`;
if (!memberNo || (!reset && !name) || !passwordFile) {
  console.error(
    'usage: --member-no CPC-2026-00000 --name "Club Administrator" --password-file <path outside the repo>  (add --reset for a new password for an existing admin; --name is then not needed)',
  );
  Deno.exit(1);
}

const repoRoot = Deno.cwd().replaceAll("\\", "/").toLowerCase();
const target =
  (await Deno.realPath(passwordFile.replace(/[^/\\]*$/, "") || ".").catch(() =>
    passwordFile
  ))
    .replaceAll("\\", "/").toLowerCase();
if (target.startsWith(repoRoot)) {
  console.error("refusing: the password file must be outside the repository");
  Deno.exit(1);
}

const token = (await Deno.readTextFile(tokenFile)).trim();
const res = await fetch(`${SUPABASE_URL}/functions/v1/member-import`, {
  method: "POST",
  headers: { "content-type": "application/json", "x-import-token": token },
  body: JSON.stringify(
    reset
      ? { action: "reset_admin_password", member_no: memberNo }
      : { action: "create_admin", member_no: memberNo, display_name: name },
  ),
});
const json = await res.json().catch(() => ({}));
if (!res.ok || !json.ok) {
  console.error(
    `${reset ? "reset" : "create_admin"} failed: HTTP ${res.status} ${
      json.code ?? ""
    }`,
  );
  Deno.exit(1);
}
await Deno.writeTextFile(
  passwordFile,
  `Capitol Pickleball Club - ${
    reset ? "administrator password reset" : "first administrator"
  }\nMember ID: ${json.member_no}\nFirst password: ${json.password}\n` +
    `Change this password the first time you sign in, then delete this file.\n`,
  { mode: 0o600 },
);
console.log(
  `admin ${json.member_no} ${
    reset ? "password reset" : "created"
  }; the password was saved to ${passwordFile}`,
);
