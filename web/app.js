import { componentsPage, forbiddenPage, notFoundPage } from "./pages.js";
import { currentPath, route, routeAccess, start } from "./router.js";
import { toast } from "./ui.js";
import { createClients } from "./lib/supabase.js";
import { createErrorReporter, installGlobalHandlers } from "./lib/errors.js";
import {
  checkAccess,
  clearAuth,
  onAuthChange,
  setAuth,
} from "./lib/permissions.js";
import { CHANNEL, createSession } from "./lib/session.js";
import { createDev, isLocalDev } from "./dev.js";
import { createAccountPages } from "./pages-account.js";
import { createAdminPages } from "./pages-admin.js";
import { createHomePages } from "./pages-home.js";
import { createShell } from "./shell.js";
import { changePassword, memberLogin, memberSignup } from "./lib/auth-api.js";
import { renderTurnstile } from "./lib/turnstile.js";

const APP_VERSION = "0.1.0";

// Where a user held at a gate is sent (the pages arrive in step 3.4).
const GATE_PAGES = { pending: "#/pending", password_change: "#/password" };

route("/components", componentsPage, "Components", "public");

const main = document.getElementById("main");
document.getElementById("skip").addEventListener("click", () => main.focus());

const { client, api } = createClients();

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

const session = createSession({
  auth: client.auth,
  login,
  idleMs: idleParam > 0 ? idleParam * 1000 : undefined,
  warnMs: idleParam > 0 ? Math.min(10_000, idleParam * 500) : undefined,
  loadAccess: async () => {
    const [grants, me, state] = await Promise.all([
      api.rpc("my_permissions"),
      api.rpc("my_profile"),
      api.rpc("my_access_state"),
    ]);
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
    } else {
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
  authApi: { changePassword, memberSignup },
  renderTurnstile,
  getAccessToken: async () =>
    (await client.auth.getSession()).data.session?.access_token,
});
route("/signin", () => accountPages.signInPage(), "Sign in", "public");
route(
  "/signup",
  () => accountPages.signUpPage(),
  "Create an account",
  "public",
);
route("/password", () => accountPages.passwordPage(), "Password", "gated");
route("/profile", () => accountPages.profilePage(), "Profile", "gated");
route("/pending", () => accountPages.pendingPage(), "Account status", "gated");

const adminPages = createAdminPages({ client, api });
route("/admin/members", () => adminPages.membersPage(), "Members", {
  any: ["members.approve", "members.suspend", "members.read"],
});

const homePages = createHomePages({ session, api });
route("/", () => homePages.homePage(), "Home", "public");

const shell = createShell({
  session,
  checkAccess,
  routeAccess,
  gatePages: GATE_PAGES,
  isDev: isLocalDev,
});

// Restore a saved session before the first page is chosen, so a reload stays on the same page
// instead of being sent to the sign-in page and then home.
// (waits at most 8 seconds, so a slow network cannot keep the page blank)
await Promise.race([
  session.start().catch(() => {}),
  new Promise((resolve) => setTimeout(resolve, 8000)),
]);

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

// Service worker: app shell only. A waiting worker is announced, never applied silently.
if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("./service-worker.js").then((reg) => {
    const announce = (worker) =>
      toast("A new version is ready.", {
        actionLabel: "Reload",
        onAction: () => worker.postMessage({ type: "SKIP_WAITING" }),
      });
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
