// Money is shown with Intl and calculated in integer centavos. Prices and totals always come
// from the server; these helpers only format and parse what the user sees or types.
const PHP = new Intl.NumberFormat("en-PH", {
  style: "currency",
  currency: "PHP",
});

/** Format a decimal amount (number or numeric string such as "1250.50") as ₱1,250.50. */
export function formatMoney(amount) {
  const n = typeof amount === "string" ? Number(amount) : amount;
  if (!Number.isFinite(n)) throw new RangeError("not a money amount");
  return PHP.format(n);
}

/** Parse user input like "₱1,250.5" into integer centavos, or null when it is not a valid amount. */
export function parseCentavos(text) {
  if (typeof text !== "string") return null;
  const cleaned = text.replace(/[₱,\s]/g, "");
  const m = /^(\d+)(?:\.(\d{1,2}))?$/.exec(cleaned);
  if (!m) return null;
  const centavos = Number(m[1]) * 100 +
    Number((m[2] ?? "").padEnd(2, "0") || 0);
  return Number.isSafeInteger(centavos) ? centavos : null;
}

/** Integer centavos to a fixed two-decimal string ("125050" -> "1250.50"), for sending to the server. */
export function centavosToDecimal(centavos) {
  if (!Number.isSafeInteger(centavos) || centavos < 0) {
    throw new RangeError("invalid centavos");
  }
  return `${Math.floor(centavos / 100)}.${
    String(centavos % 100).padStart(2, "0")
  }`;
}
