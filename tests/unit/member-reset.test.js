import assert from "node:assert/strict";
import { handle } from "../../supabase/functions/member-reset/handler.ts";

const ORIGIN = "https://jesdtprod.github.io";
const MEMBER = "01M5KVH64YWRD8G5STB90V74T7";

function world(over = {}) {
  const s = { passwords: [], finished: [], logs: [] };
  const deps = {
    allowedOrigins: [ORIGIN],
    token: (req) =>
      req.headers.get("authorization")?.replace(/^Bearer\s+/i, "") || null,
    prepare: () =>
      Promise.resolve(
        over.prepare ?? {
          ok: true,
          authUserId: "auth-1",
          memberNo: "CPC-2026-00123",
          dob: "1990-07-04",
        },
      ),
    finish: (_token, id) => {
      s.finished.push(id);
      return Promise.resolve(over.finish ?? { ok: true });
    },
    setPassword: (uid, pw) => {
      if (over.setFails) return Promise.resolve(false);
      s.passwords.push({ uid, pw });
      return Promise.resolve(true);
    },
    log: (e) => s.logs.push(e),
  };
  return { deps, s };
}

const call = (body, { token = "jwt", origin = ORIGIN, method = "POST" } = {}) =>
  new Request("https://f.example/member-reset", {
    method,
    headers: {
      origin,
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: method === "POST" ? JSON.stringify(body) : undefined,
  });

Deno.test("reset: the password becomes the last 5 digits of the ID plus MMDDYYYY, and is never returned", async () => {
  const { deps, s } = world();
  const res = await handle(call({ member_id: MEMBER }), deps);
  assert.equal(res.status, 200);
  const text = await res.text();
  assert.deepEqual(JSON.parse(text), { ok: true });
  assert.deepEqual(s.passwords, [{ uid: "auth-1", pw: "0012307041990" }]);
  assert.equal(text.includes("0012307041990"), false);
  assert.deepEqual(s.finished, [MEMBER]);
  assert.deepEqual(s.logs, ["member.reset"]);
});

Deno.test("reset: no token, a wrong origin or a bad body is refused before anything happens", async () => {
  const { deps, s } = world();
  assert.equal(
    (await handle(call({ member_id: MEMBER }, { token: null }), deps)).status,
    401,
  );
  assert.equal(
    (await handle(
      call({ member_id: MEMBER }, { origin: "https://evil.example" }),
      deps,
    ))
      .status,
    403,
  );
  assert.equal((await handle(call({ member_id: "nope" }), deps)).status, 400);
  assert.equal((await handle(call({}), deps)).status, 400);
  assert.equal(
    (await handle(call(null, { method: "GET" }), deps)).status,
    405,
  );
  assert.equal(s.passwords.length + s.finished.length, 0);
});

Deno.test("reset: when the database refuses, nothing is changed and its sentence is shown", async () => {
  for (
    const [status, code] of [[403, "forbidden"], [422, "not_allowed"], [
      401,
      "unauthorized",
    ]]
  ) {
    const { deps, s } = world({
      prepare: {
        ok: false,
        status,
        message: "An administrator account cannot be reset here",
      },
    });
    const res = await handle(call({ member_id: MEMBER }), deps);
    assert.equal(res.status, status);
    const body = await res.json();
    assert.equal(body.code, code);
    assert.match(body.message, /administrator/);
    assert.equal(s.passwords.length + s.finished.length, 0);
  }
});

Deno.test("reset: the forced-change flag is set before the password, so a failed password step leaves no weak password unflagged", async () => {
  const { deps, s } = world({ setFails: true });
  const res = await handle(call({ member_id: MEMBER }), deps);
  assert.equal(res.status, 503);
  assert.deepEqual(s.finished, [MEMBER]);
  assert.equal(s.passwords.length, 0);
  assert.deepEqual(s.logs, ["member.reset_failed"]);
});

Deno.test("reset: if the flag step is refused the password is not touched", async () => {
  const { deps, s } = world({
    finish: { ok: false, status: 403, message: "you do not have permission" },
  });
  const res = await handle(call({ member_id: MEMBER }), deps);
  assert.equal(res.status, 403);
  assert.equal(s.passwords.length, 0);
});
