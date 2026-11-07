// App shell cache only. Bump CACHE on every release so activate removes the old one.
// Only same-origin shell files are cached. Supabase and every other request
// goes straight to the network, so no authenticated data ever reaches the cache.
const CACHE = "cpc-shell-v673";
const LOCAL_DEV = ["localhost", "127.0.0.1"].includes(self.location.hostname);
const SHELL = [
  "./",
  "index.html",
  "icons/digital-id-photo-mask.svg",
  "icons/digital-id-card.png",
  "icons/cpc-logo-holo.png",
  "styles.css",
  "buttons.css",
  "app.js",
  "bootstrap.js",
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
  "pages-events.js",
  "lib/roster-editor.js",
  "event-guests.js",
  "lib/guest-schema.js",
  "pages-events-member.js",
  "event-summary.js",
  "member-self-assessment.js",
  "pages-scoring.js",
  "pages-bracket.js",
  "lib/score-validation.js",
  "pages-ranking.js",
  "pages-my-games.js",
  "pages-digital-id.js",
  "lib/digital-id-export.js",
  "pages-public-bracket.js",
  "lib/bracket-views.js",
  "lib/final-results.js",
  "cpc-points.js",
  "pages-public.js",
  "pages-notifications.js",
  "lib/push.js",
  "lib/notification-feed.js",
  "pages-import.js",
  "pages-staff.js",
  "pages-booking.js",
  "pages-bookings-admin.js",
  "shell.js",
  "shell.css",
  "dev.js",
  "lib/ulid.js",
  "lib/buttons.js",
  "lib/dropdown-position.js",
  "lib/modal-viewport.js",
  "lib/registration-live.js",
  "lib/table-layout.js",
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
  "lib/member-shortcuts.js",
  "lib/member-menu.js",
  "lib/session.js",
  "lib/avatar.js",
  "lib/view-memory.js",
  "lib/tilt.js",
  "lib/pull-refresh.js",
  "lib/startup.js",
  "lib/auth-api.js",
  "lib/password-hints.js",
  "lib/names.js",
  "lib/slot-grid.js",
  "vendor/supabase-js-2.118.0.umd.js",
  "vendor/qrcode-generator-1.4.4.js",
  "vendor/jsqr-1.4.0.js",
  "lib/qr.js",
  "pages-checkin.js",
  "lib/checkin-court-board.js",
  "config.js",
  "supabase-config.js",
  "manifest.webmanifest",
  "fonts/inter-latin-wght-normal.woff2",
  "fonts/bebas-neue/BebasNeue-Regular.ttf",
  "fonts/inter-latin-ext-wght-normal.woff2",
  "icons/cpc-logo-256.webp",
  "icons/cpc-logo-64.png",
  "icons/paddle-480.webp",
  "icons/ball-240.webp",
  "icons/court-pattern.svg",
  "icons/icon-192.png",
  "icons/icon-512.png",
  "icons/icon-maskable-512.png",
];
const SHELL_URLS = new Set(SHELL.map((p) => new URL(p, self.location).href));

self.addEventListener("install", (event) => {
  self.skipWaiting();
  if (LOCAL_DEV) return;
  event.waitUntil(caches.open(CACHE).then((c) =>
    c.addAll(SHELL.map((path) => new Request(new URL(path, self.location), { cache: "no-cache" })))
  ));
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
  if (LOCAL_DEV) return;
  const req = event.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  const isShell = SHELL_URLS.has(url.href) || req.mode === "navigate";
  if (!isShell) return;
  // Network first so releases show up; fall back to the cached shell offline.
  event.respondWith(
    fetch(req, { cache: "no-cache" })
      .then((res) => {
        if (res.ok && SHELL_URLS.has(url.href)) {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put(req, copy));
        }
        return res;
      })
      .catch(async () => {
        const cache = await caches.open(CACHE);
        const hit = await cache.match(req);
        if (hit) return hit;
        if (req.mode === "navigate") {
          const shell = await cache.match("index.html");
          if (shell) return shell;
        }
        return Response.error();
      }),
  );
});

// ---------------------------------------------------------------- push messages (PLAN 9.3)
// A message from the club arrives even when the app is in the background or closed. If the app is open and in view, the page
// already showed it (toast), so no second notification is raised.
self.addEventListener("push", (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch {
    data = {
      title: "Capitol Pickleball Club",
      body: event.data ? event.data.text() : "",
    };
  }
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({
      type: "window",
      includeUncontrolled: true,
    });
    if (windows.some((c) => c.visibilityState === "visible" && c.focused)) {
      return;
    }
    await self.registration.showNotification(
      data.title || "Capitol Pickleball Club",
      {
        body: data.body || "",
        icon: "icons/icon-192.png",
        badge: "icons/icon-192.png",
        tag: data.tag || "cpc",
        renotify: true,
        data: {
          url: typeof data.url === "string" && data.url.startsWith("#/")
            ? data.url
            : "#/",
        },
      },
    );
  })());
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const target =
    new URL(event.notification.data?.url || "#/", self.registration.scope).href;
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({
      type: "window",
      includeUncontrolled: true,
    });
    for (const c of windows) {
      if (c.url.startsWith(self.registration.scope)) {
        await c.focus();
        if ("navigate" in c) {
          try {
            await c.navigate(target);
          } catch {
            // the page keeps its current address
          }
        }
        return;
      }
    }
    await self.clients.openWindow(target);
  })());
});
