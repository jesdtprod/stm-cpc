// Business dates. The club runs on Asia/Manila (no daylight saving, UTC+8).
// A "business date" is a plain "YYYY-MM-DD" string; it is never built from the browser's own zone.
export const TIME_ZONE = "Asia/Manila";

const dateParts = new Intl.DateTimeFormat("en-CA", {
  timeZone: TIME_ZONE,
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});
const shortDate = new Intl.DateTimeFormat("en-PH", {
  timeZone: TIME_ZONE,
  year: "numeric",
  month: "short",
  day: "numeric",
});
const dateTime = new Intl.DateTimeFormat("en-PH", {
  timeZone: TIME_ZONE,
  year: "numeric",
  month: "short",
  day: "numeric",
  hour: "numeric",
  minute: "2-digit",
  hour12: true,
});

/** The Manila calendar date of an instant, as "YYYY-MM-DD". */
export function businessDate(instant = new Date()) {
  return dateParts.format(new Date(instant));
}

export function isBusinessDate(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    return false;
  }
  const d = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === value;
}

export function addDays(date, days) {
  if (!isBusinessDate(date)) throw new RangeError("invalid business date");
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

export function firstOfMonth(date) {
  if (!isBusinessDate(date)) throw new RangeError("invalid business date");
  return `${date.slice(0, 8)}01`;
}

/**
 * Inclusive business-date range for a preset (UI_DESIGN.md section 7).
 * this_month: first of the month through today. last_30_days: today and the 29 days before.
 * all_time: no restriction (both bounds null).
 */
export function presetRange(preset, now = new Date()) {
  const today = businessDate(now);
  switch (preset) {
    case "this_month":
      return { from: firstOfMonth(today), to: today };
    case "last_30_days":
      return { from: addDays(today, -29), to: today };
    case "all_time":
      return { from: null, to: null };
    default:
      throw new RangeError(`unknown preset ${preset}`);
  }
}

/** Instants bounding a business date: [from, to) in UTC ISO, ready for a database filter. */
export function dayBounds(date) {
  if (!isBusinessDate(date)) throw new RangeError("invalid business date");
  return {
    from: new Date(`${date}T00:00:00+08:00`).toISOString(),
    to: new Date(`${addDays(date, 1)}T00:00:00+08:00`).toISOString(),
  };
}

export function formatDate(instant) {
  return shortDate.format(new Date(instant));
}

export function formatDateTime(instant) {
  return dateTime.format(new Date(instant));
}
