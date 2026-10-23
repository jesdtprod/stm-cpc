// Escaping and URL safety. The UI builds DOM with textContent (see ui.js); use these when text
// must go into a string that becomes HTML (for example the PDF and print views).
const MAP = {
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&#39;",
  "`": "&#96;",
};

export function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"'`]/g, (c) => MAP[c]);
}

/** Returns the URL when it is https:, mailto: or tel:, otherwise null. Never allows javascript: or data:. */
export function safeUrl(value) {
  try {
    const u = new URL(String(value));
    return ["https:", "mailto:", "tel:"].includes(u.protocol) ? u.href : null;
  } catch {
    return null;
  }
}

/** Only same-app hash routes may be used as a redirect target after sign-in. */
export function safeRoute(value, fallback = "#/") {
  return typeof value === "string" && /^#\/[A-Za-z0-9/_-]*$/.test(value)
    ? value
    : fallback;
}
