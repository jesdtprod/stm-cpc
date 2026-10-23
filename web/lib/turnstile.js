// Cloudflare Turnstile. The script must load from Cloudflare (it cannot be self-hosted or
// given an SRI hash); the CSP allows exactly that origin for scripts and frames.
import { TURNSTILE_SITE_KEY } from "../config.js";

const SRC =
  "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";
let loading = null;

function load() {
  if (globalThis.turnstile) return Promise.resolve(globalThis.turnstile);
  loading ??= new Promise((resolve, reject) => {
    const s = document.createElement("script");
    s.src = SRC;
    s.async = true;
    s.onload = () => resolve(globalThis.turnstile);
    s.onerror = () => {
      loading = null;
      reject(
        new Error(
          "Could not load the security check. Check your connection and try again.",
        ),
      );
    };
    document.head.append(s);
  });
  return loading;
}

/**
 * Renders the widget into `container`.
 * Callbacks: onToken(token), onExpire(), onError(message). The token is single use: send it with
 * the auth request, then call reset() to get a fresh one.
 */
export async function renderTurnstile(
  container,
  { action, onToken, onExpire, onError, siteKey = TURNSTILE_SITE_KEY } = {},
) {
  const t = await load();
  const id = t.render(container, {
    sitekey: siteKey,
    action,
    theme: "dark",
    callback: (token) => onToken?.(token),
    "expired-callback": () => onExpire?.(),
    "error-callback": (code) =>
      onError?.(`The security check failed (${code}). Reload and try again.`),
  });
  return {
    getToken: () => t.getResponse(id) ?? null,
    reset: () => t.reset(id),
    remove: () => t.remove(id),
  };
}
