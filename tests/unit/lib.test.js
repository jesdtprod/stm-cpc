import assert from "node:assert/strict";
import {
  addDays,
  businessDate,
  dayBounds,
  firstOfMonth,
  formatDate,
  formatDateTime,
  isBusinessDate,
  presetRange,
} from "../../web/lib/dates.js";
import { escapeHtml, safeRoute, safeUrl } from "../../web/lib/escape.js";
import {
  centavosToDecimal,
  formatMoney,
  parseCentavos,
} from "../../web/lib/money.js";
import {
  clampPageSize,
  fetchLimit,
  pageFromRows,
} from "../../web/lib/paginate.js";
import { isUlid, ulid, ulidTime } from "../../web/lib/ulid.js";
import { validate } from "../../web/lib/validate.js";

Deno.test("ulid: matches the database format check", () => {
  for (let i = 0; i < 500; i++) {
    const id = ulid();
    assert.equal(id.length, 26);
    assert.match(id, /^[0-7][0-9A-HJKMNP-TV-Z]{25}$/);
    assert.ok(isUlid(id));
  }
});

Deno.test("ulid: sorts by time and decodes its timestamp", () => {
  const a = ulid(1_700_000_000_000);
  const b = ulid(1_700_000_000_001);
  const c = ulid(1_800_000_000_000);
  assert.ok(a.slice(0, 10) < b.slice(0, 10));
  assert.ok(b < c);
  assert.equal(ulidTime(a).getTime(), 1_700_000_000_000);
  assert.equal(ulidTime(c).getTime(), 1_800_000_000_000);
});

Deno.test("ulid: IDs are distinct and bad input is rejected", () => {
  assert.equal(new Set(Array.from({ length: 5000 }, () => ulid())).size, 5000);
  assert.equal(isUlid("not-a-ulid"), false);
  assert.equal(isUlid("8ZZZZZZZZZZZZZZZZZZZZZZZZZ"), false);
  assert.equal(isUlid(null), false);
  assert.throws(() => ulid(-1), RangeError);
  assert.throws(() => ulidTime("bad"), RangeError);
});

Deno.test("dates: business date uses Asia/Manila, not the machine zone", () => {
  // 2026-10-23 17:00 UTC is already 2026-10-24 01:00 in Manila.
  assert.equal(businessDate("2026-10-23T17:00:00Z"), "2026-10-24");
  assert.equal(businessDate("2026-10-23T15:59:59Z"), "2026-10-23");
});

Deno.test("dates: presets follow UI_DESIGN section 7", () => {
  const now = "2026-10-23T05:00:00Z";
  assert.deepEqual(presetRange("this_month", now), {
    from: "2026-10-01",
    to: "2026-10-23",
  });
  assert.deepEqual(presetRange("last_30_days", now), {
    from: "2026-09-24",
    to: "2026-10-23",
  });
  assert.deepEqual(presetRange("all_time", now), { from: null, to: null });
  assert.throws(() => presetRange("yesterday"), RangeError);
});

Deno.test("dates: arithmetic, validation and day bounds", () => {
  assert.equal(addDays("2026-02-28", 1), "2026-03-01");
  assert.equal(addDays("2026-03-01", -1), "2026-02-28");
  assert.equal(firstOfMonth("2026-10-23"), "2026-10-01");
  assert.ok(isBusinessDate("2026-02-28"));
  assert.ok(!isBusinessDate("2026-02-30"));
  assert.ok(!isBusinessDate("23/10/2026"));
  assert.deepEqual(dayBounds("2026-10-24"), {
    from: "2026-10-23T16:00:00.000Z",
    to: "2026-10-24T16:00:00.000Z",
  });
  assert.match(formatDate("2026-10-23T05:00:00Z"), /Oct 23, 2026/);
  assert.match(formatDateTime("2026-10-23T05:00:00Z"), /1:00/);
});

Deno.test("money: format, parse and round-trip without floating point drift", () => {
  assert.equal(formatMoney("1250.5"), "₱1,250.50");
  assert.equal(formatMoney(0), "₱0.00");
  assert.throws(() => formatMoney("abc"), RangeError);
  assert.equal(parseCentavos("₱1,250.5"), 125050);
  assert.equal(parseCentavos("0.07"), 7);
  assert.equal(parseCentavos("19.99"), 1999);
  assert.equal(parseCentavos("1.234"), null);
  assert.equal(parseCentavos("-5"), null);
  assert.equal(parseCentavos(""), null);
  assert.equal(centavosToDecimal(125050), "1250.50");
  assert.equal(centavosToDecimal(7), "0.07");
  assert.equal(centavosToDecimal(parseCentavos("19.99")), "19.99");
});

Deno.test("escape: html, urls and redirect targets", () => {
  assert.equal(
    escapeHtml(`<img src=x onerror="a&b">`),
    "&lt;img src=x onerror=&quot;a&amp;b&quot;&gt;",
  );
  assert.equal(escapeHtml(null), "");
  assert.equal(safeUrl("https://example.com/a"), "https://example.com/a");
  assert.equal(safeUrl("mailto:a@example.test"), "mailto:a@example.test");
  assert.equal(safeUrl("javascript:alert(1)"), null);
  assert.equal(safeUrl("data:text/html,x"), null);
  assert.equal(safeUrl("http://example.com"), null);
  assert.equal(safeUrl("not a url"), null);
  assert.equal(safeRoute("#/bookings"), "#/bookings");
  assert.equal(safeRoute("https://evil.example"), "#/");
  assert.equal(safeRoute("#//evil.example"), "#/");
});

Deno.test("paginate: keyset pages", () => {
  assert.equal(clampPageSize(500), 100);
  assert.equal(clampPageSize(0), 20);
  assert.equal(fetchLimit(10), 11);
  const rows = Array.from({ length: 11 }, (_, i) => ({ id: `id${10 - i}` }));
  const page = pageFromRows(rows, 10);
  assert.equal(page.items.length, 10);
  assert.equal(page.hasMore, true);
  assert.equal(page.nextCursor, "id1");
  const last = pageFromRows(rows.slice(0, 4), 10);
  assert.equal(last.hasMore, false);
  assert.equal(last.nextCursor, null);
  assert.deepEqual(pageFromRows([], 10), {
    items: [],
    hasMore: false,
    nextCursor: null,
  });
});

Deno.test("validate: required, length, email, mobile, pattern, custom", () => {
  const schema = {
    name: { label: "Name", required: true, max: 10 },
    email: { label: "Email", email: true },
    mobile: { label: "Mobile", mobilePH: true },
    code: {
      label: "Code",
      pattern: /^[A-Z]{3}$/,
      patternMessage: "Use three capital letters.",
    },
    confirm: {
      label: "Confirmation",
      custom: (
        v,
        all,
      ) => (v === all.password ? null : "Passwords do not match."),
    },
  };
  const bad = validate({
    name: "  ",
    email: "nope",
    mobile: "123",
    code: "ab",
    confirm: "x",
    password: "y",
  }, schema);
  assert.equal(bad.ok, false);
  assert.deepEqual(Object.keys(bad.errors).sort(), [
    "code",
    "confirm",
    "email",
    "mobile",
    "name",
  ]);
  assert.equal(bad.errors.name, "Name is required.");
  assert.equal(bad.errors.code, "Use three capital letters.");
  const good = validate({
    name: "Ana",
    email: "a@example.test",
    mobile: "0917 123 4567",
    code: "ABC",
    confirm: "y",
    password: "y",
  }, schema);
  assert.deepEqual(good, { ok: true, errors: {} });
  assert.equal(
    validate({ name: "x".repeat(11) }, schema).errors.name,
    "Name must be at most 10 characters.",
  );
  assert.equal(
    validate({ name: "Ana", mobile: "+639171234567" }, schema).ok,
    true,
  );
});
