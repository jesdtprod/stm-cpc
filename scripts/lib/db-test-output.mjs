// Supabase CLI versions return either rows directly or a { rows } object.
export function parseDbTestOutput(output) {
  const result = JSON.parse(output);
  const rows = Array.isArray(result) ? result : result?.rows;
  if (!Array.isArray(rows) || rows.length === 0) {
    throw new Error("No database test results returned");
  }
  return rows.map((row) => {
    if (
      typeof row?.line !== "string" || !/^(?:not )?ok\s+\d+\b/.test(row.line)
    ) {
      throw new Error("Invalid database test result");
    }
    return row.line;
  });
}
