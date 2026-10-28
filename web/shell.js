// The app shell (PLAN 3.6): header with the account menu, and the side panel built from the
// user's permissions. The menu is a convenience only; every page and every call is checked again
// by the router and the database.
import { attachPagePattern, h, icon } from "./ui.js";
import { MEMBER_SHORTCUTS } from "./lib/member-shortcuts.js";
import { memberMenuHidden } from "./lib/member-menu.js";
import { isAdminAccount } from "./lib/permissions.js";
import { avatarImage, signedAvatarUrls } from "./lib/avatar.js";

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
      { path: "/book", label: "Book a Court", icon: "calendar" },
      { path: "/bookings", label: "My Bookings", icon: "clock" },
      { path: "/events", label: "Events", icon: "trophy" },
      { path: "/ranking", label: "Ranking", icon: "medal" },
      { path: "/notifications", label: "Notifications", icon: "inbox" },
    ],
  },
  {
    label: "Members",
    view: "admin",
    items: [
      { path: "/admin/members", label: "Members", icon: "user" },
      { path: "/admin/import", label: "Member Import", icon: "upload" },
      { path: "/admin/categories", label: "Categories", icon: "layers" },
      // Ranks management is hidden from the menu: the Club Rank is automatic (the route /admin/ranks still exists).
    ],
  },
  {
    label: "Court Operations",
    view: "admin",
    items: [
      { path: "/admin/courts", label: "Courts", icon: "grid" },
      { path: "/admin/bookings", label: "Bookings", icon: "calendar" },
      { path: "/admin/payments", label: "Payments", icon: "currency" },
    ],
  },
  {
    label: "Competitions",
    view: "admin",
    items: [
      { path: "/admin/events", label: "Events", icon: "trophy" },
      { path: "/admin/scoring", label: "Scoring Rules", icon: "medal" },
      { path: "/notifications", label: "Notifications", icon: "inbox" },
      { path: "/ranking", label: "Ranking", icon: "medal" },
    ],
  },
  {
    label: "Administration",
    view: "admin",
    items: [
      { path: "/admin/staff", label: "Staff and Roles", icon: "user" },
      { path: "/admin/settings", label: "Settings", icon: "filter" },
    ],
  },
  {
    label: "Account",
    items: [
      { path: "/profile", label: "My Profile", icon: "user", gated: true },
      {
        path: "/password",
        label: "Change Password",
        icon: "edit",
        gated: true,
      },
      {
        path: "/pending",
        label: "Account Status",
        icon: "clock",
        gated: true,
        onlyGate: "pending",
      },
    ],
  },
];

const initials = (name) =>
  String(name ?? "").split(/\s+/).filter(Boolean).slice(0, 2)
    .map((w) => w[0]).join("").toUpperCase() || "?";

/**
 * createShell({ session, checkAccess, routeAccess, gatePages })
 * Needs these elements in index.html: #menu-btn, #side, #nav, #scrim, #account.
 * Returns { draw(path) }: call it on every route change and every sign-in or sign-out.
 */
/** The unread count shown beside Notifications in the side menu (set by the live notification feed). */
const unreadBadge = (path) => {
  const n = Number(globalThis.__cpcUnread) || 0;
  return path === "/notifications" && n > 0
    ? (n > 99 ? "99+" : String(n))
    : null;
};

export function createShell(
  { session, client, checkAccess, routeAccess, gatePages },
) {
  const el = (id) => document.getElementById(id);
  const menuBtn = el("menu-btn");
  const side = el("side");
  const nav = el("nav");
  const scrim = el("scrim");
  const account = el("account");
  const header = document.querySelector(".app-header");
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


  // ---- mobile drawer
  function setDrawer(open) {
    side.toggleAttribute("data-open", open);
    scrim.hidden = !open;
    menuBtn.setAttribute("aria-expanded", String(open));
    menuBtn.setAttribute("aria-label", open ? "Close Menu" : "Open Menu");
    if (open) side.querySelector("a")?.focus();
    else if (side.contains(document.activeElement)) {
      menuBtn?.focus();
    }
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
        h("a", { class: "btn btn-primary", href: "#/signin" }, "Sign In"),
        h("a", { class: "btn btn-accent", href: "#/signup" }, "Join the club"),
      );
      return;
    }
    const name = state.access?.display_name || "My Account";
    const memberNo = state.access?.member_no ?? "";
    const avatar = h(
      "span",
      { class: "account-avatar", "aria-hidden": "true" },
      avatarImage(null, name),
    );
    const avatarPath = state.access?.avatar_path;
    if (client && avatarPath) {
      signedAvatarUrls(client, [avatarPath]).then((urls) => {
        const url = urls.get(avatarPath);
        if (url && avatar.isConnected) {
          avatar.replaceChildren(avatarImage(url, name));
        }
      });
    }
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
      avatar,
      h(
        "span",
        { class: "account-text" },
        h("span", { class: "account-name" }, name),
        memberNo ? h("span", { class: "account-no" }, memberNo) : null,
      ),
      h(
        "span",
        { class: "account-chevron", "aria-hidden": "true" },
        icon("chevr"),
      ),
    );
    panel = h(
      "div",
      { class: "account-menu", id: "account-menu", role: "menu", hidden: true },
      h(
        "div",
        { class: "account-menu-header" },
        h("span", { class: "account-menu-name" }, name),
        memberNo ? h("span", { class: "account-menu-no" }, memberNo) : null,
      ),
      h(
        "a",
        {
          href: "#/profile",
          role: "menuitem",
          class: "account-menu-item",
          onClick: () => setMenu(false),
        },
        icon("user"),
        "My Profile",
      ),
      h(
        "a",
        {
          href: "#/password",
          role: "menuitem",
          class: "account-menu-item",
          onClick: () => setMenu(false),
        },
        icon("edit"),
        "Change Password",
      ),
      h(
        "button",
        {
          type: "button",
          role: "menuitem",
          class: "account-menu-item is-signout",
          onClick: () => {
            setMenu(false);
            session.signOut("manual");
          },
        },
        icon("logOut"),
        "Sign Out",
      ),
    );
    account.replaceChildren(toggle, panel);
  }

  // ---- side panel
  // The member side (home, play, account) and the admin side (dashboard, club pages) have their own menus.
  // The administrator account has no member side at all: only the admin console.
  let lastView = "member";
  let lastPath = "/";
  // On a computer the member side uses the administrator's layout: the side panel with the account control at its foot and no
  // top header. On a phone it keeps its own floating menu.
  const wide = globalThis.matchMedia?.("(min-width: 901px)");
  wide?.addEventListener?.("change", () => draw(lastPath));
  const viewOf = (path) =>
    isAdminAccount() || path === "/admin" || path.startsWith("/admin/") ||
      (["/profile", "/password", "/pending"].includes(path) &&
        lastView === "admin")
      ? "admin"
      : "member";
  const canOpenAdmin = () =>
    checkAccess(routeAccess("/admin"), gatePages).allow;

  // inAccountMenu: the side panel already has the account menu at its foot, so My profile and Change password are left out of the list
  // (the floating menu on a phone still lists them)
  function visibleGroups(state, view = "member", inAccountMenu = false) {
    const gate = state.gate ?? null;
    return GROUPS
      .filter((g) => !g.view || g.view === view)
      .map((g) => ({
        label: g.label,
        items: g.items.filter((n) => {
          if (
            (view === "admin" || (inAccountMenu && !gate)) &&
            ["/profile", "/password"].includes(n.path)
          ) {
            return false;
          }
          if (n.onlyGate && n.onlyGate !== gate) return false;
          if (gate && !n.gated) return false;
          if (view === "member" && memberMenuHidden(n.path)) return false;
          return checkAccess(routeAccess(n.path), gatePages).allow;
        }),
      }))
      .filter((g) => g.items.length);
  }

  function drawPagePattern() {
    const page = document.querySelector("main .page");
    if (page && !page.querySelector(".dashboard-pattern")) {
      attachPagePattern(page);
    }
  }

  function drawMobilePageHeader(path) {
    if (["/", ""].includes(path)) return;
    const main = document.querySelector("main");
    const page = main?.querySelector(".page");
    const header = page?.querySelector(".dash-hero, .page-header");
    const title = header?.querySelector("h1");
    if (!title || header.classList.contains("mobile-format-header")) return;
    page.classList.add("mobile-format-page");
    header.classList.add("mobile-format-header");
    const role = header.querySelector(".dash-chip.is-role, .eyebrow");
    let heading = header.querySelector(".member-hero-heading");
    if (!heading) {
      heading = h("div", { class: "member-hero-heading" });
      title.replaceWith(heading);
      heading.append(title);
    }
    if (role && !heading.querySelector(".mobile-title-badge")) {
      const roleBadge = h("span", { class: "dash-chip mobile-title-badge" });
      const roleIcon = role.querySelector("svg") ??
        header.querySelector(".badge-icon svg");
      if (roleIcon) roleBadge.append(roleIcon.cloneNode(true));
      roleBadge.append(document.createTextNode(role.textContent));
      heading.append(roleBadge);
    }
    if (header.classList.contains("page-header")) {
      const description = title.parentElement.parentElement;
      description.classList.add("mobile-header-copy");
      description.append(
        h(
          "div",
          { class: "dash-hero-chips mobile-header-chips" },
          h(
            "span",
            { class: "dash-chip is-date" },
            icon("calendar"),
            new Intl.DateTimeFormat("en-PH", {
              timeZone: "Asia/Manila",
              weekday: "short",
              month: "short",
              day: "numeric",
              year: "numeric",
            }).format(new Date()),
          ),
          h("span", { class: "dash-chip is-status" }, title.textContent),
        ),
      );
    }
  }

  function draw(path) {
    const state = session.getState();
    const signedIn = state.status === "signed_in";
    document.body.dataset.signedIn = String(signedIn);
    drawPagePattern();
    drawMobilePageHeader(path);

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
    lastPath = path;
    const isAdminPath = signedIn && viewOf(path) === "admin";
    const isMemberView = !isAdminPath;
    const memberHeader = document.querySelector("main .mobile-format-header");
    if (memberHeader) {
      const logo = memberHeader.querySelector(".member-header-logo");
      if (signedIn && !["/", ""].includes(path)) {
        if (!logo) {
          memberHeader.prepend(h("img", {
            class: "member-header-logo",
            src: "icons/cpc-logo-256.webp",
            alt: "Capitol Pickleball Club",
            width: 128,
            height: 128,
          }));
        }
      } else if (!memberHeader.classList.contains("public-page-hero")) {
        logo?.remove();
      }
    }
    for (const page of document.querySelectorAll("main .page")) {
      page.classList.toggle("admin-reference-page", isAdminPath);
      page.classList.toggle(
        "member-mobile-lists",
        signedIn && isMemberView && !page.classList.contains("dash-page"),
      );
    }
    // the side-panel layout: the admin side always, the member side on a computer
    const sidePanel = signedIn && (isAdminPath || Boolean(wide?.matches));
    lastView = isAdminPath ? "admin" : "member";
    document.body.dataset.memberView = String(isMemberView);
    document.body.dataset.adminView = String(sidePanel);
    const brand = document.querySelector(".admin-brand");
    if (brand) {
      brand.setAttribute("href", isAdminPath ? "#/admin" : "#/");
      const small = brand.querySelector("small");
      if (small) {
        small.textContent = isAdminPath ? "Administration" : "Member Area";
      }
    }

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
            title: "Close Menu",
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
            `${open ? "Close navigation menu" : "Open navigation menu"}${
              unreadBadge("/notifications")
                ? `, ${unreadBadge("/notifications")} unread notifications`
                : ""
            }`,
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
            href === "#/notifications" && unreadBadge("/notifications")
              ? h("span", {
                class: "notification-count assistive-nav-item-count",
                "aria-label": "Unread notifications",
              }, unreadBadge("/notifications"))
              : h("span", {
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
        // Members share their dashboard shortcuts; admin and gated menus retain their access-aware navigation.
        const groupTabs = signedIn && !state.gate && viewOf(path) === "member"
          ? [
            tab({
              label: "Home",
              detail: "Club Overview",
              iconName: "home",
              active: isHome,
              href: "#/",
            }),
            ...MEMBER_SHORTCUTS.filter((item) =>
              !memberMenuHidden(item.href) &&
              checkAccess(routeAccess(item.href.slice(1)), gatePages).allow
            ).map((item) =>
              tab({
                label: item.label,
                detail: item.desc,
                iconName: item.icon,
                active: path === item.href.slice(1),
                href: item.href,
              })
            ),
          ]
          : signedIn
          ? visibleGroups(state, viewOf(path)).flatMap((g) =>
            g.items.map((n) =>
              tab({
                label: n.label,
                detail: g.label,
                iconName: n.icon,
                active: n.path === "/" ? isHome : path === n.path,
                href: `#${n.path}`,
              })
            )
          )
          : [];
        // The administrator's side menu has no account pages (they live in the account menu), so the floating menu adds Profile.
        const adminProfileTab = signedIn && viewOf(path) === "admin"
          ? tab({
            label: "Profile",
            detail: "Your club account",
            iconName: "user",
            active: isAccount,
            href: "#/profile",
          })
          : null;
        const switchTab = signedIn && !state.gate && canOpenAdmin() &&
            !isAdminAccount()
          ? tab({
            label: viewOf(path) === "admin" ? "Member View" : "Admin Console",
            detail: viewOf(path) === "admin"
              ? "Back to your own home"
              : "Dashboard and club pages",
            iconName: viewOf(path) === "admin" ? "home" : "grid",
            href: viewOf(path) === "admin" ? "#/" : "#/admin",
          })
          : null;
        const signOutTab = signedIn
          ? tab({
            label: "Sign Out",
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
                  src: "icons/cpc-logo-256.webp",
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
            ...(signedIn
              ? [
                ...groupTabs,
                adminProfileTab,
              ]
              : [
                tab({
                  label: "Home",
                  detail: "Club Overview",
                  iconName: "home",
                  active: isHome,
                  href: "#/",
                }),
                tab({
                  label: "Courts",
                  detail: "Book court time",
                  iconName: "calendar",
                  active: isBooking,
                  href: "#/booking",
                }),
                tab({
                  label: "Events",
                  detail: "Club events and play",
                  iconName: "trophy",
                  active: isEvents,
                  href: "#/events",
                }),
                tab({
                  label: "Members",
                  detail: "Our players and ranks",
                  iconName: "user",
                  active: path === "/members",
                  href: "#/members",
                }),
                tab({
                  label: "Profile",
                  detail: "Sign in / Register",
                  iconName: "user",
                  active: isAccount,
                  href: "#/signin",
                }),
              ]),
            switchTab,
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
            src: "icons/cpc-logo-256.webp",
            alt: "",
            "aria-hidden": "true",
          }),
          signedIn && unreadBadge("/notifications")
            ? h("span", {
              class: "notification-count assistive-notification-count",
              "aria-hidden": "true",
            }, unreadBadge("/notifications"))
            : null,
        );
        if (signedIn && unreadBadge("/notifications")) {
          toggle.setAttribute(
            "aria-label",
            `Open navigation menu, ${
              unreadBadge("/notifications")
            } unread notifications`,
          );
        }
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
    const groups = visibleGroups(state, view, sidePanel);
    // Staff can move between their own member home and the admin console.
    const viewSwitch = !state.gate && canOpenAdmin() && !isAdminAccount()
      ? h(
        "div",
        { class: "view-switch", role: "group", "aria-label": "Switch View" },
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
    const navItems = [
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
            h(
              "span",
              { class: "nav-link-icon", "aria-hidden": "true" },
              icon(n.icon),
            ),
            h("span", { class: "nav-link-label" }, n.label),
            (n.badge ?? unreadBadge(n.path))
              ? h(
                "span",
                {
                  class: `nav-link-badge${
                    n.path === "/notifications" ? " notification-count" : ""
                  }`,
                },
                n.badge ?? unreadBadge(n.path),
              )
              : null,
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
              state.access?.display_name ?? "My Account",
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
          "Sign Out",
        ),
      ),
    ].filter(Boolean);
    nav.replaceChildren(...navItems);
    if (sidePanel) nav.querySelector(".side-foot").replaceChildren(account);
  }

  return { draw };
}
