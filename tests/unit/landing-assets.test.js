import assert from "node:assert/strict";

// The landing page must load fast: every image it (or the shell it sits in) names stays small.
const MAX_BYTES = 120 * 1024;
const files = ["web/pages-home.js", "web/index.html", "web/shell.js"];

Deno.test("landing: every referenced icon is small", async () => {
  const names = new Set();
  for (const f of files) {
    const text = await Deno.readTextFile(f);
    for (
      const m of text.matchAll(/icons\/[A-Za-z0-9_.-]+\.(?:png|webp|svg)/g)
    ) {
      names.add(m[0]);
    }
  }
  assert.ok(names.size > 0);
  for (const n of names) {
    const { size } = await Deno.stat(`web/${n}`);
    assert.ok(size <= MAX_BYTES, `${n} is ${size} bytes, over ${MAX_BYTES}`);
  }
});

Deno.test("landing: the public information comes from one narrow public function", async () => {
  const text = await Deno.readTextFile("web/pages-home.js");
  const calls = [
    ...text.matchAll(/api\.rpc\("(public_landing_info|club_home_stats)"/g),
  ].map((m) => m[1]);
  assert.deepEqual([...new Set(calls)].sort(), [
    "club_home_stats",
    "public_landing_info",
  ]);
  // no secret-looking values in the landing code
  assert.equal(
    /service_role|sb_secret|password\s*[:=]\s*["']/i.test(text),
    false,
  );
});
