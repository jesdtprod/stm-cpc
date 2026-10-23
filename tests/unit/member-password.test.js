import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  checkPasswordPolicy,
  firstPassword,
} from "../../supabase/functions/_shared/password-policy.ts";
import {
  FRESH_SECONDS,
  handle,
} from "../../supabase/functions/member-password/handler.ts";

const CTX = { member_no: "CPC-2026-00001", date_of_birth: "1985-12-21" };

// ---------- policy
Deno.test("password policy: length, and a long unrelated passphrase is fine", () => {
  assert.deepEqual(checkPasswordPolicy("Short1!", CTX), ["too_short"]);
  assert.deepEqual(
    checkPasswordPolicy("blue-tiger-jumps-over-5-fences", CTX),
    [],
  );
  assert.deepEqual(
    checkPasswordPolicy("correct horse battery staple", CTX),
    [],
  );
  assert.deepEqual(
    checkPasswordPolicy("x".repeat(129), CTX).includes("too_long"),
    true,
  );
});

Deno.test("password policy: the first password, in any case, is refused", () => {
  assert.equal(firstPassword(CTX), "0000112211985");
  assert.ok(
    checkPasswordPolicy("0000112211985", CTX).includes("first_password"),
  );
  assert.equal(
    firstPassword({ member_no: "CPC-2026-00001", date_of_birth: null }),
    null,
  );
});

Deno.test("password policy: nothing built from the member ID or birth date", () => {
  for (
    const pw of [
      "xx-cpc-2026-00001-xx",
      "my cpc202600001 key",
      "Id00001-and-more-words",
      "mine 202600001 okay",
    ]
  ) {
    assert.ok(checkPasswordPolicy(pw, CTX).includes("contains_member_id"), pw);
  }
  for (
    const pw of [
      "tiger12211985tiger",
      "tiger21121985tiger",
      "tiger19851221tiger",
      "tiger-12/21/1985-x",
      "tigers1221851",
    ]
  ) {
    const problems = checkPasswordPolicy(pw, CTX);
    assert.ok(
      problems.includes("contains_birth_date") || pw === "tigers1221851",
      `${pw}: ${problems}`,
    );
  }
  assert.deepEqual(checkPasswordPolicy("tiger-lily-moves-quietly", CTX), []);
  assert.deepEqual(
    checkPasswordPolicy("tiger-lily-moves-quietly", {
      member_no: "CPC-2026-00001",
      date_of_birth: null,
    }),
    [],
  );
});

Deno.test("password policy: very common choices and patterns", () => {
  for (
    const pw of [
      "Password123456",
      "capitolpickleball1",
      "qwertyuiop1234",
      "iloveyou-iloveyou",
    ]
  ) {
    assert.ok(checkPasswordPolicy(pw, CTX).includes("too_common"), pw);
  }
  assert.ok(
    checkPasswordPolicy("aaaaaaaaaaaaaaaa", CTX).includes("no_variety"),
  );
  assert.ok(
    checkPasswordPolicy("abababababababab", CTX).includes("no_variety"),
  );
});

// ---------- handler
const NOW = 1_800_000_000_000;
const ORIGIN = "https://jesdtprod.github.io";

function world(over = {}) {
  const s = { set: [], changed: [], others: 0, failures: new Map(), logs: [] };
  const deps = {
    allowedOrigins: [ORIGIN],
    now: () => NOW,
    sha256: (t) =>
      Promise.resolve(createHash("sha256").update(t).digest("hex")),
    caller: () =>
      Promise.resolve(
        over.caller === undefined
          ? { userId: "u1", issuedAt: NOW / 1000 - 60 }
          : over.caller,
      ),
    context: () =>
      Promise.resolve(
        over.context === undefined
          ? { ...CTX, member_id: "MEM1", status: "invited" }
          : over.context,
      ),
    isLocked: (keys) =>
      Promise.resolve(keys.some((k) => (s.failures.get(k) ?? 0) >= 10)),
    recordFailure: (k) => {
      s.failures.set(k, (s.failures.get(k) ?? 0) + 1);
      return Promise.resolve(false);
    },
    setPassword: (id, pw) => {
      s.set.push([id, pw]);
      return Promise.resolve(over.authOk ?? true);
    },
    passwordChanged: (id) => {
      s.changed.push(id);
      return Promise.resolve();
    },
    signOutOthers: () => {
      s.others++;
      return Promise.resolve();
    },
    log: (e) => s.logs.push(e),
  };
  return { deps, s };
}
const call = (body, { method = "POST", origin = ORIGIN, raw } = {}) =>
  new Request("https://example.test/member-password", {
    method,
    headers: {
      "content-type": "application/json",
      authorization: "Bearer t",
      ...(origin ? { origin } : {}),
    },
    body: method === "POST" ? (raw ?? JSON.stringify(body)) : undefined,
  });
const run = async (deps, body, opts) => {
  const res = await handle(call(body, opts), deps);
  return {
    status: res.status,
    body: res.status === 204 ? null : await res.json().catch(() => null),
    headers: res.headers,
  };
};
const GOOD = "blue-tiger-jumps-over-5-fences";

Deno.test("password change: a good password is set, the flag hook runs, other sessions end", async () => {
  const { deps, s } = world();
  const r = await run(deps, { new_password: GOOD });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { ok: true });
  assert.deepEqual(s.set, [["u1", GOOD]]);
  assert.deepEqual(s.changed, ["MEM1"]);
  assert.equal(s.others, 1);
  assert.equal(JSON.stringify(r.body).includes(GOOD), false);
  assert.equal(r.headers.get("cache-control"), "no-store");
  assert.equal(r.headers.get("access-control-allow-origin"), ORIGIN);
});

Deno.test("password change: a weak password is refused with reasons, and nothing is changed", async () => {
  const { deps, s } = world();
  const r = await run(deps, { new_password: "0000112211985" });
  assert.equal(r.status, 400);
  assert.equal(r.body.code, "weak_password");
  assert.ok(r.body.problems.includes("first_password"));
  assert.equal(s.set.length, 0);
  assert.equal(s.changed.length, 0);
  assert.equal(
    JSON.stringify(r.body).includes("0000112211985"),
    false,
    "the password is not echoed",
  );
});

Deno.test("password change: no valid session, no change", async () => {
  const { deps, s } = world({ caller: null });
  const r = await run(deps, { new_password: GOOD });
  assert.equal(r.status, 401);
  assert.deepEqual(r.body, { ok: false, code: "unauthorized" });
  assert.equal(s.set.length, 0);
});

Deno.test("password change: an old session must sign in again first", async () => {
  const { deps, s } = world({
    caller: { userId: "u1", issuedAt: NOW / 1000 - FRESH_SECONDS - 5 },
  });
  const r = await run(deps, { new_password: GOOD });
  assert.equal(r.status, 401);
  assert.equal(r.body.code, "sign_in_again");
  assert.equal(s.set.length, 0);
});

Deno.test("password change: a user who is not an allowed member state is refused", async () => {
  for (
    const context of [null, { ...CTX, member_id: "M", status: "suspended" }, {
      ...CTX,
      member_id: "M",
      status: "archived",
    }]
  ) {
    const { deps, s } = world({ context });
    assert.equal((await run(deps, { new_password: GOOD })).status, 403);
    assert.equal(s.set.length, 0);
  }
});

Deno.test("password change: repeated weak attempts are throttled", async () => {
  const { deps, s } = world();
  for (let i = 0; i < 10; i++) {
    assert.equal((await run(deps, { new_password: "short" })).status, 400);
  }
  const r = await run(deps, { new_password: GOOD });
  assert.equal(r.status, 429);
  assert.equal(s.set.length, 0);
});

Deno.test("password change: Auth failing is reported, and the member is not marked as changed", async () => {
  const { deps, s } = world({ authOk: false });
  const r = await run(deps, { new_password: GOOD });
  assert.equal(r.status, 503);
  assert.equal(s.changed.length, 0);
});

Deno.test("password change: input and origin checks", async () => {
  const { deps } = world();
  for (const body of [{}, { new_password: 5 }, { new_password: "" }, [], "x"]) {
    assert.equal((await run(deps, body)).status, 400, JSON.stringify(body));
  }
  assert.equal((await run(deps, null, { raw: "{oops" })).status, 400);
  assert.equal((await run(deps, null, { raw: "x".repeat(3000) })).status, 413);
  assert.equal(
    (await run(deps, { new_password: GOOD }, {
      origin: "https://evil.example",
    })).status,
    403,
  );
  assert.equal((await run(deps, null, { method: "OPTIONS" })).status, 204);
  assert.equal((await run(deps, null, { method: "GET" })).status, 405);
});
