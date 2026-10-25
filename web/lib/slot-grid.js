// Court slots for one day (PLAN 5.4). Pure functions, no DOM: the screens use them to draw the availability grid, and the
// unit tests check them. The server decides what is bookable; this only shows it.
// All wall-clock times are Asia/Manila, which has no daylight saving time (always +08:00).

const OFFSET = "+08:00";

/** "2030-02-01" + "08:30" (or "08:30:00") -> a Date at that Manila time. */
export function manilaDate(day, time) {
  return new Date(`${day}T${String(time).slice(0, 5)}:00${OFFSET}`);
}

/** Day of week (0 = Sunday) of a "YYYY-MM-DD" date. */
export function weekdayOf(day) {
  return new Date(`${day}T12:00:00${OFFSET}`).getUTCDay();
}

/** A PostgREST tstzrange such as ["2030-02-01 01:00:00+00","2030-02-01 04:00:00+00") -> { start, end } (Dates). */
export function parseRange(text) {
  const m = /"([^"]+)","([^"]+)"/.exec(String(text));
  if (!m) return null;
  const toDate = (s) => {
    let v = s.replace(" ", "T");
    if (/[+-]\d\d$/.test(v)) v += ":00";
    return new Date(v);
  };
  return { start: toDate(m[1]), end: toDate(m[2]) };
}

/** The hours that apply to a court on a day: its own dated row beats the "all courts" row. */
export function hoursFor(hours, courtId, day) {
  const weekday = weekdayOf(day);
  const rows = hours.filter((h) =>
    h.weekday === weekday && h.valid_from <= day &&
    (!h.valid_to || h.valid_to >= day) &&
    (h.court_id === courtId || h.court_id == null)
  );
  rows.sort((a, b) =>
    (Number(b.court_id != null) - Number(a.court_id != null)) ||
    b.valid_from.localeCompare(a.valid_from)
  );
  return rows[0] ?? null;
}

/**
 * buildSlots({ day, courtId, hours, slotMinutes, taken, now, advanceDays })
 *   taken: [{ start: Date, end: Date, kind: "booked" | "closed", label? }]
 * Returns one entry per slot from opening to closing:
 *   { start, end, state: "free" | "booked" | "closed" | "past" | "far", label }
 */
export function buildSlots(
  {
    day,
    courtId,
    hours,
    slotMinutes,
    taken = [],
    now = new Date(),
    advanceDays = 14,
  },
) {
  const window = hoursFor(hours, courtId, day);
  if (!window || !(slotMinutes > 0)) return [];
  const opens = manilaDate(day, window.opens_at);
  const closeText = String(window.closes_at);
  const closes = closeText.startsWith("23:59")
    ? new Date(manilaDate(day, "00:00").getTime() + 24 * 3600_000)
    : manilaDate(day, closeText);
  const farLimit = now.getTime() + advanceDays * 24 * 3600_000;
  const slots = [];
  for (
    let t = opens.getTime();
    t + slotMinutes * 60_000 <= closes.getTime();
    t += slotMinutes * 60_000
  ) {
    const start = new Date(t);
    const end = new Date(t + slotMinutes * 60_000);
    const hit = taken.find((x) => x.start < end && x.end > start);
    let state = "free";
    let label = null;
    if (hit) {
      state = hit.kind === "closed" ? "closed" : "booked";
      label = hit.label ?? null;
    } else if (start.getTime() <= now.getTime()) state = "past";
    else if (start.getTime() > farLimit) state = "far";
    slots.push({ start, end, state, label });
  }
  return slots;
}

/** How many slots in a row, starting at index i, are free (to offer longer bookings). */
export function freeRun(slots, i, max = 4) {
  let n = 0;
  while (i + n < slots.length && n < max && slots[i + n].state === "free") n++;
  return n;
}

/** "8:00 AM" style (12-hour) label for a Date, in Manila time. */
export function timeLabel(date) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "Asia/Manila",
    hour: "numeric",
    minute: "2-digit",
    hour12: true,
  }).formatToParts(date);
  const get = (type) => parts.find((p) => p.type === type)?.value ?? "";
  return `${get("hour")}:${get("minute")} ${get("dayPeriod").toUpperCase()}`;
}
