import assert from "node:assert/strict";
import { handle } from "../../supabase/functions/staff-create/handler.ts";

const ORIGIN = "https://jesdtprod.github.io";
const GOOD = "Court-Scanner-Fake-Pass-77";

function world(over = {}) {
  const s = { users: [], deleted: [], records: [], logs: [], prepared: [] };
  const deps = {
    allowedOrigins: [ORIGIN],
    token: (req) =>
      req.headers.get("authorization")?.replace(/^Bearer\s+/i, "") || null,
    prepare: (_t, role, name) => {
      s.prepared.push({ role, name });
      return Promise.resolve(
        over.prepare ?? {
          ok: true,
          memberNo: "CPC-2026-90001",
          actor: "PROFILE1",
        },
      );
    },
    createAuthUser: (email, password) => {
      if (over.authFails) {
        return Promise.resolve({ ok: false, reason: "failed" });
      }
      s.users.push({ email, password });
      return Promise.resolve({ ok: true, id: "uid-1" });
    },
    deleteAuthUser: (id) => {
      s.deleted.push(id);
      return Promise.resolve();
    },
    createRecords: (...args) => {
      if (over.recordsFail) return Promise.reject(new Error("db"));
      s.records.push(args);
      return Promise.resolve();
    },
    log: (e) => s.logs.push(e),
  };
  return { deps, s };
}

const call = (body, { token = "jwt", origin = ORIGIN, method = "POST" } = {}) =>
  new Request("https://f.example/staff-create", {
    method,
    headers: {
      origin,
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: method === "POST" ? JSON.stringify(body) : undefined,
  });

const good = {
  display_name: "Court Scanner",
  role_code: "scanner",
  password: GOOD,
};

Deno.test("staff-create: makes the login and records, and never returns the password", async () => {
  const { deps, s } = world();
  const res = await handle(call(good), deps);
  assert.equal(res.status, 200);
  const text = await res.text();
  assert.deepEqual(JSON.parse(text), { ok: true, member_no: "CPC-2026-90001" });
  assert.equal(text.includes(GOOD), false);
  assert.equal(s.users[0].email, "cpc-2026-90001@members.cpc.app");
  assert.deepEqual(s.records[0], [
    "CPC-2026-90001",
    "Court Scanner",
    "scanner",
    "uid-1",
    "PROFILE1",
  ]);
  assert.equal(JSON.stringify(s.logs).includes(GOOD), false);
});

Deno.test("staff-create: no token, a wrong origin, an admin role or a bad body is refused first", async () => {
  const { deps, s } = world();
  assert.equal((await handle(call(good, { token: null }), deps)).status, 401);
  assert.equal(
    (await handle(call(good, { origin: "https://evil.example" }), deps)).status,
    403,
  );
  assert.equal(
    (await handle(call({ ...good, role_code: "admin" }), deps)).status,
    400,
  );
  assert.equal(
    (await handle(call({ ...good, display_name: "x" }), deps)).status,
    400,
  );
  assert.equal((await handle(call(good, { method: "GET" }), deps)).status, 405);
  assert.deepEqual(s.prepared, []);
  assert.deepEqual(s.users, []);
});

Deno.test("staff-create: the database's refusal is passed on and nothing is created", async () => {
  const { deps, s } = world({
    prepare: {
      ok: false,
      status: 403,
      message: "you do not have permission to add staff",
    },
  });
  const res = await handle(call(good), deps);
  assert.equal(res.status, 403);
  assert.equal((await res.json()).code, "forbidden");
  assert.deepEqual(s.users, []);
});

Deno.test("staff-create: a weak password is refused before the login is made", async () => {
  const { deps, s } = world();
  const res = await handle(call({ ...good, password: "short" }), deps);
  assert.equal(res.status, 422);
  assert.equal((await res.json()).code, "weak_password");
  assert.deepEqual(s.users, []);
});

Deno.test("staff-create: if the records fail, the login is removed again", async () => {
  const { deps, s } = world({ recordsFail: true });
  const res = await handle(call(good), deps);
  assert.equal(res.status, 503);
  assert.deepEqual(s.deleted, ["uid-1"]);
});
