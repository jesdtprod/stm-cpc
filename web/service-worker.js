// App shell cache only. Bump CACHE on every release so activate removes the old one.
// Only same-origin shell files are cached. Supabase and every other request
// goes straight to the network, so no authenticated data ever reaches the cache.
const CACHE = "cpc-shell-v95";
const SHELL = [
  "./",
  "index.html",
  "styles.css",
  "app.js",
  "router.js",
  "ui.js",
  "pages.js",
  "pages-components.js",
  "pages-account.js",
  "pages-admin.js",
  "pages-home.js",
  "pages-settings.js",
  "pages-categories.js",
  "pages-ranks.js",
  "pages-courts.js",
  "pages-import.js",
  "pages-staff.js",
  "pages-booking.js",
  "pages-bookings-admin.js",
  "shell.js",
  "shell.css",
  "dev.js",
  "lib/ulid.js",
  "lib/lucide.js",
  "lib/dates.js",
  "lib/money.js",
  "lib/escape.js",
  "lib/paginate.js",
  "lib/validate.js",
  "lib/turnstile.js",
  "lib/api.js",
  "lib/supabase.js",
  "lib/errors.js",
  "lib/permissions.js",
  "lib/session.js",
  "lib/auth-api.js",
  "lib/password-hints.js",
  "lib/names.js",
  "lib/slot-grid.js",
  "vendor/supabase-js-2.118.0.umd.js",
  "config.js",
  "supabase-config.js",
  "manifest.webmanifest",
  "fonts/inter-latin-wght-normal.woff2",
  "fonts/inter-latin-ext-wght-normal.woff2",
  "icons/cpc-logo.png",
  "icons/paddle.png",
  "icons/ball.png",
  "icons/court-pattern.svg",
  "icons/icon-192.png",
  "icons/icon-512.png",
  "icons/icon-maskable-512.png",
];
const SHELL_URLS = new Set(SHELL.map((p) => new URL(p, self.location).href));

self.addEventListener("install", (event) => {
  self.skipWaiting();
  event.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) =>
        Promise.all(
          keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)),
        )
      )
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("message", (event) => {
  if (event.data?.type === "SKIP_WAITING") self.skipWaiting();
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  const isShell = SHELL_URLS.has(url.href) || req.mode === "navigate";
  if (!isShell) return;
  // Network first so releases show up; fall back to the cached shell offline.
  event.respondWith(
    fetch(req)
      .then((res) => {
        if (res.ok && SHELL_URLS.has(url.href)) {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put(req, copy));
        }
        return res;
      })
      .catch(() =>
        caches.match(req).then((hit) => hit ?? caches.match("index.html"))
      ),
  );
});
