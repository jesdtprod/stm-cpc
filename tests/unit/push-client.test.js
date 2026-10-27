import assert from "node:assert/strict";
import {
  enablePush,
  pushState,
  urlBase64ToUint8Array,
} from "../../web/lib/push.js";
import { VAPID_PUBLIC_KEY } from "../../web/supabase-config.js";

async function withDevice(overrides, run) {
  const json = {
    endpoint: "https://push.example.test/device",
    keys: { p256dh: "fake-public-device-key", auth: "fake-auth-key" },
  };
  const sub = { endpoint: json.endpoint, toJSON: () => json };
  const calls = [];
  const reg = {
    active: {},
    pushManager: {
      getSubscription: () => Promise.resolve(null),
      subscribe: () => Promise.resolve(sub),
    },
  };
  const api = {
    rpc: (name, args) => {
      calls.push({ name, args });
      return Promise.resolve(true);
    },
  };
  const globals = {
    navigator: {
      serviceWorker: { getRegistration: () => Promise.resolve(reg) },
      userAgent: "Test browser",
    },
    PushManager: class {},
    Notification: {
      permission: "default",
      requestPermission: () => Promise.resolve("granted"),
    },
    isSecureContext: true,
    ...overrides,
  };
  const previous = Object.fromEntries(
    Object.keys(globals).map((
      key,
    ) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]),
  );
  for (const [key, value] of Object.entries(globals)) {
    Object.defineProperty(globalThis, key, { configurable: true, value });
  }
  try {
    await run({ reg, sub, api, calls });
  } finally {
    for (const [key, descriptor] of Object.entries(previous)) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor);
      else delete globalThis[key];
    }
  }
}

Deno.test("push: public configuration contains a valid P-256 key", async () => {
  await crypto.subtle.importKey(
    "raw",
    urlBase64ToUint8Array(VAPID_PUBLIC_KEY),
    { name: "ECDH", namedCurve: "P-256" },
    false,
    [],
  );
});

Deno.test("push: local preview without a worker cannot offer device alerts", () =>
  withDevice({}, async ({ reg, api, calls }) => {
    reg.active = null;
    assert.deepEqual(await pushState(api), {
      supported: false,
      permission: "default",
      registered: false,
      reason: "not_ready",
    });
    assert.deepEqual(await enablePush(api), { ok: false, reason: "not_ready" });
    navigator.serviceWorker.getRegistration = () => Promise.resolve(undefined);
    assert.equal((await pushState(api)).reason, "not_ready");
    assert.equal((await enablePush(api)).reason, "not_ready");
    assert.equal(calls.length, 0);
  }));

Deno.test("push: a prepared device asks permission synchronously from the click", () =>
  withDevice({}, async ({ api, reg }) => {
    await pushState(api);
    let requested = false;
    Notification.requestPermission = () => {
      requested = true;
      return Promise.resolve("granted");
    };
    navigator.serviceWorker.getRegistration = () => {
      throw new Error("Must use the prepared worker");
    };
    const enabling = enablePush(api);
    assert.equal(
      requested,
      true,
      "No await may precede the permission prompt after preparation",
    );
    assert.deepEqual(await enabling, { ok: true });
    reg.pushManager.subscribe = () =>
      Promise.reject(new DOMException("Blocked", "NotAllowedError"));
    assert.deepEqual(await enablePush(api), { ok: false, reason: "denied" });
  }));

Deno.test("push: insecure contexts cannot enable device alerts", () =>
  withDevice({ isSecureContext: false }, async ({ api }) => {
    assert.equal((await pushState(api)).supported, false);
    assert.deepEqual(await enablePush(api), {
      ok: false,
      reason: "unsupported",
    });
  }));

Deno.test("push: browser permission failures are handled without an uncaught rejection", () =>
  withDevice({
    Notification: {
      permission: "default",
      requestPermission: () => {
        throw new Error("Permission unavailable");
      },
    },
  }, async ({ api, calls }) => {
    assert.deepEqual(await enablePush(api), { ok: false, reason: "denied" });
    assert.equal(calls.length, 0);
  }));

Deno.test("push: enabling reuses the subscription and registers its keys", () =>
  withDevice({}, async ({ reg, sub, api, calls }) => {
    reg.pushManager.getSubscription = () => Promise.resolve(sub);
    reg.pushManager.subscribe = () => {
      throw new Error("Must reuse the existing subscription");
    };
    assert.deepEqual(await enablePush(api), { ok: true });
    assert.equal(calls[0].name, "register_push");
    assert.equal(calls[0].args.p_endpoint, sub.endpoint);
    assert.equal(calls[0].args.p_p256dh, sub.toJSON().keys.p256dh);
    assert.equal(calls[0].args.p_auth, sub.toJSON().keys.auth);
  }));

Deno.test("push: subscription and server failures remain distinguishable", () =>
  withDevice({}, async ({ reg, api }) => {
    reg.pushManager.subscribe = () =>
      Promise.reject(new Error("Push service unavailable"));
    assert.deepEqual(await enablePush(api), {
      ok: false,
      reason: "subscription",
    });
    reg.pushManager.subscribe = () =>
      Promise.resolve({
        toJSON: () => ({
          endpoint: "https://push.example.test/device",
          keys: { p256dh: "fake-key", auth: "fake-auth" },
        }),
      });
    api.rpc = () => Promise.reject({ kind: "session_expired" });
    assert.deepEqual(await enablePush(api), { ok: false, reason: "session" });
    api.rpc = () =>
      Promise.reject({
        code: "22023",
        cause: { message: "too many devices are registered; remove one first" },
      });
    assert.deepEqual(await enablePush(api), {
      ok: false,
      reason: "device_limit",
    });
    api.rpc = () => Promise.reject(new Error("Network failure"));
    assert.deepEqual(await enablePush(api), {
      ok: false,
      reason: "registration",
    });
  }));
