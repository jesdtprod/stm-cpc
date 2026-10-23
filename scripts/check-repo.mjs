// Repository hygiene checks: no private files tracked, no inline handlers or scripts in web/.
const git = new Deno.Command("git", {
  args: ["ls-files", "-z"],
  stdout: "piped",
});
const files = new TextDecoder().decode((await git.output()).stdout).split("\0")
  .filter(Boolean);

const forbidden = [
  /(^|\/)\.env(\..*)?$/,
  /members-import/i,
  /\.(pem|key|p12|dump|backup)$/,
  /(^|\/)supabase\/\.temp\//,
];
let bad = 0;
for (const f of files) {
  if (forbidden.some((re) => re.test(f)) && !f.endsWith(".env.example")) {
    console.error(`${f}: private file is tracked`);
    bad++;
  }
  if (f.startsWith("web/") && f.endsWith(".html")) {
    const html = await Deno.readTextFile(f);
    if (/\son[a-z]+\s*=\s*["']/i.test(html)) {
      console.error(`${f}: inline event handler`);
      bad++;
    }
    if (/<script(?![^>]*\ssrc=)[^>]*>/i.test(html)) {
      console.error(`${f}: inline script`);
      bad++;
    }
  }
}
if (bad) Deno.exit(1);
console.log(`check-repo: ${files.length} files ok`);
