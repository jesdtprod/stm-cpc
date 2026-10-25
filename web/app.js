import {
  bookingPage,
  componentsPage,
  eventsPage,
  forbiddenPage,
  notFoundPage,
} from "./pages.js";
import { currentPath, route, routeAccess, start } from "./router.js";
import { toast } from "./ui.js";
import { createClients } from "./lib/supabase.js";
import { createErrorReporter, installGlobalHandlers } from "./lib/errors.js";
import {
  can,
  checkAccess,
  clearAuth,
  onAuthChange,
  setAuth,
} from "./lib/permissions.js";
import { CHANNEL, createSession } from "./lib/session.js";
import { restoreSession } from "./lib/startup.js";
import { createDev, isLocalDev } from "./dev.js";
import { createAccountPages } from "./pages-account.js";
import { createAdminPages } from "./pages-admin.js";
import { ADMIN_CODES, createHomePages } from "./pages-home.js";
import { createBookingPages } from "./pages-booking.js";
import { createBookingAdminPages } from "./pages-bookings-admin.js";
import { createCategoriesPages } from "./pages-categories.js";
import { createCourtsPages } from "./pages-courts.js";
import { createEventsPages } from "./pages-events.js";
import { createMemberEventsPages } from "./pages-events-member.js";
import { createScoringPages } from "./pages-scoring.js";
import { createBracketPages } from "./pages-bracket.js";
import { createRankingPages } from "./pages-ranking.js";
import { createPublicPages } from "./pages-public.js";
import { createNotificationPages } from "./pages-notifications.js";
import { createNotificationFeed } from "./lib/notification-feed.js";
import { createImportPages } from "./pages-import.js";
import { createRanksPages } from "./pages-ranks.js";
import { createStaffPages } from "./pages-staff.js";
import { createSettingsPages } from "./pages-settings.js";
import { createShell } from "./shell.js";
import {
  adminResetPassword,
  changePassword,
  memberLogin,
  memberSignup,
} from "./lib/auth-api.js";
import { renderTurnstile } from "./lib/turnstile.js";

const APP_VERSION = "0.1.0";

// Where a user held at a gate is sent (the pages arrive in step 3.4).
const GATE_PAGES = {
  pending: "#/pending",
  password_change: "#/password",
  profile_update: "#/profile",
};

route("/components", componentsPage, "Components", "public");

const main = document.getElementById("main");
document.getElementById("skip").addEventListener("click", () => main.focus());

const { client, api } = createClients();

// Live messages for the open page: new notifications raise a toast and the unread count at once.
const notificationFeed = createNotificationFeed({
  client,
  api,
  toast,
  onOpen: (n) => {
    if (n.url) location.hash = n.url;
  },
});

// Sign-in goes through the member-login Edge Function (step 3.1). On localhost the self-check page can also
// sign in with an email address (credentials.email), which is not available anywhere else.
let devTools = null;
const login = (credentials, captchaToken) =>
  credentials.email && devTools
    ? devTools.devLogin(credentials, captchaToken)
    : memberLogin(credentials, captchaToken);
// "?idle=20" shortens the idle timeout to 20 seconds, on localhost only, to test the sign-out.
const idleParam = isLocalDev
  ? Number(new URLSearchParams(location.search).get("idle"))
  : 0;

// The club's idle timeout (setting session.idle_minutes), read after sign-in.
let idleMinutes = null;

const session = createSession({
  auth: client.auth,
  login,
  getIdleMs: () =>
    idleParam > 0
      ? idleParam * 1000
      : idleMinutes
      ? idleMinutes * 60_000
      : null,
  idleMs: idleParam > 0 ? idleParam * 1000 : undefined,
  warnMs: idleParam > 0 ? Math.min(10_000, idleParam * 500) : undefined,
  loadAccess: async () => {
    const [grants, me, state, idle] = await Promise.all([
      api.rpc("my_permissions"),
      api.rpc("my_profile"),
      api.rpc("my_access_state"),
      api.read((c) =>
        c.from("settings").select("value").eq("key", "session.idle_minutes")
          .is("unit_id", null).is("deleted_at", null).maybeSingle()
      ).catch(() => null),
    ]);
    idleMinutes = Number(idle?.value) > 0 ? Number(idle.value) : null;
    return { grants, profile: me?.[0] ?? null, access: state?.[0] ?? null };
  },
  channel: "BroadcastChannel" in globalThis
    ? new BroadcastChannel(CHANNEL)
    : null,
  storage: globalThis.localStorage,
  cacheStorage: globalThis.caches ?? null,
  onChange: (s) => {
    dispatchEvent(new CustomEvent("cpc:session", { detail: s }));
    if (s.status === "signed_in") {
      setAuth({ signedIn: true, grants: s.grants, gate: s.gate });
      if (s.gate) notificationFeed.stop();
      else notificationFeed.start();
    } else {
      notificationFeed.stop();
      clearAuth();
      if (s.reason === "idle") {
        toast("You were signed out because of inactivity.");
      }
    }
  },
  onIdleWarning: (seconds) =>
    toast(
      `You will be signed out in ${seconds} seconds unless you keep working.`,
    ),
});

const reporter = createErrorReporter({
  getContext: () => ({
    ...(session.getState().profile ?? {}),
    app_version: APP_VERSION,
  }),
  send: (record) =>
    api.read((c) => c.from("client_errors").insert(record), { retries: 0 }),
});
installGlobalHandlers(globalThis, {
  reporter,
  notify: (message) => toast(message),
});

if (isLocalDev) {
  devTools = createDev({ client, api, session, reporter });
  route("/dev", () => devTools.page(), "Self-check", "public");
}

const accountPages = createAccountPages({
  session,
  api,
  client,
  authApi: { changePassword, memberSignup },
  renderTurnstile,
  getAccessToken: async () =>
    (await client.auth.getSession()).data.session?.access_token,
});
route("/signin", () => accountPages.signInPage(), "Sign In", "public");
route(
  "/signup",
  () => accountPages.signUpPage(),
  "Create an Account",
  "public",
);
route("/password", () => accountPages.passwordPage(), "Password", "gated");
route("/profile", () => accountPages.profilePage(), "Profile", "gated");
route("/pending", () => accountPages.pendingPage(), "Account Status", "gated");

const adminPages = createAdminPages({ client, api, adminResetPassword });
route("/admin/members", () => adminPages.membersPage(), "Members", {
  any: ["members.approve", "members.suspend", "members.read"],
});

const settingsPages = createSettingsPages({ api });
route("/admin/settings", () => settingsPages.settingsPage(), "Settings", {
  permission: "settings.manage",
});

const categoriesPages = createCategoriesPages({
  api,
  getOrgId: () => session.getState().profile?.org_id,
});
route(
  "/admin/categories",
  () => categoriesPages.categoriesPage(),
  "Categories",
  {
    permission: "categories.manage",
  },
);

const ranksPages = createRanksPages({
  api,
  getOrgId: () => session.getState().profile?.org_id,
});
route("/admin/ranks", () => ranksPages.ranksPage(), "Ranks", {
  permission: "ranks.manage",
});

const courtsPages = createCourtsPages({
  api,
  getOrgId: () => session.getState().profile?.org_id,
});
route("/admin/courts", () => courtsPages.courtsPage(), "Courts", {
  permission: "courts.manage",
});

const eventsPages = createEventsPages({ api });
route("/admin/events", () => eventsPages.eventsPage(), "Events", {
  permission: "events.manage",
});

const memberEventsPages = createMemberEventsPages({ api, client, session });

const notificationPages = createNotificationPages({
  api,
  feed: notificationFeed,
});
route(
  "/notifications",
  () => notificationPages.notificationsPage(),
  "Notifications",
  "signedIn",
);

const publicPages = createPublicPages({ api });
route(
  "/leaderboard",
  () => publicPages.leaderboardPage(),
  "Leaderboard",
  "public",
);

const rankingPages = createRankingPages({ api });
route("/ranking", () => rankingPages.rankingPage(), "Ranking", "signedIn");

const bracketPages = createBracketPages({ api });
route("/bracket", () => bracketPages.bracketPage(), "Bracket", "signedIn");

const scoringPages = createScoringPages({
  api,
  getOrgId: () => session.getState().profile?.org_id,
});
route("/admin/scoring", () => scoringPages.scoringPage(), "Scoring Rules", {
  permission: "events.manage",
});

const importPages = createImportPages({ api });
route("/admin/import", () => importPages.importPage(), "Member Import", {
  any: ["members.import", "members.review_import"],
});

const staffPages = createStaffPages({ api });
route("/admin/staff", () => staffPages.staffPage(), "Staff and Roles", {
  permission: "roles.manage",
});

const bookingPages = createBookingPages({ api, client, session });
route("/book", () => bookingPages.bookPage(), "Book a Court", {
  permission: "bookings.create",
});
route("/bookings", () => bookingPages.myBookingsPage(), "My Bookings", {
  permission: "bookings.create",
});
const bookingAdminPages = createBookingAdminPages({ api, client });
route("/admin/bookings", () => bookingAdminPages.bookingsPage(), "Bookings", {
  any: ["bookings.approve", "bookings.read_all", "bookings.checkin"],
});
route("/admin/payments", () => bookingAdminPages.paymentsPage(), "Payments", {
  any: ["payments.verify", "payments.void"],
});

const homePages = createHomePages({ session, api, client });
route("/", () => homePages.homePage(), "Home", "public");
route("/admin", () => homePages.adminHomePage(), "Admin Dashboard", {
  any: ADMIN_CODES,
});
route("/booking", () => bookingPage(), "Court Booking", "public");
// Members who may register see the registration page; everyone else sees the public placeholder.
route(
  "/events",
  () => can("events.register") ? memberEventsPages.eventsPage() : eventsPage(),
  "Events",
  "public",
);

const shell = createShell({
  session,
  checkAccess,
  routeAccess,
  gatePages: GATE_PAGES,
});

// Restore a saved session before the first page is chosen, so a reload stays on the same page
// instead of being sent to the sign-in page and then home.
// Startup failures are shown by bootstrap.js, without treating a saved session as signed out.
await restoreSession(() => session.start());

// the side menu shows the unread count as it changes
addEventListener("cpc:unread", () => shell.draw(currentPath()));

const router = start(main, {
  onChange: (path) => shell.draw(path),
  notFound: notFoundPage,
  forbidden: forbiddenPage,
  check: (access) => checkAccess(access, GATE_PAGES),
});

// Sign-in or sign-out changes what the user may see: redraw the menu and re-check the page.
onAuthChange(() => {
  shell.draw(currentPath());
  router.refresh();
});

for (const type of ["pointerdown", "keydown", "scroll", "visibilitychange"]) {
  addEventListener(type, () => session.activity(), { passive: true });
}

// Service worker: app shell only. On local development, unregister and clear caches to prevent stale bundles.
if ("serviceWorker" in navigator) {
  if (isLocalDev) {
    navigator.serviceWorker.getRegistrations().then((regs) => {
      for (const r of regs) r.unregister();
    });
    if (globalThis.caches) {
      caches.keys().then((keys) =>
        Promise.all(keys.map((k) => caches.delete(k)))
      );
    }
  } else {
    navigator.serviceWorker.register("./service-worker.js").then((reg) => {
      const announce = () => {};
      if (reg.waiting && navigator.serviceWorker.controller) {
        announce(reg.waiting);
      }
      reg.addEventListener("updatefound", () => {
        const worker = reg.installing;
        worker?.addEventListener("statechange", () => {
          if (
            worker.state === "installed" && navigator.serviceWorker.controller
          ) announce(worker);
        });
      });
    });
    let reloading = false;
    navigator.serviceWorker.addEventListener("controllerchange", () => {
      if (reloading) return;
      reloading = true;
      location.reload();
    });
  }
}
