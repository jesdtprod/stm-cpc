import assert from "node:assert/strict";
import { createScanGate } from "../../web/lib/qr.js";

Deno.test("QR scan gate: a held code cannot restart verification behind a refusal toast", () => {
  const accept = createScanGate();
  assert.equal(accept("FAKE-QR-A", 0), true);
  assert.equal(accept("FAKE-QR-A", 6000), false);
  assert.equal(accept(null, 6500), false);
  assert.equal(accept("FAKE-QR-A", 6600), false);
  assert.equal(accept(null, 8000), false);
  assert.equal(accept("FAKE-QR-A", 8100), true);
});

Deno.test("QR scan gate: the next member's QR is accepted immediately", () => {
  const accept = createScanGate();
  assert.equal(accept("FAKE-QR-A", 0), true);
  assert.equal(accept("FAKE-QR-B", 100), true);
  assert.equal(accept("FAKE-QR-B", 9000), false);
});
