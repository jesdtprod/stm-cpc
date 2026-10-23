// Repository secret scan: fails if a tracked file looks like it holds a secret.
const rules = [
  ["private key block", /-----BEGIN [A-Z ]*PRIVATE KEY-----/],
  ["Supabase secret key", /sb_secret_[A-Za-z0-9_-]{10,}/],
  [
    "JWT with service_role",
    /eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+/,
  ],
  ["Turnstile secret key", /\b0x4[A-Za-z0-9_-]{30,}\b/],
  [
    "password assignment",
    /\b(?:password|passwd|db_password)\s*[:=]\s*["'][^"'\s]{6,}["']/i,
  ],
];

const git = new Deno.Command("git", {
  args: ["ls-files", "-z"],
  stdout: "piped",
});
const files = new TextDecoder().decode((await git.output()).stdout).split("\0")
  .filter(Boolean);

const decode = (part) => {
  try {
    return JSON.parse(atob(part.replace(/-/g, "+").replace(/_/g, "/")));
  } catch {
    return null;
  }
};

let bad = 0;
for (const f of files) {
  let text;
  try {
    text = await Deno.readTextFile(f);
  } catch {
    continue;
  }
  for (const [name, re] of rules) {
    const m = text.match(re);
    if (!m) continue;
    if (name === "JWT with service_role") {
      const role = decode(m[0].split(".")[1])?.role;
      if (role !== "service_role") continue;
    }
    console.error(`${f}: possible ${name}`);
    bad++;
  }
}
if (bad) Deno.exit(1);
console.log(`check-secrets: ${files.length} files clean`);
