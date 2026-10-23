import {
  componentsPage,
  forbiddenPage,
  homePage,
  notFoundPage,
} from "./pages.js";
import { currentPath, route, routeAccess, start } from "./router.js";
import { h, icon, toast } from "./ui.js";
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
import { changePassword, memberLogin, memberSignup } from "./lib/auth-api.js";
import { renderTurnstile } from "./lib/turnstile.js";

const APP_VERSION = "0.1.0";

// Menu entries use the same access rules as the routes, so each role sees only its own menu.
const NAV = [
  { path: "/", label: "Home", icon: "home" },
  { path: "/components", label: "Components", icon: "grid" },
  { path: "/admin/members", label: "Members", icon: "user" },
];
// Where a user held at a gate is sent (the pages arrive in step 3.4).
const GATE_PAGES = { pending: "#/pending", password_change: "#/password" };

route("/", homePage, "Home", "public");
route("/components", componentsPage, "Components", "public");

const main = document.getElementById("main");
const nav = document.getElementById("nav");
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

const router = start(main, {
  onChange: drawNav,
  notFound: notFoundPage,
  forbidden: forbiddenPage,
  check: (access) => checkAccess(access, GATE_PAGES),
});

function drawNav(path = currentPath()) {
  const visible = NAV.filter((n) =>
    checkAccess(routeAccess(n.path), GATE_PAGES).allow
  );
  const state = session.getState();
  const links = visible.map((n) =>
    h(
      "a",
      { href: `#${n.path}`, "aria-current": n.path === path ? "page" : null },
      icon(n.icon),
      n.label,
    )
  );
  if (state.status === "signed_in") {
    links.push(
      h("span", { class: "nav-user" }, state.access?.member_no ?? ""),
      h("button", {
        class: "nav-action",
        type: "button",
        onClick: () => session.signOut("manual"),
      }, "Sign out"),
    );
  } else {
    links.push(
      h(
        "a",
        {
          href: "#/signin",
          "aria-current": path === "/signin" ? "page" : null,
        },
        icon("check"),
        "Sign in",
      ),
    );
  }
  nav.replaceChildren(...links);
}

// Sign-in or sign-out changes what the user may see: redraw the menu and re-check the page.
onAuthChange(() => {
  drawNav();
  router.refresh();
});

for (const type of ["pointerdown", "keydown", "scroll", "visibilitychange"]) {
  addEventListener(type, () => session.activity(), { passive: true });
}
session.start().catch(() => {}); // restores a saved session when there is one

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
