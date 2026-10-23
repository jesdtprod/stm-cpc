import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  EMAIL_DOMAIN,
  GENERIC_MESSAGE,
  handle,
  internalEmail,
  LIMITS,
  normalizeMemberId,
} from "../../supabase/functions/member-login/handler.ts";

const ORIGIN = "https://jesdtprod.github.io";
const NOW = Date.parse("2026-11-01T00:00:00Z");

/** A fake world: one member, and counters held in memory. */
function world(overrides = {}) {
  const state = {
    failures: new Map(),
    locked: new Set(),
    revoked: [],
    cleared: [],
    succeeded: [],
    signIns: [],
    logs: [],
  };
  const member = {
    member_id: "01H0000000000000000000MEM1",
    member_no: "CPC-2026-00001",
    status: "imported",
    must_change_password: true,
    temp_password_expires_at: "2026-12-01T00:00:00Z",
  };
  const deps = {
    allowedOrigins: [ORIGIN],
    now: () => NOW,
    sha256: (t) =>
      Promise.resolve(createHash("sha256").update(t).digest("hex")),
    isLocked: (keys) => Promise.resolve(keys.some((k) => state.locked.has(k))),
    recordFailure: (key, max) => {
      const n = (state.failures.get(key) ?? 0) + 1;
      state.failures.set(key, n);
      if (n >= max) state.locked.add(key);
      return Promise.resolve(n >= max);
    },
    clearFailures: (key) => {
      state.cleared.push(key);
      state.failures.delete(key);
      return Promise.resolve();
    },
    signIn: (email, password, captcha) => {
      state.signIns.push({ email, password, captcha });
      if (!captcha || captcha === "bad") {
        return Promise.resolve({ ok: false, reason: "captcha" });
      }
      if (
        email === internalEmail(member.member_no) &&
        password === "0000112212025"
      ) {
        return Promise.resolve({
          ok: true,
          userId: "u1",
          session: { access_token: "AT", refresh_token: "RT" },
        });
      }
      return Promise.resolve({ ok: false, reason: "invalid" });
    },
    revoke: (t) => {
      state.revoked.push(t);
      return Promise.resolve();
    },
    memberState: () =>
      Promise.resolve({ ...member, ...(overrides.member ?? {}) }),
    loginSucceeded: (id) => {
      state.succeeded.push(id);
      return Promise.resolve();
    },
    log: (e) => state.logs.push(e),
    ...(overrides.deps ?? {}),
  };
  return { deps, state, member };
}

function request(
  body,
  { method = "POST", origin = ORIGIN, ip = "203.0.113.7", raw } = {},
) {
  const headers = { "content-type": "application/json", "x-forwarded-for": ip };
  if (origin) headers.origin = origin;
  return new Request("https://example.test/member-login", {
    method,
    headers,
    body: method === "POST" ? (raw ?? JSON.stringify(body)) : undefined,
  });
}

const good = {
  member_id: "CPC-2026-00001",
  password: "0000112212025",
  captcha_token: "tok",
};
const read = async (res) => ({ status: res.status, body: await res.json() });

Deno.test("login: the member ID is trimmed and uppercased; the internal address is lowercase", () => {
  assert.equal(normalizeMemberId("  cpc-2026-00001 "), "CPC-2026-00001");
  assert.equal(
    internalEmail("CPC-2026-00001"),
    `cpc-2026-00001@${EMAIL_DOMAIN}`,
  );
});

Deno.test("login: a correct ID and password returns the session and the forced-change flag", async () => {
  const { deps, state } = world();
  const res = await handle(
    request({ ...good, member_id: " cpc-2026-00001 " }),
    deps,
  );
  const { status, body } = await read(res);
  assert.equal(status, 200);
  assert.deepEqual(body, {
    ok: true,
    session: { access_token: "AT", refresh_token: "RT" },
    must_change_password: true,
  });
  assert.equal(state.signIns[0].email, "cpc-2026-00001@members.cpc.app");
  assert.deepEqual(state.succeeded, ["01H0000000000000000000MEM1"]);
  assert.equal(
    state.cleared.length,
    1,
    "the member's failure counter is cleared",
  );
  assert.equal(res.headers.get("access-control-allow-origin"), ORIGIN);
  assert.equal(res.headers.get("cache-control"), "no-store");
});

Deno.test("login: unknown ID, wrong password and malformed ID give the identical response", async () => {
  const answers = [];
  for (
    const body of [
      { ...good, member_id: "CPC-2026-99999" }, // no such member
      { ...good, password: "wrong-password" }, // wrong password
      { ...good, member_id: "not an id" }, // malformed
      { ...good, member_id: "CPC-26-1" }, // malformed
    ]
  ) {
    const { deps } = world();
    answers.push(await read(await handle(request(body), deps)));
  }
  for (const a of answers) {
    assert.equal(a.status, 401);
    assert.deepEqual(a.body, {
      ok: false,
      code: "invalid_credentials",
      message: GENERIC_MESSAGE,
    });
  }
  assert.deepEqual(answers[0], answers[1]);
  assert.deepEqual(answers[1], answers[2]);
  assert.deepEqual(answers[2], answers[3]);
});

Deno.test("login: every attempt, even a malformed ID, goes through Auth (same cost)", async () => {
  const { deps, state } = world();
  await handle(request({ ...good, member_id: "garbage!!" }), deps);
  await handle(request({ ...good, member_id: "CPC-2026-99999" }), deps);
  assert.equal(state.signIns.length, 2);
  assert.match(
    state.signIns[0].email,
    /^invalid-[0-9a-f]{24}@members\.cpc\.app$/,
  );
  assert.equal(state.signIns[1].email, "cpc-2026-99999@members.cpc.app");
});

Deno.test("login: five failures lock an ID, and the lock looks like any other failure", async () => {
  const { deps, state } = world();
  for (let i = 0; i < LIMITS.idMaxFailures; i++) {
    const r = await read(
      await handle(
        request({ ...good, password: "nope" }, { ip: `198.51.100.${i}` }),
        deps,
      ),
    );
    assert.equal(r.status, 401);
  }
  // Even the right password is refused now, with the same generic answer.
  const locked = await read(
    await handle(request(good, { ip: "198.51.100.200" }), deps),
  );
  assert.equal(locked.status, 401);
  assert.deepEqual(locked.body, {
    ok: false,
    code: "invalid_credentials",
    message: GENERIC_MESSAGE,
  });
  assert.equal(
    state.signIns.length,
    LIMITS.idMaxFailures,
    "a locked attempt never reaches Auth",
  );
  // An ID that does not exist is locked in exactly the same way.
  for (let i = 0; i < LIMITS.idMaxFailures; i++) {
    await handle(
      request({ ...good, member_id: "CPC-2026-77777", password: "x" }, {
        ip: `192.0.2.${i}`,
      }),
      deps,
    );
  }
  const ghost = await read(
    await handle(
      request({ ...good, member_id: "CPC-2026-77777" }, { ip: "192.0.2.250" }),
      deps,
    ),
  );
  assert.deepEqual(ghost, locked);
});

Deno.test("login: thirty failures from one address lock the address for every ID", async () => {
  const { deps } = world();
  for (let i = 0; i < LIMITS.ipMaxFailures; i++) {
    await handle(
      request({
        ...good,
        member_id: `CPC-2026-${String(10000 + i)}`,
        password: "x",
      }, { ip: "203.0.113.99" }),
      deps,
    );
  }
  const r = await read(
    await handle(request(good, { ip: "203.0.113.99" }), deps),
  );
  assert.equal(r.status, 401);
  const other = await read(
    await handle(request(good, { ip: "203.0.113.100" }), deps),
  );
  assert.equal(other.status, 200, "another address is unaffected");
});

Deno.test("login: a bad or missing CAPTCHA is reported as captcha_failed and never locks a member ID", async () => {
  const { deps, state } = world();
  for (let i = 0; i < 10; i++) {
    const r = await read(
      await handle(request({ ...good, captcha_token: "bad" }), deps),
    );
    assert.equal(r.status, 400);
    assert.equal(r.body.code, "captcha_failed");
  }
  const idKeys = [...state.failures.keys()].filter((k) => k.startsWith("id:"));
  assert.equal(
    idKeys.length,
    0,
    "CAPTCHA failures are counted against the address only",
  );
  const ok = await read(
    await handle(request(good, { ip: "198.51.100.77" }), deps),
  );
  assert.equal(ok.status, 200);
});

Deno.test("login: after correct credentials, a disabled account gets no session", async () => {
  for (const status of ["suspended", "rejected", "archived"]) {
    const { deps, state } = world({ member: { status } });
    const r = await read(await handle(request(good), deps));
    assert.equal(r.status, 403);
    assert.equal(r.body.code, "account_disabled");
    assert.equal("session" in r.body, false);
    assert.deepEqual(
      state.revoked,
      ["AT"],
      `${status}: the Auth session is revoked`,
    );
    assert.equal(state.succeeded.length, 0);
  }
  for (const status of ["imported", "invited", "pending_approval", "active"]) {
    const { deps } = world({ member: { status } });
    assert.equal((await handle(request(good), deps)).status, 200, status);
  }
});

Deno.test("login: an expired first password is refused after correct credentials", async () => {
  const { deps, state } = world({
    member: { temp_password_expires_at: "2026-10-01T00:00:00Z" },
  });
  const r = await read(await handle(request(good), deps));
  assert.equal(r.status, 403);
  assert.equal(r.body.code, "password_expired");
  assert.deepEqual(state.revoked, ["AT"]);
  // A member who already changed their password is not affected by the old expiry.
  const done = world({
    member: {
      must_change_password: false,
      temp_password_expires_at: "2026-10-01T00:00:00Z",
    },
  });
  assert.equal((await handle(request(good), done.deps)).status, 200);
});

Deno.test("login: a valid Auth user who is not this member gets the generic answer", async () => {
  const none = world({ deps: { memberState: () => Promise.resolve(null) } });
  const r = await read(await handle(request(good), none.deps));
  assert.equal(r.status, 401);
  assert.equal(r.body.code, "invalid_credentials");
  assert.deepEqual(none.state.revoked, ["AT"]);
  const other = world({ member: { member_no: "CPC-2026-00002" } });
  assert.equal(
    (await handle(request(good), other.deps)).status,
    401,
    "the session must belong to the ID that was typed",
  );
});

Deno.test("login: input is validated, and the body is size-limited", async () => {
  const { deps, state } = world();
  for (
    const body of [
      {},
      { member_id: "CPC-2026-00001", password: "x" },
      { member_id: "CPC-2026-00001", password: "", captcha_token: "t" },
      { member_id: 5, password: "x", captcha_token: "t" },
      {
        member_id: "CPC-2026-00001",
        password: "x".repeat(200),
        captcha_token: "t",
      },
      [],
      "text",
    ]
  ) {
    const r = await read(await handle(request(body), deps));
    assert.equal(r.status, 400, JSON.stringify(body).slice(0, 40));
    assert.equal(r.body.code, "bad_request");
  }
  const notJson = await read(
    await handle(request(null, { raw: "{oops" }), deps),
  );
  assert.equal(notJson.status, 400);
  const huge = await handle(
    request(null, {
      raw: JSON.stringify({ ...good, password: "x", pad: "y".repeat(5000) }),
    }),
    deps,
  );
  assert.equal(huge.status, 413);
  assert.equal(state.signIns.length, 0, "invalid input never reaches Auth");
});

Deno.test("login: only the app's own origin may call it; preflight and methods are handled", async () => {
  const { deps } = world();
  const foreign = await handle(
    request(good, { origin: "https://evil.example" }),
    deps,
  );
  assert.equal(foreign.status, 403);
  assert.equal(foreign.headers.get("access-control-allow-origin"), null);
  const pre = await handle(request(null, { method: "OPTIONS" }), deps);
  assert.equal(pre.status, 204);
  assert.equal(pre.headers.get("access-control-allow-origin"), ORIGIN);
  assert.match(pre.headers.get("access-control-allow-headers"), /x-request-id/);
  assert.equal(
    (await handle(request(null, { method: "GET" }), deps)).status,
    405,
  );
  const noOrigin = await handle(request(good, { origin: null }), deps);
  assert.equal(noOrigin.status, 200, "server-to-server calls carry no Origin");
  assert.equal(noOrigin.headers.get("access-control-allow-origin"), null);
});

Deno.test("login: Auth being down is reported as unavailable, not as a bad password", async () => {
  const { deps, state } = world({
    deps: {
      signIn: () => Promise.resolve({ ok: false, reason: "unavailable" }),
    },
  });
  const r = await read(await handle(request(good), deps));
  assert.equal(r.status, 503);
  assert.equal(r.body.code, "unavailable");
  assert.equal(
    state.failures.size,
    0,
    "an outage does not count against the member",
  );
});

Deno.test("login: no response or log line contains the ID, the password or the address", async () => {
  const { deps, state } = world();
  const secrets = ["CPC-2026-00001", "0000112212025", "203.0.113.7"];
  const outputs = [];
  outputs.push(
    JSON.stringify(
      (await read(await handle(request({ ...good, password: "wrong" }), deps)))
        .body,
    ),
  );
  outputs.push(
    JSON.stringify(
      (await read(await handle(request(good), deps))).body.must_change_password,
    ),
  );
  outputs.push(...state.logs);
  for (const key of state.failures.keys()) outputs.push(key);
  for (const text of outputs) {
    for (const s of secrets) {
      assert.equal(String(text).includes(s), false, `${s} leaked`);
    }
  }
});
