import assert from "node:assert/strict";
import { parseDbTestOutput } from "../../scripts/lib/db-test-output.mjs";

Deno.test("database test output: supports both CLI result shapes", () => {
  const rows = [{ line: "ok 1 - guest created" }, {
    line: "ok 2 - retry replays",
  }];
  for (const result of [rows, { rows }]) {
    assert.deepEqual(
      parseDbTestOutput(JSON.stringify(result)),
      rows.map((r) => r.line),
    );
  }
});

Deno.test("database test output: preserves failing assertions and diagnostics", () => {
  const line = "not ok 2 - duplicate refused\n# Failed test";
  assert.deepEqual(parseDbTestOutput(JSON.stringify([{ line }])), [line]);
});

Deno.test("database test output: rejects missing, empty, and malformed results", () => {
  for (
    const output of [
      "not JSON",
      "null",
      "{}",
      "[]",
      '{"rows":[]}',
      "[{}]",
      '[{"line":null}]',
      '[{"line":"unexpected output"}]',
      '[{"line":"ok 1 - valid"},{}]',
    ]
  ) {
    assert.throws(() => parseDbTestOutput(output));
  }
});
