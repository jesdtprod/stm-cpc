import { formatEventDates } from "../../web/lib/dates.js";

Deno.test("event dates: compact ranges preserve month and year boundaries", () => {
  for (const [from, to, expected] of [
    ["2026-11-07", "2026-11-08", "Nov 7–8, 2026"],
    ["2026-11-07", "2026-11-07", "Nov 7, 2026"],
    ["2026-11-07", null, "Nov 7, 2026"],
    ["2026-11-30", "2026-12-01", "Nov 30–Dec 1, 2026"],
    ["2026-12-31", "2027-01-01", "Dec 31, 2026–Jan 1, 2027"],
  ]) {
    const actual = formatEventDates(from, to);
    if (actual !== expected) throw new Error(`Expected ${expected}, got ${actual}`);
  }
});
