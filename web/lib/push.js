// Web Push for this device (PLAN 9.3): lets the club reach a member even when the app is in the background or closed.
//   * enablePush asks the browser's permission, subscribes this device with the club's public key and registers it with
//     register_push. The device keys go to the server only; they are never read back.
//   * The service worker (service-worker.js) shows the message and opens the right page when it is tapped.
//   * It needs a secure origin (HTTPS or localhost) and an active service worker.
import { VAPID_PUBLIC_KEY } from "../supabase-config.js";

const readyRegistrations = new WeakMap();

export const pushSupported = () =>
  globalThis.isSecureContext !== false &&
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
  const workers = navigator.serviceWorker;
  const reg = await workers.getRegistration() ?? null;
  if (reg?.active && reg.pushManager) readyRegistrations.set(workers, reg);
  else readyRegistrations.delete(workers);
  return reg;
}

/** { supported, permission, registered } for this device. */
export async function pushState(api) {
  if (!pushSupported()) {
    return { supported: false, permission: "unsupported", registered: false };
  }
  const permission = Notification.permission;
  const reg = await registration();
  if (!reg?.active || !reg.pushManager) {
    return {
      supported: false,
      permission,
      registered: false,
      reason: "not_ready",
    };
  }
  const sub = await reg.pushManager.getSubscription();
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

/** Resolve a safe, actionable failure without exposing device keys or endpoints. */
export async function enablePush(api) {
  if (!pushSupported()) return { ok: false, reason: "unsupported" };
  let stage = "not_ready";
  try {
    // pushState prepares this before the button is shown. Avoid an asynchronous
    // worker lookup here so permission is requested directly from the click.
    const reg = readyRegistrations.get(navigator.serviceWorker) ??
      await registration();
    if (!reg?.active || !reg.pushManager) {
      return { ok: false, reason: "not_ready" };
    }
    stage = "denied";
    const permission = Notification.permission === "granted"
      ? "granted"
      : await Notification.requestPermission();
    if (permission !== "granted") return { ok: false, reason: "denied" };
    stage = "subscription";
    const sub = await reg.pushManager.getSubscription() ??
      await reg.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: urlBase64ToUint8Array(VAPID_PUBLIC_KEY),
      });
    const json = sub.toJSON();
    stage = "registration";
    await api.rpc("register_push", {
      p_endpoint: json.endpoint,
      p_p256dh: json.keys.p256dh,
      p_auth: json.keys.auth,
      p_user_agent: navigator.userAgent.slice(0, 300),
    });
    return { ok: true };
  } catch (error) {
    if (stage !== "registration" && error.name === "NotAllowedError") {
      return { ok: false, reason: "denied" };
    }
    if (stage === "registration") {
      if (error.kind === "session_expired" || error.kind === "forbidden") {
        return { ok: false, reason: "session" };
      }
      if (
        error.code === "22023" &&
        /too many devices/i.test(error.cause?.message ?? "")
      ) {
        return { ok: false, reason: "device_limit" };
      }
    }
    return { ok: false, reason: stage };
  }
}

export const PUSH_MESSAGES = {
  unsupported:
    "This browser cannot receive device alerts. On an iPhone, add the app to your Home Screen and open it from there.",
  not_ready:
    "Device alerts are still getting ready. Reload the page, then try again.",
  denied:
    "Alerts were not allowed. Allow notifications in your browser's site settings, then try again.",
  subscription:
    "The browser could not connect to its notification service. Check your connection and notification settings. In Brave, turn on “Use Google Services for Push Messaging” in Settings > Privacy and security, then restart Brave and try again.",
  registration:
    "This device could not be registered with the club. Check your connection and try again.",
  session: "Sign in again, then turn on alerts for this device.",
  device_limit:
    "Ten devices are already registered. Turn off alerts on another device, then try again.",
};

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
