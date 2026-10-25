import assert from "node:assert/strict";
import {
  buildSlots,
  freeRun,
  hoursFor,
  manilaDate,
  parseRange,
  timeLabel,
  weekdayOf,
} from "../../web/lib/slot-grid.js";

const DAY = "2030-02-04"; // a Monday
const hours = [
  {
    court_id: null,
    weekday: 1,
    opens_at: "08:00:00",
    closes_at: "21:00:00",
    valid_from: "2000-01-01",
    valid_to: null,
  },
  {
    court_id: "C1",
    weekday: 1,
    opens_at: "09:00:00",
    closes_at: "12:00:00",
    valid_from: "2000-01-01",
    valid_to: null,
  },
];
const now = new Date("2030-02-01T00:00:00+08:00");

Deno.test("slot grid: Manila wall-clock times and weekdays", () => {
  assert.equal(
    manilaDate(DAY, "08:30").toISOString(),
    "2030-02-04T00:30:00.000Z",
  );
  assert.equal(weekdayOf(DAY), 1);
  assert.equal(weekdayOf("2030-02-03"), 0);
  assert.equal(timeLabel(new Date("2030-02-04T01:00:00Z")), "9:00 AM");
});

Deno.test("slot grid: a court's own hours beat the all-courts hours, and dates are respected", () => {
  assert.equal(hoursFor(hours, "C1", DAY).opens_at, "09:00:00");
  assert.equal(hoursFor(hours, "C2", DAY).opens_at, "08:00:00");
  assert.equal(
    hoursFor(hours, "C1", "2030-02-05"),
    null,
    "no hours on a Tuesday",
  );
  const ended = [{ ...hours[0], valid_to: "2030-01-31" }];
  assert.equal(hoursFor(ended, "C2", DAY), null, "ended hours do not apply");
  const newer = [...hours, {
    court_id: "C1",
    weekday: 1,
    opens_at: "10:00:00",
    closes_at: "12:00:00",
    valid_from: "2030-01-01",
    valid_to: null,
  }];
  assert.equal(
    hoursFor(newer, "C1", DAY).opens_at,
    "10:00:00",
    "the latest start date wins",
  );
});

Deno.test("slot grid: one slot per hour from opening to closing", () => {
  const slots = buildSlots({
    day: DAY,
    courtId: "C2",
    hours,
    slotMinutes: 60,
    now,
  });
  assert.equal(slots.length, 13);
  assert.equal(timeLabel(slots[0].start), "8:00 AM");
  assert.equal(timeLabel(slots.at(-1).start), "8:00 PM");
  assert.ok(slots.every((s) => s.state === "free"));
  const half = buildSlots({
    day: DAY,
    courtId: "C1",
    hours,
    slotMinutes: 90,
    now,
  });
  assert.equal(half.length, 2, "09:00-12:00 holds two 90 minute slots");
  assert.deepEqual(
    buildSlots({
      day: "2030-02-05",
      courtId: "C1",
      hours,
      slotMinutes: 60,
      now,
    }),
    [],
  );
});

Deno.test("slot grid: booked and closed ranges, the past, and the booking window", () => {
  const taken = [
    {
      start: manilaDate(DAY, "10:00"),
      end: manilaDate(DAY, "12:00"),
      kind: "booked",
      label: "Taken",
    },
    {
      start: manilaDate(DAY, "14:00"),
      end: manilaDate(DAY, "15:00"),
      kind: "closed",
    },
  ];
  const slots = buildSlots({
    day: DAY,
    courtId: "C2",
    hours,
    slotMinutes: 60,
    taken,
    now,
  });
  const state = (t) => slots.find((s) => timeLabel(s.start) === t).state;
  assert.equal(state("9:00 AM"), "free");
  assert.equal(state("10:00 AM"), "booked");
  assert.equal(state("11:00 AM"), "booked");
  assert.equal(state("12:00 PM"), "free");
  assert.equal(state("2:00 PM"), "closed");
  const later = buildSlots({
    day: DAY,
    courtId: "C2",
    hours,
    slotMinutes: 60,
    now: new Date("2030-02-04T05:30:00Z"),
  });
  assert.equal(
    later.find((s) => timeLabel(s.start) === "1:00 PM").state,
    "past",
    "13:00 Manila has started",
  );
  assert.equal(
    later.find((s) => timeLabel(s.start) === "2:00 PM").state,
    "free",
  );
  const far = buildSlots({
    day: DAY,
    courtId: "C2",
    hours,
    slotMinutes: 60,
    now,
    advanceDays: 2,
  });
  assert.ok(far.every((s) => s.state === "far"), "beyond the booking window");
});

Deno.test("slot grid: a run of free slots limits how long a booking can be", () => {
  const taken = [{
    start: manilaDate(DAY, "11:00"),
    end: manilaDate(DAY, "12:00"),
    kind: "booked",
  }];
  const slots = buildSlots({
    day: DAY,
    courtId: "C2",
    hours,
    slotMinutes: 60,
    taken,
    now,
  });
  assert.equal(freeRun(slots, 0), 3, "08:00 to 11:00");
  assert.equal(freeRun(slots, 3), 0, "11:00 is taken");
  assert.equal(freeRun(slots, 4, 2), 2, "capped at the maximum");
});

Deno.test("slot grid: reads a PostgREST time range", () => {
  const r = parseRange('["2030-02-04 02:00:00+00","2030-02-04 03:00:00+00")');
  assert.equal(r.start.toISOString(), "2030-02-04T02:00:00.000Z");
  assert.equal(r.end.toISOString(), "2030-02-04T03:00:00.000Z");
  assert.equal(parseRange("nonsense"), null);
});
