// The app shell (PLAN 3.6): header with the account menu, and the side panel built from the
// user's permissions. The menu is a convenience only; every page and every call is checked again
// by the router and the database.
import { button, h, icon, openModal } from "./ui.js";

function svgEl(name, attrs = {}, ...children) {
  const el = document.createElementNS("http://www.w3.org/2000/svg", name);
  for (const [k, v] of Object.entries(attrs)) {
    if (v != null) el.setAttribute(k, String(v));
  }
  for (const c of children) {
    if (c) {
      el.appendChild(typeof c === "string" ? document.createTextNode(c) : c);
    }
  }
  return el;
}

// Each entry uses the access rule of its own route, so a user sees exactly the pages they can open.
// `gated: true` entries stay visible while a user is held at a gate (password change, waiting for approval).
const GROUPS = [
  {
    label: "Overview",
    items: [{ path: "/", label: "Home", icon: "home", gated: true }],
  },
  {
    label: "Play",
    items: [
      { path: "/book", label: "Book a court", icon: "calendar" },
      { path: "/bookings", label: "My bookings", icon: "clock" },
    ],
  },
  {
    label: "Club",
    items: [
      { path: "/admin/members", label: "Members", icon: "user" },
      { path: "/admin/bookings", label: "Bookings", icon: "calendar" },
      { path: "/admin/payments", label: "Payments", icon: "currency" },
      {
        path: "/admin/categories",
        label: "Categories",
        icon: "layers",
      },
      { path: "/admin/staff", label: "Staff and roles", icon: "user" },
      { path: "/admin/import", label: "Member import", icon: "upload" },
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
  const mobileNav = el("mobile-bottom-nav");
  const centerNav = el("header-center-nav");

  if (centerNav) {
    centerNav.addEventListener("click", (e) => {
      const link = e.target.closest("a[data-anchor]");
      if (!link) return;
      const anchor = link.dataset.anchor;
      const target = document.getElementById(anchor);
      if (target) {
        e.preventDefault();
        target.scrollIntoView({ behavior: "smooth" });
      }
    });
  }

  function updateHeaderScroll() {
    const isScrolled = (globalThis.scrollY ?? 0) > 20;
    const header = document.querySelector(".app-header");
    if (header) {
      header.classList.toggle("is-scrolled", isScrolled);
    }
  }
  globalThis.addEventListener("scroll", updateHeaderScroll, { passive: true });

  function openQrScanModal() {
    const state = session.getState();
    const name = state.access?.display_name || "Club Member";
    const memberNo = state.access?.member_no || "CPC-MEMBER";

    let modalRef = null;
    const closeBtn = button({
      label: "Close",
      variant: "secondary",
      onClick: () => modalRef?.close(),
    });

    modalRef = openModal({
      title: "Member QR Code & Check-in",
      body: h(
        "div",
        { class: "qr-modal-body" },
        h(
          "div",
          { class: "qr-viewfinder" },
          icon("qrScan"),
          h("div", { class: "qr-scan-bar" }),
        ),
        h(
          "p",
          { class: "qr-hint" },
          "Scan court QR to check in or present your member ID badge:",
        ),
        h(
          "div",
          { class: "qr-badge-preview" },
          h("div", { class: "qr-badge-name" }, name),
          h("div", { class: "qr-badge-id" }, `Member ID: ${memberNo}`),
          h("span", { class: "badge badge-success" }, "Active Member"),
        ),
      ),
      actions: [closeBtn],
    });
  }

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
        h("a", { class: "btn btn-outline", href: "#/signin" }, "Sign In"),
        h("a", { class: "btn btn-accent", href: "#/signup" }, "Join the club"),
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

    // Landing page: root path when not signed in
    const isLanding = (path === "/" || path === "") && !signedIn;
    document.body.dataset.landing = String(isLanding);
    document.documentElement.dataset.landing = String(isLanding);

    // Member view vs Admin view: admin paths are under /admin
    const isMemberView = !path.startsWith("/admin");
    document.body.dataset.memberView = String(isMemberView);
    document.body.dataset.adminView = String(!isMemberView);

    updateHeaderScroll();

    drawAccount(state);

    // Center header navigation active state
    if (centerNav) {
      for (const link of centerNav.querySelectorAll(".header-nav-link")) {
        const route = link.dataset.route;
        if (route) {
          const isActive = route === "/"
            ? (path === "/" || path === "")
            : path.startsWith(route);
          link.classList.toggle("is-active", isActive);
          if (isActive) link.setAttribute("aria-current", "page");
          else link.removeAttribute("aria-current");
        }
      }
    }

    // Render mobile floating bottom navbar
    if (mobileNav) {
      if (isMemberView) {
        mobileNav.hidden = false;
        const isHome = path === "/" || path === "";
        const isBooking = path === "/booking";
        const isQr = path === "/qr";
        const isEvents = path === "/events";
        const isAccount = path === "/profile" || path === "/password" ||
          path === "/pending";

        const bgSvg = svgEl(
          "svg",
          {
            class: "bottom-nav-bg-svg",
            viewBox: "0 0 390 66",
            preserveAspectRatio: "none",
            "aria-hidden": "true",
          },
          svgEl("path", {
            d: "M 0 24 C 0 10 10 0 24 0 L 146 0 C 162 0 168 28 195 28 C 222 28 228 0 244 0 L 366 0 C 380 0 390 10 390 24 L 390 66 L 0 66 Z",
            fill: "#FFFFFF",
          }),
        );

        const itemsWrap = h(
          "div",
          { class: "bottom-nav-items-grid" },
          h(
            "a",
            {
              class: `bottom-nav-item${isHome ? " is-active" : ""}`,
              href: "#/",
              "aria-label": "Home",
              "aria-current": isHome ? "page" : null,
            },
            icon("home"),
            h("span", { class: "bottom-nav-label" }, "Home"),
          ),
          h(
            "a",
            {
              class: `bottom-nav-item${isBooking ? " is-active" : ""}`,
              href: "#/booking",
              "aria-label": "Courts",
              "aria-current": isBooking ? "page" : null,
            },
            icon("calendar"),
            h("span", { class: "bottom-nav-label" }, "Courts"),
          ),
          h(
            "div",
            { class: "bottom-nav-elevated-wrap" },
            h(
              "button",
              {
                class: `bottom-nav-elevated-btn${isQr ? " is-active" : ""}`,
                type: "button",
                "aria-label": "Explore / QR Pass",
                onClick: (e) => {
                  e.preventDefault();
                  openQrScanModal();
                },
              },
              icon("qrScan"),
            ),
            h(
              "span",
              { class: "bottom-nav-label bottom-nav-center-label" },
              "Explore",
            ),
          ),
          h(
            "a",
            {
              class: `bottom-nav-item${isEvents ? " is-active" : ""}`,
              href: "#/events",
              "aria-label": "Events",
              "aria-current": isEvents ? "page" : null,
            },
            icon("trophy"),
            h("span", { class: "bottom-nav-label" }, "Events"),
          ),
          h(
            "a",
            {
              class: `bottom-nav-item${isAccount ? " is-active" : ""}`,
              href: signedIn ? "#/profile" : "#/signin",
              "aria-label": "Profile",
              "aria-current": isAccount ? "page" : null,
            },
            icon("user"),
            h("span", { class: "bottom-nav-label" }, "Profile"),
          ),
        );

        mobileNav.replaceChildren(bgSvg, itemsWrap);
      } else {
        mobileNav.hidden = true;
        mobileNav.replaceChildren();
      }
    }

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
