import assert from "node:assert/strict";
import {
  analyzeFile,
  cleanDetails,
  initialPassword,
  normalizeEmail,
  normalizeGender,
  normalizeMemberNo,
  normalizeMobile,
  normalizeSuffix,
  parseBirthDate,
  validateEnrichRow,
  validateImportRow,
} from "../../supabase/functions/_shared/member-import-rules.ts";
import {
  handle,
  internalEmail,
  MAX_ROWS_PER_CALL,
} from "../../supabase/functions/member-import/handler.ts";

const TODAY = new Date("2026-11-01T00:00:00Z");
const BATCH = "01H0000000000000000000BAT1";

// ---------- rules
Deno.test("import rules: member IDs are trimmed, uppercased, and a six-digit ID with one leading zero is shortened", () => {
  assert.deepEqual(normalizeMemberNo(" cpc-2026-00001 "), {
    member_no: "CPC-2026-00001",
    shortened: false,
  });
  assert.deepEqual(normalizeMemberNo("CPC-2026-000123"), {
    member_no: "CPC-2026-00123",
    shortened: true,
  });
  for (
    const bad of [
      null,
      "",
      "  ",
      "CPC-2026-1",
      "CPC-2026-123456",
      "CPC-26-00001",
      "XYZ-2026-00001",
      "CPC-2026-00001-X",
    ]
  ) {
    assert.equal(normalizeMemberNo(bad), null, String(bad));
  }
});

Deno.test("import rules: the first password is the last 5 digits of the ID then MMDDYYYY", () => {
  assert.equal(
    initialPassword("CPC-2026-00001", "2025-12-21"),
    "0000112212025",
  );
  assert.equal(
    initialPassword("CPC-2026-12345", "1980-01-05"),
    "1234501051980",
  );
  assert.equal(initialPassword("CPC-2026-00001", "2025-12-21").length, 13);
});

Deno.test("import rules: birth dates - real dates, text read as month/day/year, bounds", () => {
  assert.equal(
    parseBirthDate("2001-02-03T00:00:00", null, TODAY),
    "2001-02-03",
  );
  assert.equal(parseBirthDate(null, "12/21/2025", TODAY), "2025-12-21");
  assert.equal(parseBirthDate(null, "1/2/1999", TODAY), "1999-01-02");
  assert.equal(
    parseBirthDate(null, "21/12/2000", TODAY),
    null,
    "day/month order is not guessed",
  );
  assert.equal(
    parseBirthDate(null, "02/30/2000", TODAY),
    null,
    "impossible date",
  );
  assert.equal(parseBirthDate("1919-12-31", null, TODAY), null, "before 1920");
  assert.equal(
    parseBirthDate("2027-01-01", null, TODAY),
    null,
    "in the future",
  );
  assert.equal(parseBirthDate(null, "not a date", TODAY), null);
  assert.equal(parseBirthDate(null, null, TODAY), null);
});

Deno.test("import rules: mobile numbers and emails", () => {
  for (
    const [raw, want] of [
      ["09171234567", "09171234567"],
      ["0917 123 4567", "09171234567"],
      ["(0917) 123 4567", "09171234567"],
      ["0917-123-4567", "09171234567"],
      ["9171234567", "09171234567"],
      ["+63 917 123 4567", "09171234567"],
      ["12345", "12345"],
      ["", null],
      [null, null],
    ]
  ) assert.equal(normalizeMobile(raw), want, String(raw));
  assert.equal(normalizeEmail(" Ana@Example.TEST "), "ana@example.test");
  assert.equal(normalizeEmail("not-an-email"), null);
  assert.equal(normalizeEmail("a b@c.d"), null);
});

const raw = (row, over = {}) => ({
  row,
  id_no: `CPC-2026-${String(row).padStart(5, "0")}`,
  display_name: `Fake Person ${row}`,
  dob: "1990-01-02",
  dob_text: null,
  mobile: "09171234567",
  email: `p${row}@example.test`,
  rfid: `RF${row}`,
  ...over,
});

Deno.test("import rules: the whole-file pass skips, holds back, reassigns and cleans as decided", () => {
  const rows = [
    raw(2), // clean
    raw(3, { id_no: null }), // no ID: skipped
    raw(4, { id_no: "  " }), // blank ID: skipped
    raw(5, { id_no: "CPC-2026-00010" }), // shared ID: the first row keeps it ...
    raw(6, { id_no: "cpc-2026-00010 " }), // ... same ID, other spelling: gets a new number
    raw(7, { id_no: "garbage" }), // invalid ID: held back
    raw(8, { id_no: "CPC-2026-000200" }), // shortened to 00200, and it is the first claimant
    raw(9, { dob: null, dob_text: "13/45/2000" }), // unreadable birth date: member without account
    raw(11, { email: "nope" }), // bad email: imported without it
    raw(12, { rfid: "SAME" }),
    raw(13, { rfid: "SAME" }), // shared RFID: cleared on both
    raw(14, { display_name: "  " }), // no name: held back
    raw(15, { id_no: "CPC-2026-00200" }), // same as row 8 once shortened: gets a new number
    raw(16, { rfid: "SAME", id_no: null }), // a third holder of the code on a skipped row still counts
    raw(17, { dob: null, dob_text: "12/21/2025" }), // text date read month/day/year
    raw(18, { id_no: "CPC-2026-00010" }), // a third claimant of 00010
  ];
  const a = analyzeFile(rows, TODAY);
  assert.deepEqual(a.rows.map((r) => r.source_row), [
    2,
    5,
    6,
    8,
    9,
    11,
    12,
    13,
    15,
    17,
    18,
  ]);
  assert.deepEqual(
    a.rows.filter((r) => r.needs_new_id).map((r) => r.source_row),
    [6, 15, 18],
  );
  assert.deepEqual(a.counts, {
    total: 16,
    skipped_no_id: 3,
    held_back: 2,
    reassigned: 3,
    importable: 11,
    with_account: 10,
    without_account: 1,
  });
  const codes = (row) =>
    a.issues.filter((i) => i.source_row === row).map((i) => i.issue_code)
      .sort();
  assert.deepEqual(codes(5), [], "the first claimant has no issue");
  assert.deepEqual(
    codes(6),
    [],
    "the new number is recorded by the server, not here",
  );
  assert.deepEqual(codes(7), ["invalid_member_no"]);
  assert.deepEqual(codes(8), ["member_no_normalized"]);
  assert.deepEqual(codes(9), ["invalid_birth_date"]);
  assert.deepEqual(codes(11), ["invalid_email"]);
  assert.deepEqual(codes(12), ["duplicate_rfid_cleared"]);
  assert.deepEqual(codes(14), ["missing_name"]);
  assert.equal(
    a.rows.find((r) => r.source_row === 6).member_no,
    "CPC-2026-00010",
    "it carries the claimed ID until the server assigns a number",
  );
  assert.equal(a.rows.find((r) => r.source_row === 12).rfid, null);
  assert.equal(a.rows.find((r) => r.source_row === 13).rfid, null);
  assert.equal(a.rows.find((r) => r.source_row === 2).rfid, "RF2");
  assert.equal(a.rows.find((r) => r.source_row === 11).email, null);
  assert.equal(a.rows.find((r) => r.source_row === 17).dob, "2025-12-21");
  assert.equal(a.rows.find((r) => r.source_row === 9).dob, null);
});

Deno.test("import rules: a nameless row does not take an ID away from a named row", () => {
  const a = analyzeFile([
    raw(2, { display_name: null }),
    raw(3, { id_no: "CPC-2026-00002" }),
  ], TODAY);
  assert.deepEqual(a.rows.map((r) => [r.source_row, r.needs_new_id]), [[
    3,
    false,
  ]]);
});

Deno.test("import rules: a shortened ID that is free is imported and reported", () => {
  const a = analyzeFile([raw(2, { id_no: "CPC-2026-000123" })], TODAY);
  assert.equal(a.rows[0].member_no, "CPC-2026-00123");
  assert.deepEqual(a.issues.map((i) => i.issue_code), ["member_no_normalized"]);
});

Deno.test("import rules: the function re-checks each row it is sent", () => {
  const good = {
    source_row: 2,
    member_no: "CPC-2026-00001",
    display_name: "Fake  Person",
    dob: "1990-01-02",
    mobile: "0917",
    email: "A@B.CO",
    rfid: "RF",
  };
  const ok = validateImportRow(good, TODAY);
  assert.equal(ok.ok, true);
  assert.equal(ok.row.display_name, "Fake Person");
  assert.equal(ok.row.email, "a@b.co");
  for (
    const bad of [
      null,
      { ...good, source_row: 0 },
      { ...good, member_no: "cpc-2026-00001" },
      { ...good, member_no: "CPC-2026-1" },
      { ...good, display_name: " " },
      { ...good, dob: "01/02/1990" },
      { ...good, dob: "2999-01-01" },
      { ...good, dob: 5 },
    ]
  ) assert.equal(validateImportRow(bad, TODAY).ok, false, JSON.stringify(bad));
  assert.equal(validateImportRow({ ...good, dob: null }, TODAY).row.dob, null);
});

// ---------- handler
function world(over = {}) {
  const s = {
    users: [],
    deleted: [],
    members: [],
    issues: [],
    begun: [],
    finished: [],
    admins: [],
    scanners: [],
    passwordSets: [],
    resets: [],
    logs: [],
    passwords: [],
  };
  const deps = {
    authorize: () => Promise.resolve("token"),
    now: () => TODAY.getTime(),
    passwordDays: over.passwordDays ?? 0,
    existingPeople: (nos) =>
      Promise.resolve(
        new Map(
          s.members
            .filter((m) => nos.includes(m.member_no))
            .map((
              m,
            ) => [m.member_no, {
              display_name: m.display_name,
              date_of_birth: m.dob,
            }]),
        ),
      ),
    findReassigned: (claimed, name) => {
      const m = s.members.find((x) =>
        x.claimedNo === claimed && x.display_name === name
      );
      return Promise.resolve(m ? m.member_no : null);
    },
    enrichPerson: (memberNo, details) => {
      s.enriched = s.enriched ?? [];
      const m = s.members.find((x) => x.member_no === memberNo);
      if (!m || m.details) return Promise.resolve(false);
      m.details = details;
      s.enriched.push(memberNo);
      return Promise.resolve(true);
    },
    createAuthUser: (email, password) => {
      s.passwords.push(password);
      if (s.users.some((u) => u.email === email)) {
        return Promise.resolve({ ok: false, reason: "exists" });
      }
      const id = `uid-${s.users.length + 1}`;
      s.users.push({ id, email });
      return Promise.resolve({ ok: true, id });
    },
    deleteAuthUser: (id) => {
      s.deleted.push(id);
      return Promise.resolve();
    },
    allocate: (_batch, claimed, name, _dob, reserved) => {
      s.reserved = reserved;
      if (over.allocFails) return Promise.reject(new Error("alloc"));
      const prior = s.members.find((m) =>
        m.claimedNo === claimed && m.display_name === name
      );
      if (prior) {
        return Promise.resolve({ member_no: prior.member_no, existing: true });
      }
      s.allocated = (s.allocated ?? 0) + 1;
      return Promise.resolve({
        member_no: `CPC-2026-${String(90000 + s.allocated)}`,
        existing: false,
      });
    },
    importMember: ({ row, claimedNo, authUserId, passwordExpiresAt }) => {
      if (over.importFails?.includes(row.member_no)) {
        return Promise.reject(new Error("db"));
      }
      if (s.members.some((m) => m.member_no === row.member_no)) {
        return Promise.resolve({ outcome: "existing", rfid_cleared: false });
      }
      s.members.push({ ...row, claimedNo, authUserId, passwordExpiresAt });
      return Promise.resolve({ outcome: "created", rfid_cleared: false });
    },
    begin: (sha, n) => {
      s.begun.push({ sha, n });
      return Promise.resolve(BATCH);
    },
    finish: (id, c) => {
      s.finished.push({ id, c });
      return Promise.resolve();
    },
    issue: (id, row, no, code) => {
      s.issues.push({ id, row, no, code });
      return Promise.resolve();
    },
    createAdmin: (no, name, uid) => {
      if (over.adminExists) return Promise.reject(new Error("dup"));
      s.admins.push({ no, name, uid });
      return Promise.resolve("MEMID");
    },
    createScanner: (no, name, uid) => {
      if (over.adminExists) return Promise.reject(new Error("dup"));
      s.scanners.push({ no, name, uid });
      return Promise.resolve("MEMID");
    },
    adminResetTarget: (no) =>
      Promise.resolve(no === "CPC-2026-00000" ? "admin-uid" : null),
    setAuthPassword: (uid, pw) => {
      s.passwordSets.push({ uid, pw });
      return Promise.resolve(!over.authFails);
    },
    adminResetDone: (no) => {
      s.resets.push(no);
      return Promise.resolve();
    },
    memberResetTarget: (no) =>
      Promise.resolve(no === "CPC-2026-00001" ? "member-uid" : null),
    memberResetDone: (no) => {
      s.resets.push(no);
      return Promise.resolve();
    },
    randomPassword: () => "Adm1nPassw0rdFake",
    log: (e) => s.logs.push(e),
    ...(over.deps ?? {}),
  };
  return { deps, s };
}

const call = (body, { method = "POST", headers = {}, raw } = {}) =>
  new Request("https://example.test/member-import", {
    method,
    headers: { "content-type": "application/json", ...headers },
    body: method === "POST" ? (raw ?? JSON.stringify(body)) : undefined,
  });
const run = async (deps, body, opts) => {
  const res = await handle(call(body, opts), deps);
  return { status: res.status, body: await res.json(), headers: res.headers };
};
const row = (n, over = {}) => ({
  source_row: n,
  member_no: `CPC-2026-${String(n).padStart(5, "0")}`,
  display_name: `Fake ${n}`,
  dob: "1990-01-02",
  mobile: null,
  email: null,
  rfid: null,
  ...over,
});

Deno.test("import: creates the Auth user with the template password, then the member; the password goes nowhere else", async () => {
  const { deps, s } = world();
  const r = await run(deps, {
    action: "rows",
    batch_id: BATCH,
    rows: [row(1, { dob: "2025-12-21" })],
  });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.results, [{ source_row: 1, outcome: "created" }]);
  assert.equal(s.users[0].email, "cpc-2026-00001@members.cpc.app");
  assert.deepEqual(s.passwords, ["0000112212025"]);
  assert.equal(s.members[0].authUserId, "uid-1");
  assert.equal(
    s.members[0].passwordExpiresAt,
    null,
    "first passwords do not expire",
  );
  assert.equal(
    JSON.stringify(r.body).includes("0000112212025"),
    false,
    "the password is not in the response",
  );
});

Deno.test("import: a member without a birth date is created without an account", async () => {
  const { deps, s } = world();
  const r = await run(deps, {
    action: "rows",
    batch_id: BATCH,
    rows: [row(1, { dob: null })],
  });
  assert.deepEqual(r.body.results, [{
    source_row: 1,
    outcome: "created_no_account",
  }]);
  assert.equal(s.users.length, 0);
  assert.equal(s.members[0].authUserId, null);
  assert.equal(s.members[0].passwordExpiresAt, null);
});

Deno.test("import: re-running creates no duplicates and no extra Auth users", async () => {
  const { deps, s } = world();
  const rows = [row(1), row(2), row(3, { dob: null })];
  const first = await run(deps, { action: "rows", batch_id: BATCH, rows });
  assert.deepEqual(first.body.results.map((x) => x.outcome), [
    "created",
    "created",
    "created_no_account",
  ]);
  const second = await run(deps, { action: "rows", batch_id: BATCH, rows });
  assert.deepEqual(second.body.results.map((x) => x.outcome), [
    "existing",
    "existing",
    "existing",
  ]);
  assert.equal(s.members.length, 3);
  assert.equal(s.users.length, 2);
});

Deno.test("import: if the database step fails, the Auth user is removed and the row is reported failed", async () => {
  const { deps, s } = world({ importFails: ["CPC-2026-00002"] });
  const r = await run(deps, {
    action: "rows",
    batch_id: BATCH,
    rows: [row(1), row(2)],
  });
  assert.deepEqual(r.body.results, [
    { source_row: 1, outcome: "created" },
    { source_row: 2, outcome: "failed", reason: "database_error" },
  ]);
  assert.deepEqual(s.deleted, ["uid-2"]);
});

Deno.test("import: a race that finds the member already there removes the new Auth user", async () => {
  const { deps, s } = world({
    deps: {
      importMember: () =>
        Promise.resolve({ outcome: "existing", rfid_cleared: false }),
    },
  });
  const r = await run(deps, {
    action: "rows",
    batch_id: BATCH,
    rows: [row(1)],
  });
  assert.deepEqual(r.body.results, [{ source_row: 1, outcome: "existing" }]);
  assert.deepEqual(s.deleted, ["uid-1"]);
});

Deno.test("import: an Auth user that already exists is reported, not overwritten", async () => {
  const { deps, s } = world();
  s.users.push({ id: "old", email: "cpc-2026-00001@members.cpc.app" });
  const r = await run(deps, {
    action: "rows",
    batch_id: BATCH,
    rows: [row(1)],
  });
  assert.deepEqual(r.body.results, [{
    source_row: 1,
    outcome: "failed",
    reason: "auth_user_exists",
  }]);
  assert.equal(s.members.length, 0);
});

Deno.test("import: bad rows are refused individually, and the rest still go through", async () => {
  const { deps, s } = world();
  const r = await run(deps, {
    action: "rows",
    batch_id: BATCH,
    rows: [row(1), row(2, { member_no: "bad" }), row(3, { dob: "1800-01-01" })],
  });
  assert.deepEqual(
    r.body.results.map((x) => [x.source_row, x.outcome, x.reason]),
    [
      [1, "created", undefined],
      [2, "failed", "bad_member_no"],
      [3, "failed", "bad_birth_date"],
    ],
  );
  assert.equal(s.members.length, 1);
});

Deno.test("import: begin, issues and finish are validated and recorded", async () => {
  const { deps, s } = world();
  assert.equal(
    (await run(deps, {
      action: "begin",
      file_sha256: "a".repeat(64),
      row_count: 10,
    })).body.batch_id,
    BATCH,
  );
  assert.equal(
    (await run(deps, { action: "begin", file_sha256: "nope", row_count: 10 }))
      .status,
    400,
  );
  const issues = await run(deps, {
    action: "issues",
    batch_id: BATCH,
    issues: [
      {
        source_row: 5,
        member_no_claimed: "CPC-2026-00010",
        issue_code: "duplicate_member_no",
      },
      { source_row: 6, member_no_claimed: null, issue_code: "made_up" },
      { source_row: 0, member_no_claimed: null, issue_code: "missing_name" },
    ],
  });
  assert.equal(
    issues.body.recorded,
    1,
    "unknown codes and bad rows are skipped",
  );
  assert.deepEqual(s.issues, [{
    id: BATCH,
    row: 5,
    no: "CPC-2026-00010",
    code: "duplicate_member_no",
  }]);
  assert.equal(
    (await run(deps, {
      action: "finish",
      batch_id: BATCH,
      created: 3,
      skipped: 2,
      held_back: 1,
      failed: 0,
    })).status,
    200,
  );
  assert.deepEqual(s.finished[0], {
    id: BATCH,
    c: { created: 3, skipped: 2, held_back: 1, failed: 0 },
  });
  assert.equal(
    (await run(deps, {
      action: "finish",
      batch_id: "x",
      created: 3,
      skipped: 2,
      held_back: 1,
      failed: 0,
    })).status,
    400,
  );
});

Deno.test("import: batch size and body size are limited", async () => {
  const { deps } = world();
  const many = Array.from(
    { length: MAX_ROWS_PER_CALL + 1 },
    (_, i) => row(i + 1),
  );
  assert.equal(
    (await run(deps, { action: "rows", batch_id: BATCH, rows: many })).status,
    400,
  );
  assert.equal(
    (await run(deps, { action: "rows", batch_id: BATCH, rows: [] })).status,
    400,
  );
  assert.equal(
    (await run(deps, null, { raw: "x".repeat(300_000) })).status,
    413,
  );
  assert.equal((await run(deps, null, { raw: "{oops" })).status, 400);
  assert.equal((await run(deps, { action: "dance" })).status, 400);
});

Deno.test("import: no credentials, no entry; browsers are turned away; only POST", async () => {
  const { deps, s } = world({
    deps: { authorize: () => Promise.resolve(null) },
  });
  const r = await run(deps, {
    action: "rows",
    batch_id: BATCH,
    rows: [row(1)],
  });
  assert.equal(r.status, 401);
  assert.deepEqual(r.body, { ok: false, code: "unauthorized" });
  assert.equal(s.members.length, 0);
  const open = world();
  assert.equal(
    (await run(open.deps, {
      action: "begin",
      file_sha256: "a".repeat(64),
      row_count: 1,
    }, { headers: { origin: "https://evil.example" } })).status,
    403,
  );
  assert.equal((await run(open.deps, null, { method: "GET" })).status, 405);
});

Deno.test("import: the first admin is created once, and the password is returned once", async () => {
  const { deps, s } = world();
  const r = await run(deps, {
    action: "create_admin",
    member_no: "CPC-2026-00000",
    display_name: "Club Administrator",
  });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, {
    ok: true,
    member_no: "CPC-2026-00000",
    password: "Adm1nPassw0rdFake",
  });
  assert.equal(s.users[0].email, "cpc-2026-00000@members.cpc.app");
  assert.deepEqual(s.admins[0], {
    no: "CPC-2026-00000",
    name: "Club Administrator",
    uid: "uid-1",
  });
  assert.equal(r.headers.get("cache-control"), "no-store");
  const again = await run(deps, {
    action: "create_admin",
    member_no: "CPC-2026-00000",
    display_name: "Club Administrator",
  });
  assert.equal(again.status, 409, "the Auth user already exists");
  assert.equal(JSON.stringify(again.body).includes("Adm1n"), false);
});

Deno.test("import: a scanner account is created once, with the password returned once", async () => {
  const { deps, s } = world();
  const r = await run(deps, {
    action: "create_scanner",
    member_no: "CPC-2026-90001",
    display_name: "Court Scanner",
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.ok, true);
  assert.equal(r.body.member_no, "CPC-2026-90001");
  assert.deepEqual(s.scanners[0], {
    no: "CPC-2026-90001",
    name: "Court Scanner",
    uid: "uid-1",
  });
  assert.equal(s.admins.length, 0, "a scanner is never an admin");
  assert.equal(
    (await run(world().deps, {
      action: "create_scanner",
      member_no: "bad",
      display_name: "x",
    })).status,
    400,
  );
  const dup = await run(world({ adminExists: true }).deps, {
    action: "create_scanner",
    member_no: "CPC-2026-90001",
    display_name: "Court Scanner",
  });
  assert.equal(dup.status, 409);
});

Deno.test("import: if the admin rows fail, the Auth user is removed", async () => {
  const { deps, s } = world({ adminExists: true });
  const r = await run(deps, {
    action: "create_admin",
    member_no: "CPC-2026-00000",
    display_name: "Club Administrator",
  });
  assert.equal(r.status, 409);
  assert.deepEqual(s.deleted, ["uid-1"]);
  assert.equal(
    (await run(world().deps, {
      action: "create_admin",
      member_no: "bad",
      display_name: "x",
    })).status,
    400,
  );
  assert.equal(
    internalEmail("CPC-2026-00000"),
    "cpc-2026-00000@members.cpc.app",
  );
});

Deno.test("import: a row with a shared ID gets a new number, its own password, and the old ID is remembered", async () => {
  const { deps, s } = world();
  const first = row(1, { dob: "1990-01-02" });
  const shared = row(2, {
    member_no: "CPC-2026-00001",
    dob: "2025-12-21",
    needs_new_id: true,
    display_name: "Fake Second Person",
  });
  const r = await run(deps, {
    action: "rows",
    batch_id: BATCH,
    rows: [first, shared],
  });
  assert.deepEqual(r.body.results, [
    { source_row: 1, outcome: "created" },
    {
      source_row: 2,
      outcome: "created",
      member_no: "CPC-2026-90001",
      reassigned_from: "CPC-2026-00001",
    },
  ]);
  assert.equal(s.users[1].email, "cpc-2026-90001@members.cpc.app");
  assert.equal(
    s.passwords[1],
    "9000112212025",
    "the password uses the NEW number",
  );
  const stored = s.members.find((m) => m.member_no === "CPC-2026-90001");
  assert.equal(stored.claimedNo, "CPC-2026-00001");
});

Deno.test("import: re-running finds the reassigned person again and allocates nothing new", async () => {
  const { deps, s } = world();
  const rows = [
    row(1),
    row(2, {
      member_no: "CPC-2026-00001",
      needs_new_id: true,
      display_name: "Fake Second Person",
    }),
  ];
  await run(deps, { action: "rows", batch_id: BATCH, rows });
  const again = await run(deps, { action: "rows", batch_id: BATCH, rows });
  assert.deepEqual(again.body.results.map((x) => x.outcome), [
    "existing",
    "existing",
  ]);
  assert.equal(again.body.results[1].member_no, "CPC-2026-90001");
  assert.equal(s.allocated, 1);
  assert.equal(s.members.length, 2);
  assert.equal(s.users.length, 2);
});

Deno.test("import: if allocating a number fails, no account is created", async () => {
  const { deps, s } = world({ allocFails: true });
  const r = await run(deps, {
    action: "rows",
    batch_id: BATCH,
    rows: [row(2, { needs_new_id: true })],
  });
  assert.deepEqual(r.body.results, [{
    source_row: 2,
    outcome: "failed",
    reason: "allocation_failed",
  }]);
  assert.equal(s.users.length, 0);
});

Deno.test("import: a number held by a different person is not skipped: the newcomer gets a new number", async () => {
  const { deps, s } = world();
  await run(deps, {
    action: "rows",
    batch_id: BATCH,
    rows: [row(1, { display_name: "Fake Holder" })],
  });
  const newcomer = row(2, {
    member_no: "CPC-2026-00001",
    display_name: "Fake Newcomer",
    dob: "1995-05-05",
  });
  const r = await run(deps, {
    action: "rows",
    batch_id: BATCH,
    rows: [newcomer],
  });
  assert.deepEqual(r.body.results, [
    {
      source_row: 2,
      outcome: "created",
      member_no: "CPC-2026-90001",
      reassigned_from: "CPC-2026-00001",
    },
  ]);
  assert.equal(s.members.length, 2);
  const again = await run(deps, {
    action: "rows",
    batch_id: BATCH,
    rows: [newcomer],
  });
  assert.equal(again.body.results[0].outcome, "existing");
  assert.equal(s.members.length, 2);
});

Deno.test("import: the same person under the same number is existing, despite spacing or case", async () => {
  const { deps, s } = world();
  await run(deps, {
    action: "rows",
    batch_id: BATCH,
    rows: [row(1, { display_name: "Fake Holder", dob: null })],
  });
  const r = await run(deps, {
    action: "rows",
    batch_id: BATCH,
    rows: [row(1, { display_name: "  fake   HOLDER ", dob: "1990-01-02" })],
  });
  assert.deepEqual(r.body.results, [{ source_row: 1, outcome: "existing" }]);
  assert.equal(s.members.length, 1);
});

Deno.test("import: the allocator is told every ID the file uses, and the list is validated", async () => {
  const { deps, s } = world();
  await run(deps, {
    action: "rows",
    batch_id: BATCH,
    rows: [row(2, { needs_new_id: true })],
    reserved_nos: ["CPC-2026-00005", "CPC-2026-00006"],
  });
  assert.deepEqual(s.reserved, ["CPC-2026-00005", "CPC-2026-00006"]);
  assert.equal(
    (await run(deps, {
      action: "rows",
      batch_id: BATCH,
      rows: [row(3)],
      reserved_nos: ["bad"],
    })).status,
    400,
  );
  assert.equal(
    (await run(deps, {
      action: "rows",
      batch_id: BATCH,
      rows: [row(3)],
      reserved_nos: Array(5001).fill("CPC-2026-00001"),
    })).status,
    400,
  );
});

Deno.test("import: an expiry can still be switched on (passwordDays above 0)", async () => {
  const { deps, s } = world({ passwordDays: 30 });
  await run(deps, { action: "rows", batch_id: BATCH, rows: [row(1)] });
  assert.equal(
    s.members[0].passwordExpiresAt,
    new Date(TODAY.getTime() + 30 * 86_400_000).toISOString(),
  );
});

// ---------- enrich: details from the spreadsheet
Deno.test("details: suffix and gender are normalized, names are tidied", () => {
  assert.equal(normalizeSuffix("JR"), "Jr.");
  assert.equal(normalizeSuffix(" jr. "), "Jr.");
  assert.equal(normalizeSuffix("Sr"), "Sr.");
  assert.equal(normalizeSuffix("III"), "III");
  assert.equal(normalizeSuffix("N/A"), null);
  assert.equal(normalizeSuffix(""), null);
  for (
    const [raw, want] of [
      ["Male", "male"],
      ["M", "male"],
      ["FEMALE", "female"],
      ["f", "female"],
      ["", null],
      ["other", null],
      [null, null],
    ]
  ) {
    assert.equal(normalizeGender(raw), want, String(raw));
  }
});

Deno.test("details: a whole row is cleaned, shouting names are title-cased, a half emergency contact is dropped", () => {
  const d = cleanDetails({
    row: 2,
    id_no: "x",
    display_name: "x",
    dob: null,
    dob_text: null,
    mobile: null,
    email: null,
    rfid: null,
    last_name: "MARQUEZ",
    first_name: "Kyle",
    middle_name: "dela cruz",
    suffix: "JR",
    gender: "Male",
    em_name: "ANA MARQUEZ",
    em_rel: "Mother",
    em_phone: "0917 555 0001",
  });
  assert.deepEqual(d, {
    first_name: "Kyle",
    middle_name: "dela cruz",
    last_name: "Marquez",
    suffix: "Jr.",
    gender: "male",
    emergency_name: "Ana Marquez",
    emergency_relationship: "Mother",
    emergency_phone: "09175550001",
  });
  const half = cleanDetails({
    row: 3,
    id_no: "x",
    display_name: "x",
    dob: null,
    dob_text: null,
    mobile: null,
    email: null,
    rfid: null,
    em_name: "Only Name",
    em_phone: "12",
  });
  assert.deepEqual([
    half.emergency_name,
    half.emergency_phone,
    half.emergency_relationship,
  ], [null, null, null]);
  const none = cleanDetails({
    row: 4,
    id_no: "x",
    display_name: "x",
    dob: null,
    dob_text: null,
    mobile: null,
    email: null,
    rfid: null,
  });
  assert.ok(Object.values(none).every((v) => v === null));
});

Deno.test("details: the whole-file pass carries each row's details", () => {
  const a = analyzeFile([{
    ...raw(2),
    last_name: "Reyes",
    first_name: "Ana",
    gender: "F",
  }], TODAY);
  assert.equal(a.rows[0].details.last_name, "Reyes");
  assert.equal(a.rows[0].details.gender, "female");
});

Deno.test("details: the function re-checks each enrich row", () => {
  const base = {
    source_row: 2,
    member_no: "CPC-2026-00001",
    display_name: "Fake Person",
    dob: "1990-01-02",
  };
  const ok = validateEnrichRow({
    ...base,
    details: {
      first_name: "Fake",
      suffix: "Esq",
      gender: "other",
      emergency_name: "N",
      emergency_phone: "12",
      last_name: " Person ",
    },
  });
  assert.equal(ok.ok, true);
  assert.deepEqual(ok.row.details, {
    first_name: "Fake",
    middle_name: null,
    last_name: "Person",
    suffix: null,
    gender: null,
    emergency_name: null,
    emergency_relationship: null,
    emergency_phone: null,
  });
  assert.equal(
    validateEnrichRow({ ...base, member_no: "bad", details: {} }).ok,
    false,
  );
  assert.equal(
    validateEnrichRow({ ...base, details: { suffix: "Jr.", gender: "female" } })
      .row.details.suffix,
    "Jr.",
  );
});

const erow = (n, over = {}) => ({
  ...row(n),
  details: { first_name: "Fake", last_name: `Person${n}`, gender: "male" },
  ...over,
});

Deno.test("enrich: a matching member is filled in, and a second run changes nothing", async () => {
  const { deps, s } = world();
  await run(deps, { action: "rows", batch_id: BATCH, rows: [row(1), row(2)] });
  const first = await run(deps, { action: "enrich", rows: [erow(1), erow(2)] });
  assert.equal(first.status, 200);
  assert.deepEqual(first.body.results.map((r) => r.outcome), [
    "updated",
    "updated",
  ]);
  assert.equal(s.members[0].details.last_name, "Person1");
  const again = await run(deps, { action: "enrich", rows: [erow(1), erow(2)] });
  assert.deepEqual(again.body.results.map((r) => r.outcome), [
    "unchanged",
    "unchanged",
  ]);
});

Deno.test("enrich: a person who was given a new number is found by the ID they claimed", async () => {
  const { deps, s } = world();
  const moved = row(2, {
    member_no: "CPC-2026-00001",
    needs_new_id: true,
    display_name: "Fake Second Person",
  });
  await run(deps, { action: "rows", batch_id: BATCH, rows: [row(1), moved] });
  const r = await run(deps, {
    action: "enrich",
    rows: [
      erow(2, {
        member_no: "CPC-2026-00001",
        needs_new_id: true,
        display_name: "Fake Second Person",
      }),
    ],
  });
  assert.deepEqual(r.body.results, [{ source_row: 2, outcome: "updated" }]);
  assert.equal(
    s.enriched[0],
    "CPC-2026-90001",
    "the new number, not the first row's",
  );
});

Deno.test("enrich: the first holder of an ID is not enriched with someone else's details", async () => {
  const { deps, s } = world();
  await run(deps, {
    action: "rows",
    batch_id: BATCH,
    rows: [row(1, { display_name: "Fake Holder" })],
  });
  const r = await run(deps, {
    action: "enrich",
    rows: [
      erow(2, {
        member_no: "CPC-2026-00001",
        display_name: "Fake Stranger",
        dob: "1980-05-05",
      }),
    ],
  });
  assert.deepEqual(r.body.results, [{ source_row: 2, outcome: "not_found" }]);
  assert.equal(s.enriched, undefined);
});

Deno.test("enrich: unknown members are reported, bad rows refused, sizes limited, access required", async () => {
  const { deps } = world();
  assert.deepEqual(
    (await run(deps, { action: "enrich", rows: [erow(9)] })).body.results,
    [{ source_row: 9, outcome: "not_found" }],
  );
  const bad = await run(deps, {
    action: "enrich",
    rows: [{ source_row: 3, member_no: "nope" }],
  });
  assert.deepEqual(bad.body.results.map((r) => [r.source_row, r.outcome]), [[
    3,
    "failed",
  ]]);
  assert.equal((await run(deps, { action: "enrich", rows: [] })).status, 400);
  assert.equal(
    (await run(deps, {
      action: "enrich",
      rows: Array.from({ length: 61 }, (_, i) => erow(i + 1)),
    })).status,
    400,
  );
  const locked = world({ deps: { authorize: () => Promise.resolve(null) } });
  assert.equal(
    (await run(locked.deps, { action: "enrich", rows: [erow(1)] })).status,
    401,
  );
});

Deno.test("import: an admin who forgot the password gets a new random one, once, and must change it at sign-in", async () => {
  const { deps, s } = world();
  const r = await run(deps, {
    action: "reset_admin_password",
    member_no: "CPC-2026-00000",
  });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, {
    ok: true,
    member_no: "CPC-2026-00000",
    password: "Adm1nPassw0rdFake",
  });
  assert.deepEqual(s.passwordSets, [{
    uid: "admin-uid",
    pw: "Adm1nPassw0rdFake",
  }]);
  assert.deepEqual(
    s.resets,
    ["CPC-2026-00000"],
    "marked for a forced change and audited",
  );
  assert.equal(r.headers.get("cache-control"), "no-store");
  assert.equal(
    JSON.stringify(s.logs).includes("Adm1n"),
    false,
    "the log never holds the password",
  );
});

Deno.test("import: the reset works only for an admin, and nothing is changed for anyone else", async () => {
  const { deps, s } = world();
  const r = await run(deps, {
    action: "reset_admin_password",
    member_no: "CPC-2026-00001",
  });
  assert.equal(r.status, 404);
  assert.equal(JSON.stringify(r.body).includes("Adm1n"), false);
  assert.deepEqual(s.passwordSets, []);
  const bad = await run(deps, {
    action: "reset_admin_password",
    member_no: "nope",
  });
  assert.equal(bad.status, 400);
});

Deno.test("import: if Auth refuses the new password, nothing is marked and no password is returned", async () => {
  const { deps, s } = world({ authFails: true });
  const r = await run(deps, {
    action: "reset_admin_password",
    member_no: "CPC-2026-00000",
  });
  assert.equal(r.status, 502);
  assert.equal(JSON.stringify(r.body).includes("Adm1n"), false);
  assert.deepEqual(s.resets, []);
});

Deno.test("import: a member who forgot the password gets a new random one, once, and must change it at sign-in", async () => {
  const { deps, s } = world();
  const r = await run(deps, {
    action: "reset_member_password",
    member_no: "CPC-2026-00001",
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.member_no, "CPC-2026-00001");
  assert.deepEqual(s.passwordSets, [{
    uid: "member-uid",
    pw: "Adm1nPassw0rdFake",
  }]);
  assert.deepEqual(s.resets, ["CPC-2026-00001"]);
  assert.equal(JSON.stringify(s.logs).includes("Adm1n"), false);
  const none = await run(deps, {
    action: "reset_member_password",
    member_no: "CPC-2026-00777",
  });
  assert.equal(none.status, 404);
  assert.equal(
    s.passwordSets.length,
    1,
    "nothing changed for an unknown member",
  );
});
