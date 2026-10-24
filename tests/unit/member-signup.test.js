import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  signupMobile,
  validateSignup,
} from "../../supabase/functions/_shared/signup-rules.ts";
import {
  handle,
  LIMIT,
} from "../../supabase/functions/member-signup/handler.ts";

const TODAY = new Date("2026-11-01T00:00:00Z");
const ORIGIN = "https://jesdtprod.github.io";
const GOOD = {
  first_name: "  Ana  ",
  middle_name: "Marie",
  last_name: "Dela Cruz",
  suffix: "Jr.",
  gender: "Female",
  date_of_birth: "1995-04-05",
  mobile: "0917 123 4567",
  email: " Ana@Example.TEST ",
  password: "blue-tiger-jumps-over-5-fences",
  consent_waiver: true,
  consent_privacy: true,
  captcha_token: "tok",
};

// ---------- rules
Deno.test("signup rules: a good form is cleaned", () => {
  const r = validateSignup(GOOD, TODAY);
  assert.equal(r.ok, true);
  assert.deepEqual(r.data, {
    first_name: "Ana",
    middle_name: "Marie",
    last_name: "Dela Cruz",
    suffix: "Jr.",
    display_name: "Ana Dela Cruz",
    gender: "female",
    date_of_birth: "1995-04-05",
    mobile: "09171234567",
    email: "ana@example.test",
    password: "blue-tiger-jumps-over-5-fences",
    captcha_token: "tok",
  });
});

Deno.test("signup rules: optional fields may be empty, the email may not", () => {
  const r = validateSignup({
    ...GOOD,
    middle_name: "",
    suffix: "",
    gender: "",
  }, TODAY);
  assert.equal(r.ok, true);
  assert.deepEqual([
    r.data.middle_name,
    r.data.suffix,
    r.data.gender,
  ], [null, null, null]);
  const noEmail = validateSignup({ ...GOOD, email: "" }, TODAY);
  assert.equal(noEmail.ok, false);
  assert.equal(noEmail.errors.email, "required");
});

Deno.test("signup rules: each required field and bad value is reported by name", () => {
  const r = validateSignup({
    consent_waiver: false,
    consent_privacy: "yes",
    first_name: "X1",
    last_name: "",
    date_of_birth: "1800-01-01",
    mobile: "12",
    email: "nope",
    suffix: "Esq",
    gender: "x",
    password: "",
  }, TODAY);
  assert.equal(r.ok, false);
  assert.deepEqual(r.errors, {
    first_name: "invalid",
    last_name: "required",
    suffix: "invalid",
    gender: "invalid",
    date_of_birth: "invalid",
    mobile: "invalid",
    email: "invalid",
    password: "required",
    consent_waiver: "not_accepted",
    consent_privacy: "not_accepted",
    captcha_token: "required",
  });
});

Deno.test("signup rules: names allow accents, hyphens, apostrophes and periods, and refuse digits and markup", () => {
  for (const ok of ["Niño", "Mary-Ann", "O'Brien", "Ma. Cristina", "José"]) {
    assert.equal(
      validateSignup({ ...GOOD, first_name: ok }, TODAY).ok,
      true,
      ok,
    );
  }
  for (
    const bad of ["<b>x</b>", "Ana2", "x".repeat(61), "; drop table", "-Ana"]
  ) {
    assert.equal(
      validateSignup({ ...GOOD, first_name: bad }, TODAY).ok,
      false,
      bad,
    );
  }
});

Deno.test("signup rules: birth date must be real, past, and from 1920", () => {
  for (
    const bad of [
      "2027-01-01",
      "1919-12-31",
      "2000-02-30",
      "05/04/1995",
      "not a date",
    ]
  ) {
    assert.equal(
      validateSignup({ ...GOOD, date_of_birth: bad }, TODAY).ok,
      false,
      bad,
    );
  }
  assert.equal(
    validateSignup({ ...GOOD, date_of_birth: "2020-06-01" }, TODAY).ok,
    true,
    "a child may be registered (flagged for review)",
  );
});

Deno.test("signup rules: mobile numbers", () => {
  assert.equal(signupMobile("09171234567"), "09171234567");
  assert.equal(signupMobile("+63 917 123 4567"), "09171234567");
  assert.equal(signupMobile("9171234567"), "09171234567");
  assert.equal(signupMobile("1234"), null);
  assert.equal(signupMobile("08171234567"), null);
});

Deno.test("signup rules: any attempt to name a member ID is refused outright", () => {
  for (const key of ["member_id", "member_no", "id_no", "id"]) {
    assert.deepEqual(
      validateSignup({ ...GOOD, [key]: "CPC-2026-00001" }, TODAY),
      { ok: false, code: "existing_member_claim" },
      key,
    );
  }
});

// ---------- handler
const NOW = TODAY.getTime();

function world(over = {}) {
  const s = {
    failures: new Map(),
    users: [],
    deleted: [],
    members: [],
    logs: [],
    captchas: [],
    numbers: 0,
  };
  const deps = {
    allowedOrigins: [ORIGIN],
    now: () => NOW,
    sha256: (t) =>
      Promise.resolve(createHash("sha256").update(t).digest("hex")),
    isLocked: (keys) =>
      Promise.resolve(keys.some((k) => (s.failures.get(k) ?? 0) >= LIMIT.max)),
    recordFailure: (k) => {
      s.failures.set(k, (s.failures.get(k) ?? 0) + 1);
      return Promise.resolve(false);
    },
    signupEnabled: () => Promise.resolve(over.enabled ?? true),
    checkCaptcha: (t) => {
      s.captchas.push(t);
      return Promise.resolve(over.captcha ?? (t === "bad" ? "failed" : "ok"));
    },
    allocateMemberNo: () => {
      s.numbers++;
      return Promise.resolve(
        over.number ?? `CPC-2026-${String(1500 + s.numbers).padStart(5, "0")}`,
      );
    },
    createAuthUser: (email, password) => {
      if (over.authFails) return Promise.resolve({ ok: false });
      s.users.push({ email, password });
      return Promise.resolve({ ok: true, id: `uid-${s.users.length}` });
    },
    deleteAuthUser: (id) => {
      s.deleted.push(id);
      return Promise.resolve();
    },
    createMember: (no, data, uid) => {
      if (over.dbFails) return Promise.reject(new Error("db"));
      s.members.push({ no, data, uid });
      return Promise.resolve();
    },
    log: (e) => s.logs.push(e),
  };
  return { deps, s };
}
const call = (
  body,
  { method = "POST", origin = ORIGIN, ip = "203.0.113.5", raw } = {},
) =>
  new Request("https://example.test/member-signup", {
    method,
    headers: {
      "content-type": "application/json",
      "x-forwarded-for": ip,
      ...(origin ? { origin } : {}),
    },
    body: method === "POST" ? (raw ?? JSON.stringify(body)) : undefined,
  });
const run = async (deps, body, opts) => {
  const res = await handle(call(body, opts), deps);
  return {
    status: res.status,
    body: res.status === 204 ||
        res.status === 403 && !res.headers.get("content-type")
      ? null
      : await res.json().catch(() => null),
    headers: res.headers,
  };
};

Deno.test("signup: a good application creates the account and the member, and returns the new ID", async () => {
  const { deps, s } = world();
  const r = await run(deps, GOOD);
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { ok: true, member_no: "CPC-2026-01501" });
  assert.deepEqual(s.users, [{
    email: "cpc-2026-01501@members.cpc.app",
    password: GOOD.password,
  }]);
  assert.equal(s.members[0].no, "CPC-2026-01501");
  assert.equal(s.members[0].uid, "uid-1");
  assert.equal(s.members[0].data.display_name, "Ana Dela Cruz");
  assert.equal(r.headers.get("cache-control"), "no-store");
  assert.equal(r.headers.get("access-control-allow-origin"), ORIGIN);
  assert.equal(JSON.stringify(r.body).includes(GOOD.password), false);
});

Deno.test("signup: a claim of an existing member ID is rejected and nothing is created", async () => {
  const { deps, s } = world();
  const r = await run(deps, { ...GOOD, member_id: "CPC-2026-00001" });
  assert.equal(r.status, 400);
  assert.equal(r.body.code, "existing_member_claim");
  assert.equal(s.users.length + s.members.length + s.numbers, 0);
});

Deno.test("signup: the honeypot looks like success but creates nothing", async () => {
  const { deps, s } = world();
  const r = await run(deps, { ...GOOD, website: "http://spam.example" });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { ok: true, queued: true });
  assert.equal(
    s.users.length + s.members.length + s.numbers + s.captchas.length,
    0,
  );
  assert.deepEqual(s.logs, ["signup.honeypot"]);
});

Deno.test("signup: invalid input is listed field by field and never reaches the account step", async () => {
  const { deps, s } = world();
  const r = await run(deps, { ...GOOD, mobile: "12", last_name: "" });
  assert.equal(r.status, 400);
  assert.equal(r.body.code, "invalid");
  assert.deepEqual(r.body.errors, { last_name: "required", mobile: "invalid" });
  assert.equal(s.users.length + s.captchas.length, 0);
});

Deno.test("signup: a weak password is refused with reasons, before the CAPTCHA token is spent", async () => {
  const { deps, s } = world();
  const r = await run(deps, { ...GOOD, password: "password1234" });
  assert.equal(r.status, 400);
  assert.equal(r.body.code, "weak_password");
  assert.ok(r.body.problems.includes("too_common"));
  assert.equal(s.captchas.length, 0);
  const dob = await run(deps, { ...GOOD, password: "tiger04051995tiger" });
  assert.ok(dob.body.problems.includes("contains_birth_date"));
  assert.equal(s.users.length, 0);
});

Deno.test("signup: a bad CAPTCHA is refused and nothing is created", async () => {
  const { deps, s } = world();
  const r = await run(deps, { ...GOOD, captcha_token: "bad" });
  assert.equal(r.status, 400);
  assert.equal(r.body.code, "captcha_failed");
  assert.equal(s.users.length + s.members.length + s.numbers, 0);
  const down = world({ captcha: "unavailable" });
  assert.equal((await run(down.deps, GOOD)).status, 503);
});

Deno.test("signup: attempts per address are limited, and another address is unaffected", async () => {
  const { deps } = world();
  for (let i = 0; i < LIMIT.max; i++) {
    assert.equal((await run(deps, GOOD, { ip: "198.51.100.9" })).status, 200);
  }
  const blocked = await run(deps, GOOD, { ip: "198.51.100.9" });
  assert.equal(blocked.status, 429);
  assert.equal(blocked.body.code, "too_many_attempts");
  assert.equal((await run(deps, GOOD, { ip: "198.51.100.10" })).status, 200);
});

Deno.test("signup: when sign-up is switched off, nothing is created", async () => {
  const { deps, s } = world({ enabled: false });
  const r = await run(deps, GOOD);
  assert.equal(r.status, 403);
  assert.equal(r.body.code, "closed");
  assert.equal(s.users.length, 0);
});

Deno.test("signup: if the database step fails the Auth user is removed and the applicant can retry", async () => {
  const { deps, s } = world({ dbFails: true });
  const r = await run(deps, GOOD);
  assert.equal(r.status, 503);
  assert.deepEqual(s.deleted, ["uid-1"]);
  assert.equal(s.members.length, 0);
  const authDown = world({ authFails: true });
  assert.equal((await run(authDown.deps, GOOD)).status, 503);
  assert.equal(authDown.s.deleted.length, 0);
});

Deno.test("signup: origin, method, body size and shape", async () => {
  const { deps } = world();
  assert.equal(
    (await handle(call(GOOD, { origin: "https://evil.example" }), deps)).status,
    403,
  );
  assert.equal(
    (await handle(call(GOOD, { origin: null }), deps)).status,
    403,
    "a missing Origin is refused too",
  );
  assert.equal((await run(deps, null, { method: "OPTIONS" })).status, 204);
  assert.equal((await run(deps, null, { method: "GET" })).status, 405);
  assert.equal((await run(deps, null, { raw: "{oops" })).status, 400);
  assert.equal(
    (await run(deps, null, {
      raw: JSON.stringify({ ...GOOD, pad: "x".repeat(9000) }),
    })).status,
    413,
  );
  assert.equal((await run(deps, [], {})).status, 400);
});

Deno.test("signup: logs and responses carry no names, numbers, dates or passwords", async () => {
  const { deps, s } = world();
  const r = await run(deps, GOOD);
  const everything = JSON.stringify([r.body, s.logs, [...s.failures.keys()]]);
  for (
    const secret of [
      "Ana",
      "Dela Cruz",
      "09171234567",
      "1995-04-05",
      GOOD.password,
      "203.0.113.5",
    ]
  ) {
    assert.equal(everything.includes(secret), false, secret);
  }
});
