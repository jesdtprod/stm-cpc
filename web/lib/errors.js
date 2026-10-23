// Global error handling and client_errors reporting (PLAN 1B.5).
// Reports are de-duplicated, rate limited, and stripped of personal data and tokens.
const LIMITS = { message: 2000, stack: 8000, url: 500, userAgent: 300 };

/** Removes emails, tokens, long digit runs and URL query strings or fragments, then truncates. */
export function sanitize(text, max = LIMITS.message) {
  return String(text ?? "")
    .replace(/[\w.+-]+@[\w-]+\.[\w.-]+/g, "[email]")
    .replace(/eyJ[\w-]{10,}\.[\w-]{5,}\.[\w-]*/g, "[token]")
    .replace(/\b[A-Za-z0-9_-]{32,}\b/g, "[token]")
    .replace(/\+?\d[\d\s-]{8,}\d/g, "[number]")
    .replace(
      /([?#])[^\s)'"]*/g,
      (m, c) => (c === "#" && m.startsWith("#/") ? m.split("?")[0] : c),
    )
    .slice(0, max);
}

/** The page route without parameters, e.g. "https://host/app/#/bookings?x=1" -> "https://host/app/#/bookings". */
export function safePageUrl(href) {
  try {
    const u = new URL(href);
    const route = u.hash.split("?")[0];
    return sanitize(`${u.origin}${u.pathname}${route}`, LIMITS.url);
  } catch {
    return null;
  }
}

/**
 * createErrorReporter({ send, getContext, now, maxPerWindow, windowMs })
 *   send(record) -> Promise   writes one row to client_errors (only possible when signed in)
 *   getContext() -> { org_id, profile_id, app_version }
 * report(error) returns "sent" | "duplicate" | "limited" | "skipped" | "failed".
 */
export function createErrorReporter(
  {
    send,
    getContext = () => ({}),
    now = () => Date.now(),
    maxPerWindow = 5,
    windowMs = 60_000,
  },
) {
  const seen = new Set();
  let stamps = [];
  return {
    async report(error, extra = {}) {
      const context = getContext() ?? {};
      if (!context.profile_id) return "skipped"; // client_errors accepts signed-in users only
      const message = sanitize(error?.message ?? error);
      const stack = sanitize(error?.stack ?? "", LIMITS.stack);
      const fingerprint = `${message}|${stack.split("\n")[1] ?? ""}`;
      if (seen.has(fingerprint)) return "duplicate";
      const t = now();
      stamps = stamps.filter((s) => t - s < windowMs);
      if (stamps.length >= maxPerWindow) return "limited";
      seen.add(fingerprint);
      stamps.push(t);
      try {
        await send({
          org_id: context.org_id ?? null,
          profile_id: context.profile_id,
          message: message || "Unknown error",
          stack: stack || null,
          url: safePageUrl(extra.href ?? globalThis.location?.href),
          user_agent: sanitize(
            extra.userAgent ?? globalThis.navigator?.userAgent,
            LIMITS.userAgent,
          ),
          app_version: context.app_version ?? null,
        });
        return "sent";
      } catch {
        return "failed"; // never throw from the error handler
      }
    },
  };
}

/** Wires window "error" and "unhandledrejection" to the reporter and shows one friendly message. */
export function installGlobalHandlers(target, { reporter, notify }) {
  const handle = (error) => {
    reporter.report(error);
    notify(
      "Something went wrong. We've logged it. If it keeps happening, reload the page.",
    );
  };
  target.addEventListener(
    "error",
    (e) => handle(e.error ?? new Error(e.message)),
  );
  target.addEventListener(
    "unhandledrejection",
    (e) => handle(e.reason ?? new Error("Unhandled promise rejection")),
  );
}
