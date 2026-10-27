import assert from "node:assert/strict";
import { formatMemberName } from "../../web/lib/names.js";

Deno.test("member names: last name, full first name, middle initial and extension", () => {
  const person = Object.freeze({
    first_name: "  juAN   paBLO ",
    middle_name: "  maRIA luz ",
    last_name: "DELA CRUZ",
    suffix: "jr.",
    display_name: "A different nickname",
  });
  assert.equal(formatMemberName(person), "Dela Cruz, Juan Pablo M. Jr.");
});

Deno.test("member names: optional middle names and extensions add no stray punctuation", () => {
  assert.equal(
    formatMemberName({ first_name: "ANA", last_name: "REYES" }),
    "Reyes, Ana",
  );
  assert.equal(
    formatMemberName({
      first_name: "ANA",
      last_name: "REYES",
      middle_name: "b.",
    }),
    "Reyes, Ana B.",
  );
  for (
    const [suffix, expected] of [["ii", "II"], ["III", "III"], ["iv", "IV"], [
      "v",
      "V",
    ], ["SR.", "Sr."]]
  ) {
    assert.equal(
      formatMemberName({ first_name: "ANA", last_name: "REYES", suffix }),
      `Reyes, Ana ${expected}`,
    );
  }
});

Deno.test("member names: accents, compound names, apostrophes and hyphens use proper case", () => {
  assert.equal(
    formatMemberName({
      first_name: "MARÍA-LUZ",
      middle_name: "ñora",
      last_name: "O’NEIL",
    }),
    "O’Neil, María-Luz Ñ.",
  );
  assert.equal(
    formatMemberName({ first_name: "jean", last_name: "d'ANGELO" }),
    "D'Angelo, Jean",
  );
});

Deno.test("member names: display name fallback does not guess or mix missing parts", () => {
  for (
    const person of [
      { display_name: "  saMPLE   CLUB PLAYER  " },
      { first_name: "Ana", display_name: "  saMPLE   CLUB PLAYER  " },
      { last_name: "Reyes", display_name: "  saMPLE   CLUB PLAYER  " },
    ]
  ) assert.equal(formatMemberName(person), "Sample Club Player");
  assert.equal(
    formatMemberName({ display_name: "sample player iii" }),
    "Sample Player III",
  );
  assert.equal(
    formatMemberName({ display_name: "sample player jr." }),
    "Sample Player Jr.",
  );
});

Deno.test("member names: absent names and display text remain safe plain strings", () => {
  assert.equal(formatMemberName(), "Unknown");
  assert.equal(formatMemberName({ display_name: " " }), "Unknown");
  assert.equal(formatMemberName({ first_name: "ana" }), "Ana");
  assert.equal(formatMemberName({ display_name: "<SCRIPT>" }), "<script>");
});
