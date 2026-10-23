// Keyset pagination (DATABASE.md section 4): newest first by ULID, no offsets.
// Query shape:  .order("id", { ascending: false }).limit(pageSize + 1)  [+ .lt("id", cursor)]
export const MAX_PAGE_SIZE = 100;

export function clampPageSize(n, fallback = 20) {
  if (!Number.isInteger(n) || n < 1) return fallback;
  return Math.min(n, MAX_PAGE_SIZE);
}

/** Number of rows to request: one extra row tells us whether another page exists. */
export function fetchLimit(pageSize) {
  return clampPageSize(pageSize) + 1;
}

/** Splits the rows returned for fetchLimit() into the page and the cursor for the next one. */
export function pageFromRows(rows, pageSize) {
  const size = clampPageSize(pageSize);
  const items = rows.slice(0, size);
  const hasMore = rows.length > size;
  return {
    items,
    hasMore,
    nextCursor: hasMore ? items[items.length - 1].id : null,
  };
}
