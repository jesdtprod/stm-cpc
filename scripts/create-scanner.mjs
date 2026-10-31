// Creates a scanner-only staff account: it can check members in by QR and do nothing else.
//   deno task members:create-scanner -- --member-no CPC-2026-90001 --name "Court Scanner" --password-file "<path outside the repo>"
//
// The Edge Function makes the account with a random password and returns it once. This script writes
// it to --password-file and prints only the member ID and the file's location, never the password.
// The file must be outside the repository; the script refuses a path inside it.
import { SUPABASE_URL } from "../web/supabase-config.js";

const args = Object.fromEntries(
  Deno.args.flatMap((a, i, all) =>
    a.startsWith("--") ? [[a.slice(2), all[i + 1]]] : []
  ),
);
const home = Deno.env.get("USERPROFILE") ?? Deno.env.get("HOME") ?? ".";
const memberNo = args["member-no"];
const name = args.name;
const passwordFile = args["password-file"];
const tokenFile = args["token-file"] ?? `${home}/cpc-import-token.txt`;
if (!memberNo || !name || !passwordFile) {
  console.error(
    'usage: --member-no CPC-2026-90001 --name "Court Scanner" --password-file <path outside the repo>',
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
  body: JSON.stringify({
    action: "create_scanner",
    member_no: memberNo,
    display_name: name,
  }),
});
const json = await res.json().catch(() => ({}));
if (!res.ok || !json.ok) {
  console.error(
    `create_scanner failed: HTTP ${res.status} ${json.code ?? ""}`,
  );
  Deno.exit(1);
}
await Deno.writeTextFile(
  passwordFile,
  `Capitol Pickleball Club - scanner account
Member ID: ${json.member_no}
First password: ${json.password}
` +
    `This account can only check members in. Change the password at the first sign-in, then delete this file.
`,
  { mode: 0o600 },
);
console.log(
  `scanner ${json.member_no} created; the password was saved to ${passwordFile}`,
);
