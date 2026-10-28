import assert from "node:assert/strict";
import { watchRegistrationChanges } from "../../web/lib/registration-live.js";

const tick = () => new Promise((resolve) => setTimeout(resolve, 350));
function fixture(refresh) {
  const handlers = new Map();
  let status;
  let removed = 0;
  const page = { isConnected: true };
  const channel = {
    on(type, filter, callback) { handlers.set(filter.table, callback); return this; },
    subscribe(callback) { status = callback; return this; },
  };
  const stop = watchRegistrationChanges({
    client: { channel: () => channel, removeChannel: () => { removed += 1; } }, page, refresh,
  });
  return { handlers, status: (value) => status(value), page, stop, removed: () => removed };
}

Deno.test("registration live: registration bursts, cancellation and reconnect refresh the screen", async () => {
  let refreshes = 0;
  const f = fixture(() => { refreshes += 1; });
  try {
    for (const state of ["requested", "confirmed", "withdrawn"]) f.handlers.get("registrations")({ new: { status: state } });
    await tick();
    assert.equal(refreshes, 1, "Coalesces related registration changes");
    f.handlers.get("events")({ new: { status: "cancelled" } });
    f.handlers.get("divisions")({ new: { status: "cancelled" } });
    await tick();
    assert.equal(refreshes, 2, "Event and division cancellation update controls too");
    f.status("SUBSCRIBED");
    await tick();
    assert.equal(refreshes, 3, "Reconnect catches missed changes");
    f.page.isConnected = false;
    f.handlers.get("registrations")({});
    assert.equal(f.removed(), 1, "Detached screen releases its subscription");
  } finally { f.stop(); }
});

Deno.test("registration live: in-flight refresh queues one follow-up and stop cancels work", async () => {
  let refreshes = 0;
  let release;
  const pending = new Promise((resolve) => { release = resolve; });
  const f = fixture(async () => { refreshes += 1; if (refreshes === 1) await pending; });
  try {
    f.handlers.get("registrations")({});
    await tick();
    f.handlers.get("registrations")({});
    await tick();
    assert.equal(refreshes, 1, "Never overlaps refreshes");
    release();
    await tick();
    assert.equal(refreshes, 2, "Changes during a request receive a follow-up refresh");
    f.handlers.get("registrations")({});
    f.stop();
    await tick();
    assert.equal(refreshes, 2, "Stop cancels pending refresh");
    assert.equal(f.removed(), 1, "Stop is idempotent");
  } finally { release(); f.stop(); }
});
