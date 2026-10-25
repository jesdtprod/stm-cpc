import assert from "node:assert/strict";
import {
  handle,
  sameSecret,
} from "../../supabase/functions/push-send/handler.ts";

const ID = "01M5KVH64YWRD8G5STB90V74T7";
const SECRET = "shared-secret-for-tests";

function world(over = {}) {
  const s = { sent: [], marked: null, logs: [] };
  const deps = {
    secret: over.secret ?? SECRET,
    load: () =>
      Promise.resolve(
        over.target === undefined
          ? {
            title: "Your booking is confirmed",
            body: "Court 1 · Mon Nov 2, 10:00 AM",
            url: "#/bookings",
            tag: "booking.confirmed",
            subs: [
              {
                id: "s1",
                endpoint: "https://push.example/a",
                p256dh: "k1",
                auth: "a1",
              },
              {
                id: "s2",
                endpoint: "https://push.example/b",
                p256dh: "k2",
                auth: "a2",
              },
              {
                id: "s3",
                endpoint: "https://push.example/c",
                p256dh: "k3",
                auth: "a3",
              },
            ],
          }
          : over.target,
      ),
    send: (sub, payload) => {
      s.sent.push({ endpoint: sub.endpoint, payload });
      return Promise.resolve(over.results?.[sub.id] ?? "ok");
    },
    mark: (ok, gone) => {
      s.marked = { ok, gone };
      return Promise.resolve();
    },
    log: (e, f) => s.logs.push([e, f]),
  };
  return { deps, s };
}
const call = (body, { secret = SECRET, method = "POST" } = {}) =>
  new Request("https://f.example/push-send", {
    method,
    headers: secret === null ? {} : { "x-dispatch-secret": secret },
    body: method === "POST" ? JSON.stringify(body) : undefined,
  });

Deno.test("push: a notification goes to every registered device with only title, text and address", async () => {
  const { deps, s } = world();
  const res = await handle(call({ notification_id: ID }), deps);
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { ok: true, sent: 3, gone: 0, failed: 0 });
  assert.equal(s.sent.length, 3);
  const payload = JSON.parse(s.sent[0].payload);
  assert.deepEqual(Object.keys(payload).sort(), [
    "body",
    "tag",
    "title",
    "url",
  ]);
  assert.equal(payload.url, "#/bookings");
  assert.deepEqual(s.marked, { ok: ["s1", "s2", "s3"], gone: [] });
});

Deno.test("push: a device the push service says is gone is reported, a failure is counted, and neither stops the rest", async () => {
  const { deps, s } = world({ results: { s2: "gone", s3: "error" } });
  const res = await handle(call({ notification_id: ID }), deps);
  assert.deepEqual(await res.json(), { ok: true, sent: 1, gone: 1, failed: 1 });
  assert.deepEqual(s.marked, { ok: ["s1"], gone: ["s2"] });
  assert.equal(
    JSON.stringify(s.logs).includes("push.example"),
    false,
    "logs hold counts only",
  );
});

Deno.test("push: without the shared secret nothing is read or sent", async () => {
  for (const secret of [null, "", "wrong", SECRET + "x"]) {
    const { deps, s } = world();
    const res = await handle(call({ notification_id: ID }, { secret }), deps);
    assert.equal(res.status, 401);
    assert.equal(s.sent.length, 0);
  }
  const { deps } = world({ secret: "" });
  assert.equal(
    (await handle(call({ notification_id: ID }), deps)).status,
    503,
    "an unset secret closes the function",
  );
});

Deno.test("push: method, body and id are checked", async () => {
  const { deps } = world();
  assert.equal((await handle(call(null, { method: "GET" }), deps)).status, 405);
  assert.equal(
    (await handle(call({ notification_id: "not-an-id" }), deps)).status,
    400,
  );
  assert.equal((await handle(call({}), deps)).status, 400);
  assert.equal(
    (await handle(
      new Request("https://f.example/p", {
        method: "POST",
        headers: { "x-dispatch-secret": SECRET },
        body: "{oops",
      }),
      deps,
    )).status,
    400,
  );
  assert.equal(
    (await handle(call({ notification_id: ID, pad: "x".repeat(600) }), deps))
      .status,
    413,
  );
});

Deno.test("push: an unknown notification, or a member with no devices, sends nothing", async () => {
  const none = world({ target: null });
  assert.equal(
    (await handle(call({ notification_id: ID }), none.deps)).status,
    404,
  );
  const empty = world({
    target: { title: "t", body: null, url: null, tag: null, subs: [] },
  });
  const res = await handle(call({ notification_id: ID }), empty.deps);
  assert.deepEqual(await res.json(), { ok: true, sent: 0, gone: 0, failed: 0 });
  assert.equal(empty.s.sent.length, 0);
});

Deno.test("push: the secret comparison does not stop at the first difference", () => {
  assert.equal(sameSecret("abc", "abc"), true);
  assert.equal(sameSecret("abc", "abd"), false);
  assert.equal(sameSecret("abc", "abcd"), false);
  assert.equal(sameSecret("", ""), true);
});
