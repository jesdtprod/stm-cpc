// The app shell (PLAN 3.6): header with the account menu, and the side panel built from the
// user's permissions. The menu is a convenience only; every page and every call is checked again
// by the router and the database.
import { button, h, icon, openModal } from "./ui.js";
import { isAdminAccount } from "./lib/permissions.js";

// Each entry uses the access rule of its own route, so a user sees exactly the pages they can open.
// `gated: true` entries stay visible while a user is held at a gate (password change, waiting for approval).
const GROUPS = [
  {
    label: "Overview",
    view: "member",
    items: [{ path: "/", label: "Home", icon: "home", gated: true }],
  },
  {
    label: "Overview",
    view: "admin",
    items: [{ path: "/admin", label: "Dashboard", icon: "grid" }],
  },
  {
    label: "Play",
    view: "member",
    items: [
      { path: "/book", label: "Book a court", icon: "calendar" },
      { path: "/bookings", label: "My bookings", icon: "clock" },
    ],
  },
  {
    label: "Club",
    view: "admin",
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
  const header = document.querySelector(".app-header");
  const adminMenuBtn = el("admin-menu-btn");
  const mobileNav = el("mobile-bottom-nav");
  const centerNav = el("header-center-nav");
  let closeAssistiveMenu = null;

  document.addEventListener("pointerdown", (event) => {
    if (!mobileNav?.contains(event.target)) closeAssistiveMenu?.();
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") closeAssistiveMenu?.();
  });

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
    adminMenuBtn?.setAttribute("aria-expanded", String(open));
    adminMenuBtn?.setAttribute("aria-label", open ? "Close menu" : "Open menu");
    if (open) side.querySelector("a")?.focus();
    else if (side.contains(document.activeElement)) {
      (document.body.dataset.adminView === "true" ? adminMenuBtn : menuBtn)
        ?.focus();
    }
  }
  menuBtn.addEventListener(
    "click",
    () => setDrawer(!side.hasAttribute("data-open")),
  );
  scrim.addEventListener("click", () => setDrawer(false));
  adminMenuBtn?.addEventListener(
    "click",
    () => setDrawer(!side.hasAttribute("data-open")),
  );
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
        h("a", { class: "btn btn-primary", href: "#/signin" }, "Sign In"),
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
  // The member side (home, play, account) and the admin side (dashboard, club pages) have their own menus.
  // The administrator account has no member side at all: only the admin console.
  let lastView = "member";
  const viewOf = (path) =>
    isAdminAccount() || path === "/admin" || path.startsWith("/admin/") ||
      (["/profile", "/password", "/pending"].includes(path) &&
        lastView === "admin")
      ? "admin"
      : "member";
  const canOpenAdmin = () =>
    checkAccess(routeAccess("/admin"), gatePages).allow;

  function visibleGroups(state, view = "member") {
    const gate = state.gate ?? null;
    return GROUPS
      .filter((g) => !g.dev || isDev)
      .filter((g) => !g.view || g.view === view)
      .map((g) => ({
        label: g.label,
        items: g.items.filter((n) => {
          if (view === "admin" && ["/profile", "/password"].includes(n.path)) {
            return false;
          }
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
    // The home page and the sign-in page share one look: the full-screen hero, the pattern, the transparent header.
    const isAuthRoute = path === "/signin" || path === "/signup";
    const isLanding = (path === "/" || path === "" || isAuthRoute) &&
      !signedIn;
    document.body.dataset.landing = String(isLanding);
    // The sign-in page has no top header: only the sign-in card.
    const isAuthPage = isAuthRoute && !signedIn;
    document.body.dataset.authPage = String(isAuthPage);
    document.documentElement.dataset.authPage = String(isAuthPage);
    document.documentElement.dataset.landing = String(isLanding);

    // Account pages retain the view they were opened from.
    const isAdminPath = signedIn && viewOf(path) === "admin";
    const isMemberView = !isAdminPath;
    lastView = isAdminPath ? "admin" : "member";
    document.body.dataset.memberView = String(isMemberView);
    document.body.dataset.adminView = String(isAdminPath);

    updateHeaderScroll();

    drawAccount(state);
    // Keep one account menu and move it into the admin side panel below.
    header.append(account);

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

        // Floating assistive navigation: the draggable logo opens a centered quick menu modal.
        const closeBtn = h(
          "button",
          {
            class: "assistive-nav-menu-close",
            type: "button",
            "aria-label": "Close navigation menu",
            title: "Close menu",
            onClick: () => setMenuOpen(false),
          },
          icon("x"),
        );
        const setMenuOpen = (open) => {
          itemsWrap.hidden = !open;
          scrim.hidden = !open;
          toggle.setAttribute("aria-expanded", String(open));
          toggle.setAttribute(
            "aria-label",
            open ? "Close navigation menu" : "Open navigation menu",
          );
          if (open) {
            closeBtn.focus?.();
          }
        };
        const tab = ({ label, detail, iconName, active, href, onClick }) =>
          h(
            href ? "a" : "button",
            {
              class: `assistive-nav-item${active ? " is-active" : ""}`,
              ...(href
                ? {
                  href,
                  onClick: () => setMenuOpen(false),
                }
                : {
                  type: "button",
                  onClick: (e) => {
                    setMenuOpen(false);
                    onClick?.(e);
                  },
                }),
              "aria-label": label,
              title: label,
              "aria-current": active && href ? "page" : null,
              "data-nav": iconName,
            },
            h("span", {
              class: "assistive-nav-item-icon",
              "aria-hidden": "true",
            }, icon(iconName)),
            h(
              "span",
              { class: "assistive-nav-item-copy" },
              h("span", { class: "assistive-nav-item-title" }, label),
              h("span", { class: "assistive-nav-item-detail" }, detail),
            ),
            h("span", {
              class: "assistive-nav-item-chevron",
              "aria-hidden": "true",
            }, icon("chevr")),
          );
        const scrim = h("div", {
          class: "assistive-nav-scrim",
          hidden: true,
          "aria-hidden": "true",
          onClick: () => setMenuOpen(false),
        });
        // The pages this person may open (members, bookings, settings ...), grouped as in the side panel on a computer.
        const shown = new Set(["/", "/profile", "/admin"]);
        const extraTabs = signedIn
          ? visibleGroups(state, viewOf(path)).flatMap((g) =>
            g.items.filter((n) => !shown.has(n.path)).map((n) =>
              tab({
                label: n.label,
                detail: g.label,
                iconName: n.icon,
                active: path === n.path,
                href: `#${n.path}`,
              })
            )
          )
          : [];
        const switchTab = signedIn && !state.gate && canOpenAdmin() &&
            !isAdminAccount()
          ? tab({
            label: viewOf(path) === "admin" ? "Member view" : "Admin console",
            detail: viewOf(path) === "admin"
              ? "Back to your own home"
              : "Dashboard and club pages",
            iconName: viewOf(path) === "admin" ? "home" : "grid",
            href: viewOf(path) === "admin" ? "#/" : "#/admin",
          })
          : null;
        const signOutTab = signedIn
          ? tab({
            label: "Sign out",
            detail: "Leave this device",
            iconName: "x",
            onClick: () => session.signOut("manual"),
          })
          : null;
        const itemsWrap = h(
          "div",
          {
            class: "assistive-nav-menu",
            hidden: true,
            role: "dialog",
            "aria-modal": "true",
            "aria-labelledby": "assistive-nav-title",
          },
          h(
            "div",
            { class: "assistive-nav-menu-header" },
            h(
              "div",
              { class: "assistive-nav-menu-brand" },
              h(
                "div",
                { class: "assistive-nav-menu-crest", "aria-hidden": "true" },
                h("img", {
                  src: "icons/cpc-logo.png",
                  alt: "",
                  class: "assistive-nav-menu-crest-img",
                }),
              ),
              h(
                "div",
                { class: "assistive-nav-menu-headings" },
                h(
                  "span",
                  { class: "assistive-nav-menu-eyebrow" },
                  "Capitol Pickleball",
                ),
                h(
                  "h2",
                  {
                    id: "assistive-nav-title",
                    class: "assistive-nav-menu-title",
                  },
                  "Quick Menu",
                ),
              ),
            ),
            closeBtn,
          ),
          h(
            "div",
            { class: "assistive-nav-menu-items" },
            tab({
              label: "Home",
              detail: isAdminAccount() ? "Admin dashboard" : "Club overview",
              iconName: "home",
              active: isAdminAccount() ? path === "/admin" : isHome,
              href: isAdminAccount() ? "#/admin" : "#/",
            }),
            ...(isAdminAccount() ? [] : [
              tab({
                label: "Courts",
                detail: "Book court time",
                iconName: "calendar",
                active: isBooking,
                href: "#/booking",
              }),
              tab({
                label: "QR pass",
                detail: "Open your member pass",
                iconName: "qrScan",
                active: isQr,
                onClick: (e) => {
                  e.preventDefault();
                  openQrScanModal();
                },
              }),
              tab({
                label: "Events",
                detail: "Club events and play",
                iconName: "trophy",
                active: isEvents,
                href: "#/events",
              }),
            ]),
            tab({
              label: "Profile",
              detail: signedIn ? "Your club account" : "Sign in / Register",
              iconName: "user",
              active: isAccount,
              href: signedIn ? "#/profile" : "#/signin",
            }),
            switchTab,
            ...extraTabs,
            signOutTab,
          ),
          h(
            "div",
            { class: "assistive-nav-menu-footer" },
            h(
              "span",
              { class: "assistive-nav-footer-hint" },
              "Tap anywhere outside to close",
            ),
          ),
        );
        let dragState = null;
        let dragConsumed = false;
        const placeAssistiveNav = (left, top) => {
          const margin = 12;
          const width = globalThis.innerWidth ||
            document.documentElement.clientWidth;
          const height = globalThis.innerHeight ||
            document.documentElement.clientHeight;
          const maxLeft = Math.max(margin, width - 56 - margin);
          const maxTop = Math.max(margin, height - 56 - margin);
          mobileNav.style.left = `${
            Math.min(Math.max(left, margin), maxLeft)
          }px`;
          mobileNav.style.top = `${Math.min(Math.max(top, margin), maxTop)}px`;
          mobileNav.style.right = "auto";
          mobileNav.style.bottom = "auto";
        };
        const toggle = h(
          "button",
          {
            class: "assistive-nav-toggle",
            type: "button",
            "aria-label": "Open navigation menu",
            "aria-expanded": "false",
            "aria-controls": "assistive-nav-menu",
            title: "Navigation",
            onPointerDown: (event) => {
              if (event.button != null && event.button !== 0) return;
              const rect = mobileNav.getBoundingClientRect();
              dragState = {
                pointerId: event.pointerId,
                startX: event.clientX,
                startY: event.clientY,
                left: rect.left,
                top: rect.top,
                moved: false,
              };
              toggle.setPointerCapture?.(event.pointerId);
            },
            onPointerMove: (event) => {
              if (!dragState || dragState.pointerId !== event.pointerId) return;
              event.preventDefault();
              const dx = event.clientX - dragState.startX;
              const dy = event.clientY - dragState.startY;
              if (Math.abs(dx) > 4 || Math.abs(dy) > 4) dragState.moved = true;
              if (dragState.moved) {
                placeAssistiveNav(dragState.left + dx, dragState.top + dy);
              }
            },
            onPointerUp: (event) => {
              if (!dragState || dragState.pointerId !== event.pointerId) return;
              toggle.releasePointerCapture?.(event.pointerId);
              if (dragState.moved) {
                dragConsumed = true;
                try {
                  localStorage.setItem(
                    "cpc-assistive-nav-position",
                    JSON.stringify({
                      left: mobileNav.style.left,
                      top: mobileNav.style.top,
                    }),
                  );
                } catch {
                  // Position persistence is optional.
                }
              }
              dragState = null;
            },
            onPointerCancel: () => {
              dragState = null;
            },
            onClick: () => {
              if (dragConsumed) {
                dragConsumed = false;
                return;
              }
              setMenuOpen(itemsWrap.hidden);
            },
          },
          h("img", {
            class: "assistive-nav-logo",
            src: "icons/cpc-logo.png",
            alt: "",
            "aria-hidden": "true",
          }),
        );
        itemsWrap.id = "assistive-nav-menu";
        mobileNav.replaceChildren(scrim, itemsWrap, toggle);
        closeAssistiveMenu = () => setMenuOpen(false);
        try {
          const saved = JSON.parse(
            localStorage.getItem("cpc-assistive-nav-position"),
          );
          if (
            Number.parseFloat(saved?.left) >= 0 &&
            Number.parseFloat(saved?.top) >= 0
          ) {
            placeAssistiveNav(
              Number.parseFloat(saved.left),
              Number.parseFloat(saved.top),
            );
          }
        } catch {
          // A first visit or restricted storage uses the CSS default position.
        }
      } else {
        closeAssistiveMenu = null;
        mobileNav.hidden = true;
        mobileNav.replaceChildren();
      }
    }

    if (!signedIn) {
      setDrawer(false);
      nav.replaceChildren();
      return;
    }
    const view = viewOf(path);
    const groups = visibleGroups(state, view);
    // Staff can move between their own member home and the admin console.
    const viewSwitch = !state.gate && canOpenAdmin() && !isAdminAccount()
      ? h(
        "div",
        { class: "view-switch", role: "group", "aria-label": "Switch view" },
        h(
          "a",
          {
            class: `view-switch-btn${view === "member" ? " is-active" : ""}`,
            href: "#/",
            "aria-current": view === "member" ? "true" : null,
          },
          icon("user"),
          "Member",
        ),
        h(
          "a",
          {
            class: `view-switch-btn${view === "admin" ? " is-active" : ""}`,
            href: "#/admin",
            "aria-current": view === "admin" ? "true" : null,
          },
          icon("grid"),
          "Admin",
        ),
      )
      : null;
    nav.replaceChildren(
      viewSwitch,
      ...groups.flatMap((g) => [
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
      h(
        "div",
        { class: "side-foot" },
        h(
          "div",
          { class: "side-user" },
          h(
            "span",
            { class: "side-user-avatar", "aria-hidden": "true" },
            initials(state.access?.display_name),
          ),
          h(
            "div",
            { class: "side-user-copy" },
            h(
              "span",
              { class: "side-user-name" },
              state.access?.display_name ?? "My account",
            ),
            h("span", { class: "side-user-id" }, state.access?.member_no ?? ""),
          ),
        ),
        h(
          "button",
          {
            class: "btn btn-secondary side-signout",
            type: "button",
            onClick: () => session.signOut("manual"),
          },
          icon("logOut"),
          "Sign out",
        ),
      ),
    );
    if (isAdminPath) nav.querySelector(".side-foot").replaceChildren(account);
  }

  return { draw };
}
