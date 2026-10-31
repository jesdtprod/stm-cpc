import assert from "node:assert/strict";
import { membershipApplicationsOpen } from "../../web/lib/auth-api.js";
import { SUPABASE_ANON_KEY } from "../../web/supabase-config.js";

Deno.test("membership availability: uses a fresh anonymous request without a member session", async () => {
  const result = await membershipApplicationsOpen((_url, init) => {
    assert.equal(init.cache, "no-store");
    assert.equal(init.method, "POST");
    assert.equal(init.headers.authorization, `Bearer ${SUPABASE_ANON_KEY}`);
    assert.equal(init.headers.apikey, SUPABASE_ANON_KEY);
    return Promise.resolve({ ok: true, json: () => Promise.resolve(true) });
  });
  assert.equal(result, true);
});
Deno.test("membership availability: a disabled setting remains closed", async () => {
  assert.equal(
    await membershipApplicationsOpen(() =>
      Promise.resolve({
        ok: true,
        json: () => Promise.resolve(false),
      })
    ),
    false,
  );
});
Deno.test("membership availability: errors and malformed responses are unavailable, never closed", async () => {
  for (
    const fetchFn of [
      () => Promise.reject(new Error("network")),
      () => Promise.resolve({ ok: false }),
      () => Promise.resolve({ ok: true, json: () => Promise.resolve("true") }),
      () => Promise.resolve({ ok: true, json: () => Promise.resolve(null) }),
    ]
  ) {
    await assert.rejects(() => membershipApplicationsOpen(fetchFn), {
      code: "unavailable",
    });
  }
});
