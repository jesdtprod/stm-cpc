// Runs the Supabase security and performance advisors on the linked project and fails on any finding
// that is not in the accepted list below. Every accepted finding says why, so an exception is a decision
// someone made and wrote down, not something silently ignored.
// Run: deno task db:advisors
const ACCEPTED = {
  auth_leaked_password_protection:
    "Needs the Pro plan (HaveIBeenPwned check). The club is on the free plan. The first-password rule is predictable by design, so " +
    "the compensating controls in docs/SECURITY.md section 2 (Turnstile, lockout, forced change) apply. Revisit if the plan changes.",
};

const { code, stdout, stderr } = await new Deno.Command("npx", {
  args: [
    "supabase@2.118.0",
    "db",
    "advisors",
    "--linked",
    "--type",
    "all",
    "--level",
    "warn",
  ],
  stdout: "piped",
  stderr: "piped",
}).output();
const out = new TextDecoder().decode(stdout);
let findings = [];
try {
  findings = JSON.parse(out).results ?? [];
} catch {
  if (
    code !== 0 ||
    !/No issues found/i.test(out + new TextDecoder().decode(stderr))
  ) {
    console.error(
      `could not read the advisor output:\n${out}\n${
        new TextDecoder().decode(stderr)
      }`,
    );
    Deno.exit(1);
  }
}
const accepted = findings.filter((f) => ACCEPTED[f.name]);
const open = findings.filter((f) => !ACCEPTED[f.name]);
for (const f of accepted) {
  console.log(`accepted: ${f.name} - ${ACCEPTED[f.name]}`);
}
for (const f of open) {
  console.error(
    `FINDING ${f.level} ${f.name}: ${f.title}\n  ${f.remediation ?? ""}`,
  );
}
console.log(
  open.length ? `${open.length} open finding(s)` : "advisors: no open findings",
);
Deno.exit(open.length ? 1 : 0);
