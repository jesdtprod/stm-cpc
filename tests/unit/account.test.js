import assert from "node:assert/strict";
import {
  AuthFlowError,
  changePassword,
  memberLogin,
} from "../../web/lib/auth-api.js";
import {
  localPasswordProblems,
  problemMessages,
} from "../../web/lib/password-hints.js";
import { createSession } from "../../web/lib/session.js";
import { nextHash } from "../../web/pages-account.js";

// ---------- auth api
const fakeFetch = (status, body, calls = []) => (url, init) => {
  calls.push({ url, init });
  return Promise.resolve({
    ok: status < 400,
    status,
    json: () => Promise.resolve(body),
  });
};

Deno.test("auth api: a sign-in sends the ID, password and CAPTCHA token to member-login and returns the session", async () => {
  const calls = [];
  const out = await memberLogin(
    { memberId: "CPC-2026-00001", password: "pw" },
    "tok",
    fakeFetch(200, {
      ok: true,
      session: { access_token: "A", refresh_token: "R" },
      must_change_password: true,
    }, calls),
  );
  assert.deepEqual(out, {
    access_token: "A",
    refresh_token: "R",
    must_change_password: true,
  });
  assert.match(calls[0].url, /\/functions\/v1\/member-login$/);
  assert.deepEqual(JSON.parse(calls[0].init.body), {
    member_id: "CPC-2026-00001",
    password: "pw",
    captcha_token: "tok",
  });
});

Deno.test("auth api: failures become AuthFlowError with a safe message", async () => {
  for (
    const [status, body, code] of [
      [401, {
        ok: false,
        code: "invalid_credentials",
        message: "Sign-in failed.",
      }, "invalid_credentials"],
      [400, { ok: false, code: "captcha_failed" }, "captcha_failed"],
      [403, { ok: false, code: "account_disabled" }, "account_disabled"],
      [503, { ok: false, code: "unavailable" }, "unavailable"],
      [500, {}, "unavailable"],
    ]
  ) {
    await assert.rejects(
      () =>
        memberLogin(
          { memberId: "x", password: "y" },
          "t",
          fakeFetch(status, body),
        ),
      (e) =>
        e instanceof AuthFlowError && e.code === code && e.message.length > 5,
      code,
    );
  }
  await assert.rejects(
    () =>
      memberLogin(
        { memberId: "x", password: "y" },
        "t",
        () => Promise.reject(new Error("offline")),
      ),
    (e) => e.code === "network",
  );
});

Deno.test("auth api: a password change sends the token, and weak passwords come back with reasons", async () => {
  const calls = [];
  await changePassword(
    "a-long-new-password",
    "ACCESS",
    fakeFetch(200, { ok: true }, calls),
  );
  assert.equal(calls[0].init.headers.authorization, "Bearer ACCESS");
  assert.deepEqual(JSON.parse(calls[0].init.body), {
    new_password: "a-long-new-password",
  });
  await assert.rejects(
    () =>
      changePassword(
        "short",
        "ACCESS",
        fakeFetch(400, {
          ok: false,
          code: "weak_password",
          problems: ["too_short"],
        }),
      ),
    (e) => e.code === "weak_password" && e.problems[0] === "too_short",
  );
});

// ---------- password hints
Deno.test("password hints: local checks and message mapping", () => {
  assert.deepEqual(
    localPasswordProblems("a-long-enough-one", "a-long-enough-one"),
    [],
  );
  assert.equal(localPasswordProblems("short", "short").length, 1);
  assert.ok(
    localPasswordProblems("a-long-enough-one", "different-one-here").some((m) =>
      /match/.test(m)
    ),
  );
  assert.deepEqual(
    problemMessages(["first_password", "unknown_code"]).length,
    2,
  );
  assert.match(problemMessages(["contains_birth_date"])[0], /birth date/);
});

// ---------- gates and where to go next
Deno.test("account: where each kind of user is sent after signing in", () => {
  const signedIn = (gate, access) => ({ status: "signed_in", gate, access });
  assert.equal(nextHash({ status: "signed_out" }), "#/signin");
  assert.equal(
    nextHash(signedIn("password_change", { must_change_password: true })),
    "#/password",
  );
  assert.equal(
    nextHash(
      signedIn("pending", { status: "invited", profile_complete: false }),
    ),
    "#/profile",
  );
  assert.equal(
    nextHash(
      signedIn("pending", { status: "invited", profile_complete: true }),
    ),
    "#/pending",
  );
  assert.equal(
    nextHash(
      signedIn("pending", {
        status: "pending_approval",
        profile_complete: false,
      }),
    ),
    "#/pending",
  );
  assert.equal(nextHash(signedIn(null, { status: "active" })), "#/");
});

function makeSession(access, grants = []) {
  const state = { access, grants };
  const auth = {
    setSession: () => Promise.resolve({ error: null }),
    signOut: () => Promise.resolve(),
    onAuthStateChange: () => {},
    getSession: () => Promise.resolve({ data: { session: null } }),
  };
  const session = createSession({
    auth,
    login: () => Promise.resolve({ access_token: "a", refresh_token: "r" }),
    loadAccess: () =>
      Promise.resolve({
        grants: state.grants,
        profile: { profile_id: "P" },
        access: state.access,
      }),
    setTimer: () => 0,
    clearTimer: () => {},
  });
  return { session, state };
}

Deno.test("session: a forced password change holds the user at password_change before anything else", async () => {
  const { session } = makeSession({
    must_change_password: true,
    status: "invited",
  });
  await session.signIn({ memberId: "x", password: "y" }, "tok");
  assert.equal(session.getState().gate, "password_change");
  assert.equal(session.getState().access.status, "invited");
});

Deno.test("session: after the password is changed the member is held as pending until approved; refresh() updates the gate", async () => {
  const { session, state } = makeSession({
    must_change_password: true,
    status: "invited",
  });
  await session.signIn({ memberId: "x", password: "y" }, "tok");
  state.access = { must_change_password: false, status: "invited" };
  await session.refresh();
  assert.equal(session.getState().gate, "pending");
  state.access = { must_change_password: false, status: "active" };
  state.grants = [{ code: "bookings.create", org_id: "o", unit_id: null }];
  await session.refresh();
  assert.equal(session.getState().gate, null);
});

Deno.test("session: refresh() does nothing when signed out", async () => {
  const { session } = makeSession(null);
  assert.equal((await session.refresh()).status, "signed_out");
});
