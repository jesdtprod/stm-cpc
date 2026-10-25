// Web Push for this device (PLAN 9.3): lets the club reach a member even when the app is in the background or closed.
//   * enablePush asks the browser's permission, subscribes this device with the club's public key and registers it with
//     register_push. The device keys go to the server only; they are never read back.
//   * The service worker (service-worker.js) shows the message and opens the right page when it is tapped.
//   * It needs the installed or deployed (https) app and a service worker; on a local test server it reports "unsupported".
import { VAPID_PUBLIC_KEY } from "../supabase-config.js";

export const pushSupported = () =>
  typeof navigator !== "undefined" && "serviceWorker" in navigator &&
  typeof globalThis.PushManager !== "undefined" &&
  typeof globalThis.Notification !== "undefined";

export function urlBase64ToUint8Array(base64) {
  const padding = "=".repeat((4 - (base64.length % 4)) % 4);
  const raw = atob((base64 + padding).replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from(raw, (c) => c.charCodeAt(0));
}

async function registration() {
  // Not "ready": that waits forever when no service worker is registered (a local test server).
  return await navigator.serviceWorker.getRegistration() ?? null;
}

/** { supported, permission, registered } for this device. */
export async function pushState(api) {
  if (!pushSupported()) {
    return { supported: false, permission: "unsupported", registered: false };
  }
  const permission = Notification.permission;
  const reg = await registration();
  const sub = reg ? await reg.pushManager.getSubscription() : null;
  let registered = false;
  if (sub && permission === "granted") {
    try {
      registered = Boolean(
        await api.rpc("my_push_registered", { p_endpoint: sub.endpoint }),
      );
    } catch {
      registered = false;
    }
  }
  return { supported: true, permission, registered };
}

/** Resolves { ok: true } or { ok: false, reason } where reason is "denied", "unsupported" or "failed". */
export async function enablePush(api) {
  if (!pushSupported()) return { ok: false, reason: "unsupported" };
  const reg = await registration();
  if (!reg) return { ok: false, reason: "unsupported" };
  const permission = await Notification.requestPermission();
  if (permission !== "granted") return { ok: false, reason: "denied" };
  try {
    const sub = await reg.pushManager.getSubscription() ??
      await reg.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: urlBase64ToUint8Array(VAPID_PUBLIC_KEY),
      });
    const json = sub.toJSON();
    await api.rpc("register_push", {
      p_endpoint: json.endpoint,
      p_p256dh: json.keys.p256dh,
      p_auth: json.keys.auth,
      p_user_agent: navigator.userAgent.slice(0, 300),
    });
    return { ok: true };
  } catch {
    return { ok: false, reason: "failed" };
  }
}

export async function disablePush(api) {
  const reg = pushSupported() ? await registration() : null;
  const sub = reg ? await reg.pushManager.getSubscription() : null;
  if (!sub) return;
  try {
    await api.rpc("unregister_push", { p_endpoint: sub.endpoint });
  } finally {
    await sub.unsubscribe();
  }
}
