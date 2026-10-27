import assert from "node:assert/strict";

const source = await Deno.readTextFile(
  new URL("../../web/service-worker.js", import.meta.url),
);

function workerAt(origin) {
  const events = new Map();
  const cached = [];
  const worker = {
    location: new URL("service-worker.js", origin),
    addEventListener: (name, handler) => events.set(name, handler),
    skipWaiting() {},
  };
  const cache = {
    open: () =>
      Promise.resolve({
        addAll: (files) => {
          cached.push(...files);
        },
      }),
  };
  new Function("self", "caches", source)(worker, cache);
  return { events, cached };
}

Deno.test("local push worker: localhost and loopback keep push handlers without caching app files", () => {
  for (const origin of ["http://localhost:8099/", "http://127.0.0.1:8099/"]) {
    const { events, cached } = workerAt(origin);
    assert(events.has("push"));
    assert(events.has("notificationclick"));
    events.get("install")({
      waitUntil: () =>
        assert.fail("Local installation must not cache the shell"),
    });
    events.get("fetch")({
      respondWith: () =>
        assert.fail("Local files must go straight to the dev server"),
    });
    assert.equal(cached.length, 0);
  }
});

Deno.test("published push worker: app shell still gets cached for offline access", async () => {
  const { events, cached } = workerAt("https://example.test/cpc/");
  let installing;
  events.get("install")({
    waitUntil: (promise) => {
      installing = promise;
    },
  });
  await installing;
  assert(cached.includes("index.html"));
  assert(cached.includes("lib/push.js"));
  assert(events.has("push"));
});
