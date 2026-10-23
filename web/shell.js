// The app shell (PLAN 3.6): header with the account menu, and the side panel built from the
// user's permissions. The menu is a convenience only; every page and every call is checked again
// by the router and the database.
import { h, icon } from "./ui.js";

// Each entry uses the access rule of its own route, so a user sees exactly the pages they can open.
// `gated: true` entries stay visible while a user is held at a gate (password change, waiting for approval).
const GROUPS = [
  {
    label: "Overview",
    items: [{ path: "/", label: "Home", icon: "home", gated: true }],
  },
  {
    label: "Club",
    items: [
      { path: "/admin/members", label: "Members", icon: "user" },
      {
        path: "/admin/categories",
        label: "Categories",
        icon: "layers",
      },
      { path: "/admin/ranks", label: "Ranks", icon: "layers" },
      { path: "/admin/courts", label: "Courts", icon: "grid" },
      { path: "/admin/settings", label: "Settings", icon: "filter" },
    ],
  },
  {
    label: "Account",
    items: [
      { path: "/profile", label: "My profile", icon: "user", gated: true },
      {
        path: "/password",
        label: "Change password",
        icon: "edit",
        gated: true,
      },
      {
        path: "/pending",
        label: "Account status",
        icon: "clock",
        gated: true,
        onlyGate: "pending",
      },
    ],
  },
  {
    label: "Developer",
    dev: true,
    items: [
      { path: "/components", label: "Components", icon: "grid" },
      { path: "/dev", label: "Self-check", icon: "check" },
    ],
  },
];

const initials = (name) =>
  String(name ?? "").split(/\s+/).filter(Boolean).slice(0, 2)
    .map((w) => w[0]).join("").toUpperCase() || "?";

/**
 * createShell({ session, checkAccess, routeAccess, gatePages, isDev })
 * Needs these elements in index.html: #menu-btn, #side, #nav, #scrim, #account.
 * Returns { draw(path) }: call it on every route change and every sign-in or sign-out.
 */
export function createShell(
  { session, checkAccess, routeAccess, gatePages, isDev = false },
) {
  const el = (id) => document.getElementById(id);
  const menuBtn = el("menu-btn");
  const side = el("side");
  const nav = el("nav");
  const scrim = el("scrim");
  const account = el("account");

  // ---- mobile drawer
  function setDrawer(open) {
    side.toggleAttribute("data-open", open);
    scrim.hidden = !open;
    menuBtn.setAttribute("aria-expanded", String(open));
    menuBtn.setAttribute("aria-label", open ? "Close menu" : "Open menu");
    if (open) side.querySelector("a")?.focus();
    else if (side.contains(document.activeElement)) menuBtn.focus();
  }
  menuBtn.addEventListener(
    "click",
    () => setDrawer(!side.hasAttribute("data-open")),
  );
  scrim.addEventListener("click", () => setDrawer(false));
  side.addEventListener("click", (e) => {
    if (e.target.closest("a")) setDrawer(false);
  });
  // Back on a wide screen the drawer state no longer applies.
  matchMedia("(min-width: 901px)").addEventListener("change", (e) => {
    if (e.matches) setDrawer(false);
  });

  // ---- account menu
  let menuOpen = false;
  let toggle = null;
  let panel = null;
  function setMenu(open, { restoreFocus = false } = {}) {
    menuOpen = open;
    if (!toggle || !panel) return;
    panel.hidden = !open;
    toggle.setAttribute("aria-expanded", String(open));
    if (open) panel.querySelector("a, button")?.focus();
    else if (restoreFocus) toggle.focus();
  }
  document.addEventListener("click", (e) => {
    if (menuOpen && !account.contains(e.target)) setMenu(false);
  });
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    if (menuOpen) setMenu(false, { restoreFocus: true });
    else if (side.hasAttribute("data-open")) setDrawer(false);
  });

  function drawAccount(state) {
    menuOpen = false;
    if (state.status !== "signed_in") {
      toggle = panel = null;
      account.replaceChildren(
        h("a", { class: "btn btn-secondary", href: "#/signin" }, "Sign in"),
        h("a", { class: "btn btn-primary", href: "#/signup" }, "Join the club"),
      );
      return;
    }
    const name = state.access?.display_name || "My account";
    const memberNo = state.access?.member_no ?? "";
    toggle = h(
      "button",
      {
        class: "account-btn",
        type: "button",
        "aria-label": `Account menu, ${name}`,
        "aria-haspopup": "menu",
        "aria-expanded": "false",
        "aria-controls": "account-menu",
        onClick: () => setMenu(!menuOpen),
      },
      h(
        "span",
        { class: "account-avatar", "aria-hidden": "true" },
        initials(name),
      ),
      h(
        "span",
        { class: "account-text" },
        h("span", { class: "account-name" }, name),
        memberNo ? h("span", { class: "account-no" }, memberNo) : null,
      ),
    );
    panel = h(
      "div",
      { class: "account-menu", id: "account-menu", role: "menu", hidden: true },
      h(
        "a",
        {
          href: "#/profile",
          role: "menuitem",
          onClick: () => setMenu(false),
        },
        icon("user"),
        "My profile",
      ),
      h(
        "a",
        {
          href: "#/password",
          role: "menuitem",
          onClick: () => setMenu(false),
        },
        icon("edit"),
        "Change password",
      ),
      h(
        "button",
        {
          type: "button",
          role: "menuitem",
          onClick: () => {
            setMenu(false);
            session.signOut("manual");
          },
        },
        icon("x"),
        "Sign out",
      ),
    );
    account.replaceChildren(toggle, panel);
  }

  // ---- side panel
  function visibleGroups(state) {
    const gate = state.gate ?? null;
    return GROUPS
      .filter((g) => !g.dev || isDev)
      .map((g) => ({
        label: g.label,
        items: g.items.filter((n) => {
          if (n.onlyGate && n.onlyGate !== gate) return false;
          if (gate && !n.gated) return false;
          return checkAccess(routeAccess(n.path), gatePages).allow;
        }),
      }))
      .filter((g) => g.items.length);
  }

  function draw(path) {
    const state = session.getState();
    const signedIn = state.status === "signed_in";
    document.body.dataset.signedIn = String(signedIn);
    drawAccount(state);
    if (!signedIn) {
      setDrawer(false);
      nav.replaceChildren();
      return;
    }
    nav.replaceChildren(
      ...visibleGroups(state).flatMap((g) => [
        h("div", { class: "nav-heading" }, g.label),
        ...g.items.map((n) =>
          h(
            "a",
            {
              class: "nav-link",
              href: `#${n.path}`,
              "aria-current": n.path === path ? "page" : null,
            },
            icon(n.icon),
            n.label,
          )
        ),
      ]),
    );
  }

  return { draw };
}
