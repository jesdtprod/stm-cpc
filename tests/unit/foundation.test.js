import assert from "node:assert/strict";
import {
  ApiError,
  call,
  createApi,
  makeFetch,
  mapError,
} from "../../web/lib/api.js";
import {
  createErrorReporter,
  installGlobalHandlers,
  safePageUrl,
  sanitize,
} from "../../web/lib/errors.js";
import {
  can,
  canAny,
  checkAccess,
  clearAuth,
  setAuth,
} from "../../web/lib/permissions.js";
import { createSession } from "../../web/lib/session.js";
import { isUlid } from "../../web/lib/ulid.js";

// ---------- api (1B.4)
Deno.test("api: database and network errors become readable messages", () => {
  const cases = [
    [{ code: "42501" }, "forbidden", "You don't have permission to do that."],
    [{ code: "23505" }, "duplicate", "That already exists."],
    [
      { code: "23514" },
      "invalid",
      "Some of the information is not valid. Check it and try again.",
    ],
    [
      { code: "CP409" },
      "in_progress",
      "That request is still being processed. Try again in a moment.",
    ],
    [
      { code: "CP422" },
      "conflict",
      "This request does not match an earlier one. Reload the page and try again.",
    ],
    [
      { code: "55000" },
      "state",
      "That record can't be changed in its current state.",
    ],
    [
      { code: "PGRST301" },
      "session_expired",
      "Your session has expired. Sign in again.",
    ],
    [
      { error_code: "captcha_failed" },
      "captcha",
      "The security check failed. Try again.",
    ],
    [
      { status: 503 },
      "server",
      "Something went wrong on our side. Try again in a moment.",
    ],
    [
      new TypeError("Failed to fetch"),
      "network",
      "Can't reach the server. Check your connection and try again.",
    ],
    [{ message: "weird" }, "unknown", "Something went wrong. Try again."],
  ];
  for (const [input, kind, message] of cases) {
    const e = mapError(input, "REQ1");
    assert.ok(e instanceof ApiError);
    assert.equal(e.kind, kind);
    assert.equal(e.message, message);
    assert.equal(e.requestId, "REQ1");
  }
  assert.equal(mapError({ code: "CP409" }).retryable, true);
  assert.equal(mapError({ code: "42501" }).retryable, false);
});

Deno.test("api: a retry reuses the same idempotency key and succeeds once", async () => {
  const seen = [];
  let calls = 0;
  const client = {
    rpc(name, args) {
      seen.push({ name, args });
      calls++;
      return Promise.resolve(
        calls < 3
          ? { data: null, error: { code: "CP409", message: "busy" } }
          : { data: { ok: true }, error: null },
      );
    },
  };
  const api = createApi({ client, sleep: () => Promise.resolve() });
  const key = api.newKey();
  assert.ok(isUlid(key));
  const data = await api.rpc("cancel_booking", { p_id: "b1" }, { key });
  assert.deepEqual(data, { ok: true });
  assert.equal(seen.length, 3);
  assert.ok(
    seen.every((s) => s.args.p_idempotency_key === key),
    "every attempt sends the same key",
  );
});

Deno.test("api: non-retryable errors fail at once; retries are bounded", async () => {
  let n = 0;
  const denied =
    () => (n++, Promise.resolve({ data: null, error: { code: "42501" } }));
  await assert.rejects(
    () => call(denied, { sleep: () => Promise.resolve() }),
    (e) => e.kind === "forbidden",
  );
  assert.equal(n, 1);
  n = 0;
  const down =
    () => (n++, Promise.resolve({ data: null, error: { status: 500 } }));
  await assert.rejects(
    () => call(down, { retries: 2, sleep: () => Promise.resolve() }),
    (e) => e.kind === "server",
  );
  assert.equal(n, 3);
});

Deno.test("api: create() uses the key as the id and ignores duplicates", async () => {
  let captured;
  const client = {
    from: (table) => ({
      upsert: (
        row,
        opts,
      ) => (captured = { table, row, opts },
        Promise.resolve({ data: null, error: null })),
    }),
  };
  const api = createApi({ client });
  await api.create("lookups", "01H0000000000000000000KEY1", { code: "x" });
  assert.deepEqual(captured, {
    table: "lookups",
    row: { code: "x", id: "01H0000000000000000000KEY1" },
    opts: { onConflict: "id", ignoreDuplicates: true },
  });
});

Deno.test("api: every request carries an x-request-id", async () => {
  const sink = {};
  let headers;
  const f = makeFetch(
    (
      _input,
      init,
    ) => (headers = init.headers, Promise.resolve(new Response("{}"))),
    () => "RID-1",
    sink,
  );
  await f("https://example.test/x", { headers: { apikey: "k" } });
  assert.equal(headers.get("x-request-id"), "RID-1");
  assert.equal(headers.get("apikey"), "k");
  assert.equal(sink.lastRequestId, "RID-1");
});

// ---------- errors (1B.5)
Deno.test("errors: personal data and tokens never reach the log", () => {
  assert.equal(sanitize("failed for ana@example.test"), "failed for [email]");
  assert.equal(
    sanitize("Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.abc123def"),
    "Bearer [token]",
  );
  assert.equal(sanitize("call 0917 123 4567 now"), "call [number] now");
  assert.equal(
    safePageUrl("https://h.example/app/#/members?token=abc&x=1"),
    "https://h.example/app/#/members",
  );
  assert.equal(sanitize("word ".repeat(1000)).length, 2000);
});

Deno.test("errors: reports once per distinct error, rate limited, only when signed in", async () => {
  const sent = [];
  let t = 0;
  const ctx = { profile_id: "P1", org_id: "O1", app_version: "1" };
  const reporter = createErrorReporter({
    send: (r) => (sent.push(r), Promise.resolve()),
    getContext: () => ctx,
    now: () => t,
    maxPerWindow: 2,
    windowMs: 1000,
  });
  const err = (m) =>
    Object.assign(new Error(m), {
      stack: `Error: ${m}\n    at f (app.js:1:1)`,
    });
  assert.equal(
    await reporter.report(err("boom"), { href: "https://h.example/#/x" }),
    "sent",
  );
  assert.equal(await reporter.report(err("boom")), "duplicate");
  assert.equal(await reporter.report(err("two")), "sent");
  assert.equal(await reporter.report(err("three")), "limited");
  t = 2000;
  assert.equal(await reporter.report(err("three")), "sent");
  assert.equal(sent.length, 3);
  assert.equal(sent[0].profile_id, "P1");
  assert.ok(sent[0].message.length <= 2000);
  ctx.profile_id = null;
  assert.equal(await reporter.report(err("anon")), "skipped");
});

Deno.test("errors: a failing send never throws, and global handlers notify once per event", async () => {
  const reporter = createErrorReporter({
    send: () => Promise.reject(new Error("db down")),
    getContext: () => ({ profile_id: "P" }),
  });
  assert.equal(await reporter.report(new Error("x")), "failed");
  const target = new EventTarget();
  const notes = [];
  installGlobalHandlers(target, { reporter, notify: (m) => notes.push(m) });
  const ev = new Event("error");
  ev.error = new Error("kaboom");
  target.dispatchEvent(ev);
  assert.equal(notes.length, 1);
  assert.match(notes[0], /Something went wrong/);
});

// ---------- permissions and guards (1B.3)
Deno.test("permissions: can() and route access follow the grants", () => {
  clearAuth();
  assert.equal(can("bookings.create"), false);
  assert.deepEqual(checkAccess("public"), { allow: true });
  assert.deepEqual(checkAccess("signedIn"), { redirect: "#/signin" });

  setAuth({
    signedIn: true,
    grants: [{ org_id: "O", unit_id: null, code: "bookings.create" }, {
      org_id: "O",
      unit_id: "U1",
      code: "courts.manage",
    }],
  });
  assert.equal(can("bookings.create"), true);
  assert.equal(can("members.approve"), false);
  assert.equal(can("courts.manage", { unitId: "U1" }), true);
  assert.equal(can("courts.manage", { unitId: "U2" }), false);
  assert.equal(canAny(["members.approve", "bookings.create"]), true);
  assert.deepEqual(checkAccess("signedIn"), { allow: true });
  assert.deepEqual(checkAccess({ permission: "bookings.create" }), {
    allow: true,
  });
  assert.deepEqual(checkAccess({ permission: "members.approve" }), {
    forbidden: true,
  });
  assert.deepEqual(checkAccess({ any: ["members.approve", "courts.manage"] }), {
    allow: true,
  });
});

Deno.test("permissions: a gated user reaches only gated and public pages", () => {
  const pages = { pending: "#/pending", password_change: "#/password" };
  setAuth({ signedIn: true, grants: [], gate: "pending" });
  assert.equal(can("bookings.create"), false);
  assert.deepEqual(checkAccess("gated", pages), { allow: true });
  assert.deepEqual(checkAccess("signedIn", pages), { redirect: "#/pending" });
  assert.deepEqual(checkAccess({ permission: "bookings.create" }, pages), {
    redirect: "#/pending",
  });
  assert.deepEqual(checkAccess("public", pages), { allow: true });
  setAuth({ signedIn: true, grants: [], gate: "password_change" });
  assert.deepEqual(checkAccess("signedIn", pages), { redirect: "#/password" });
  clearAuth();
});

// ---------- session (1B.2)
function fakeClock() {
  let t = 0;
  const timers = [];
  return {
    now: () => t,
    setTimer: (
      fn,
      ms,
    ) => (timers.push({ at: t + ms, fn, live: true }), timers.at(-1)),
    clearTimer: (h) => h && (h.live = false),
    advance(ms) {
      t += ms;
      for (
        const h of timers.filter((x) => x.live && x.at <= t).sort((a, b) =>
          a.at - b.at
        )
      ) {
        h.live = false;
        h.fn();
      }
    },
  };
}

function makeBus() {
  const ports = [];
  return () => {
    const port = {
      handlers: [],
      postMessage(data) {
        for (const p of ports) {
          if (p !== port) p.handlers.forEach((h) => h({ data }));
        }
      },
      addEventListener(_t, h) {
        port.handlers.push(h);
      },
    };
    ports.push(port);
    return port;
  };
}

function makeEnv(overrides = {}) {
  const clock = fakeClock();
  const log = { signOuts: 0, changes: [], warnings: [] };
  const store = new Map([["cpc.queue", "x"], ["cpc.auth", "t"], [
    "other",
    "keep",
  ]]);
  const caches = new Map([["cpc-shell-v4", 1], ["cpc-data", 1]]);
  const auth = {
    setSession: () => Promise.resolve({ error: null }),
    signOut: () => (log.signOuts++, Promise.resolve({ error: null })),
    getSession: () => Promise.resolve({ data: { session: null } }),
    onAuthStateChange: (fn) => (log.authListener = fn),
  };
  const make = (channel) =>
    createSession({
      auth,
      login: () => Promise.resolve({ access_token: "a", refresh_token: "r" }),
      loadAccess: () =>
        Promise.resolve({
          grants: [{ org_id: "O", unit_id: null, code: "bookings.create" }],
          profile: { profile_id: "P1", org_id: "O" },
        }),
      channel,
      storage: {
        get length() {
          return store.size;
        },
        key: (i) => [...store.keys()][i],
        removeItem: (k) => store.delete(k),
      },
      cacheStorage: {
        keys: () => Promise.resolve([...caches.keys()]),
        delete: (k) => Promise.resolve(caches.delete(k)),
      },
      onChange: (s) => log.changes.push(s.status),
      onIdleWarning: (s) => log.warnings.push(s),
      ...clock,
      ...overrides,
    });
  return { clock, log, store, caches, auth, make };
}

Deno.test("session: sign-in loads grants; idle timeout warns, then signs out and clears local data", async () => {
  const env = makeEnv();
  const s = env.make(null);
  await s.signIn({ id: "CPC-2026-00001", password: "x" }, "token");
  assert.equal(s.getState().status, "signed_in");
  assert.equal(s.getState().gate, null);
  assert.deepEqual(
    s.getState().profile,
    { profile_id: "P1", org_id: "O" },
    "the profile is kept for error reports",
  );
  env.clock.advance(14 * 60_000 - 1);
  assert.equal(s.getState().status, "signed_in");
  env.clock.advance(1);
  assert.deepEqual(env.log.warnings, [60]);
  env.clock.advance(60_000);
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(s.getState().status, "signed_out");
  assert.equal(s.getState().reason, "idle");
  assert.equal(env.log.signOuts, 1);
  assert.deepEqual(
    [...env.caches.keys()],
    ["cpc-shell-v4"],
    "data caches are cleared, the app shell stays",
  );
  assert.deepEqual(
    [...env.store.keys()],
    ["other"],
    "cpc.* keys (including any offline queue) are cleared",
  );
});

Deno.test("session: activity postpones the idle sign-out", async () => {
  const env = makeEnv();
  const s = env.make(null);
  await s.signIn({}, "t");
  env.clock.advance(10 * 60_000);
  s.activity();
  env.clock.advance(10 * 60_000);
  assert.equal(s.getState().status, "signed_in");
  env.clock.advance(5 * 60_000 + 1);
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(s.getState().status, "signed_out");
});

Deno.test("session: signing out in one tab signs out the other", async () => {
  const bus = makeBus();
  const a = makeEnv();
  const b = makeEnv();
  const tabA = a.make(bus());
  const tabB = b.make(bus());
  await tabA.start();
  await tabB.start();
  await tabA.signIn({}, "t");
  await tabB.signIn({}, "t");
  await tabA.signOut();
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(tabA.getState().status, "signed_out");
  assert.equal(tabB.getState().status, "signed_out", "the second tab follows");
  assert.equal(b.store.has("cpc.queue"), false);
});

Deno.test("session: a sign-out from the auth layer (token revoked) is honoured", async () => {
  const env = makeEnv();
  const s = env.make(null);
  await s.start();
  await s.signIn({}, "t");
  env.log.authListener("SIGNED_OUT");
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(s.getState().status, "signed_out");
  assert.equal(s.getState().reason, "remote");
});

Deno.test("session: members with no grants are gated as pending", async () => {
  const env = makeEnv();
  const s = createSession({
    auth: env.auth,
    login: () => Promise.resolve({}),
    loadAccess: () => Promise.resolve({ grants: [], profile: null }),
    ...env.clock,
  });
  await s.signIn({}, "t");
  assert.equal(s.getState().gate, "pending");
});

Deno.test("session: sensitive actions ask for the password again after five minutes", async () => {
  const env = makeEnv();
  const s = env.make(null);
  await s.signIn({}, "t");
  let prompts = 0;
  const prompt = () => (prompts++, Promise.resolve({ password: "x" }));
  assert.equal(await s.ensureFreshAuth(prompt, "t"), true);
  assert.equal(prompts, 0, "recent sign-in needs no prompt");
  env.clock.advance(5 * 60_000 + 1);
  s.activity();
  assert.equal(await s.ensureFreshAuth(prompt, "t"), true);
  assert.equal(prompts, 1);
  env.clock.advance(5 * 60_000 + 1);
  assert.equal(
    await s.ensureFreshAuth(() => Promise.resolve(null), "t"),
    false,
    "cancelled prompt refuses the action",
  );
});

Deno.test("session: a restored session is not fresh, so sensitive actions prompt", async () => {
  const env = makeEnv();
  env.auth.getSession = () =>
    Promise.resolve({ data: { session: { access_token: "a" } } });
  const s = env.make(null);
  await s.start();
  assert.equal(s.getState().status, "signed_in");
  let prompts = 0;
  await s.ensureFreshAuth(() => (prompts++, Promise.resolve({})), "t");
  assert.equal(prompts, 1);
});
