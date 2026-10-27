import { badge, button, h, icon, kpiCard, memberHero, pageHeader } from "./ui.js";
import { formatCourtTime as time } from "./lib/dates.js";
import { eventSummary, eventSummarySkeleton } from "./event-summary.js";

export { componentsPage } from "./pages-components.js";

export function homePage() {
  return h(
    "div",
    { class: "page" },
    pageHeader({
      icon: "home",
      eyebrow: "Welcome",
      title: "Capitol Pickleball Club",
      description:
        "Sign-in, bookings, ranks and tournaments arrive in later steps.",
    }),
    h(
      "div",
      { class: "kpis" },
      kpiCard("Members", "—"),
      kpiCard("Bookings Today", "—"),
      kpiCard("Open Events", "—"),
    ),
  );
}

// Public courts and events come from public_landing_info (1540/1550): names, dates, place, status, fee,
// court settings and usual hours only. Nothing about members leaves the database.
// One loader per page: draw loading cards, then the rows (or the error state with retry).
function publicListPage({ api, hero, pick, renderCards }) {
  const host = h("div", { class: "public-page-body" });
  async function load() {
    host.replaceChildren(renderCards([], "loading", load));
    try {
      const info = await api.rpc("public_landing_info");
      host.replaceChildren(renderCards(pick(info) ?? [], "ready", load));
    } catch {
      host.replaceChildren(renderCards([], "error", load));
    }
  }
  load();
  return h("div", { class: "page public-page" }, hero, host);
}

function renderCourtCards(rows, state, onRetry) {
  if (state === "loading") {
    const sk = (shape = "w-70") => h("span", { class: `sk ${shape}` });
    return h(
      "div",
      { class: "public-courts-grid", "aria-busy": "true" },
      ...Array.from({ length: 4 }, () =>
        h(
          "div",
          { class: "public-card public-court-card sk-card", "aria-hidden": "true" },
          h(
            "div",
            { class: "public-court-header" },
            h(
              "div",
              { class: "public-court-title-group" },
              sk("sk-avatar"),
              h("div", { class: "sk-group" }, sk("w-50"), sk("w-30 sk-sub")),
            ),
            sk("sk-pill"),
          ),
          h(
            "div",
            { class: "public-court-meta" },
            sk("w-70"),
            sk("w-50"),
          ),
        )),
    );
  }
  if (state === "error") {
    return h(
      "div",
      { class: "tbl-state error card", role: "alert" },
      h("span", { class: "badge-icon" }, icon("alert")),
      h("h2", {}, "Could not load courts"),
      h(
        "p",
        { class: "muted" },
        "Something went wrong while loading courts. Please try again.",
      ),
      button({ label: "Retry", icon: "refresh", onClick: onRetry }),
    );
  }
  if (rows.length === 0) {
    return h(
      "div",
      { class: "tbl-state card" },
      h("span", { class: "badge-icon" }, icon("inbox")),
      h("h2", {}, "No courts published yet"),
      h(
        "p",
        { class: "muted" },
        "Court details appear here once the club publishes them.",
      ),
    );
  }
  return h(
    "div",
    { class: "public-courts-grid", role: "feed", "aria-label": "Club Courts" },
    ...rows.map((c) => {
      const hoursText = c.hours?.opens
        ? `${time(c.hours.opens)} – ${time(c.hours.closes, true)}`
        : "—";
      const daysText = c.hours?.days >= 7
        ? "Every day"
        : c.hours?.days
        ? `${c.hours.days} days a week`
        : "Operating Days";

      return h(
        "article",
        { class: "public-card public-court-card", "aria-label": c.name },
        h(
          "div",
          { class: "public-court-header" },
          h(
            "div",
            { class: "public-court-title-group" },
            h(
              "span",
              { class: "member-avatar is-icon public-court-avatar", "aria-hidden": "true" },
              icon("grid"),
            ),
            h(
              "div",
              { class: "public-court-title-copy" },
              h("h2", { class: "public-court-title" }, c.name),
              h(
                "span",
                { class: "sub" },
                [c.indoor ? "Indoor" : "Outdoor", c.surface || null].filter(Boolean).join(" · "),
              ),
            ),
          ),
          badge(c.indoor ? "Indoor" : "Outdoor", "neutral"),
        ),
        h(
          "div",
          { class: "public-court-meta" },
          h(
            "div",
            { class: "public-court-meta-tile" },
            h("span", { class: "public-court-meta-label" }, icon("clock"), "Hours"),
            h("span", { class: "public-court-meta-val" }, hoursText),
            h("span", { class: "sub" }, daysText),
          ),
          h(
            "div",
            { class: "public-court-meta-tile" },
            h("span", { class: "public-court-meta-label" }, icon("layers"), "Surface"),
            h("span", { class: "public-court-meta-val" }, c.surface || "Standard"),
            h("span", { class: "sub" }, "Court Surface"),
          ),
        ),
        h(
          "div",
          { class: "public-court-footer" },
          h(
            "a",
            { class: "btn btn-outline btn-block", href: "#/book" },
            icon("calendar"),
            "Reserve Court",
          ),
        ),
      );
    }),
  );
}


function renderEventCards(rows, state, onRetry) {
  if (state === "loading") {
    return h("div", { class: "public-cards-list", "aria-busy": "true" },
      ...Array.from({ length: 2 }, () => h("div",
        { class: "public-card public-event-card", "aria-hidden": "true" },
        ...eventSummarySkeleton(),
      )),
    );
  }
  if (state === "error") {
    return h(
      "div",
      { class: "tbl-state error card", role: "alert" },
      h("span", { class: "badge-icon" }, icon("alert")),
      h("h2", {}, "Could not load events"),
      h(
        "p",
        { class: "muted" },
        "Something went wrong while loading events. Please try again.",
      ),
      button({ label: "Retry", icon: "refresh", onClick: onRetry }),
    );
  }
  if (rows.length === 0) {
    return h(
      "div",
      { class: "tbl-state card" },
      h("span", { class: "badge-icon" }, icon("inbox")),
      h("h2", {}, "No upcoming events"),
      h(
        "p",
        { class: "muted" },
        "Club events appear here when registration opens. Check back soon.",
      ),
    );
  }
  return h(
    "div",
    { class: "public-cards-list", role: "feed", "aria-label": "Club Events" },
    ...rows.map((e) => {
      return h(
        "article",
        { class: "public-card public-event-card", "aria-label": e.name },
        ...eventSummary(e),
        h(
          "div",
          { class: "public-card-footer" },
          h(
            "div",
            { class: "public-card-footer-note" },
            icon("info"),
            h("span", {}, "Sign in as an active club member to register for this event."),
          ),
          h(
            "div",
            { class: "public-card-actions" },
            h("a", { class: "btn btn-primary", href: "#/signin" }, "Sign In to Register"),
            h("a", { class: "btn btn-outline", href: "#/signup" }, "Join Club"),
          ),
        ),
      );
    }),
  );
}

export function bookingPage({ api }) {
  return publicListPage({
    api,
    hero: memberHero({
      iconName: "calendar",
      eyebrow: "Courts",
      title: "Court Booking",
      description:
        "Our courts and their usual hours. Sign in as a member to reserve a time.",
      chip: "Court Availability",
      actions: [
        h("a", { class: "btn btn-primary", href: "#/book" }, "Book a Court"),
      ],
    }),
    pick: (info) => info?.courts,
    renderCards: renderCourtCards,
  });
}

export function eventsPage({ api }) {
  return publicListPage({
    api,
    hero: memberHero({
      iconName: "trophy",
      eyebrow: "Competition",
      title: "Club Events & Tournaments",
      description:
        "Upcoming and running club events. Sign in as a member to register.",
      chip: "Public Events",
      actions: [
        h("a", { class: "btn btn-primary", href: "#/signin" }, "Sign In"),
      ],
    }),
    pick: (info) => info?.events,
    renderCards: renderEventCards,
  });
}

export function notFoundPage() {
  return h(
    "div",
    { class: "page" },
    pageHeader({
      icon: "alert",
      title: "Page not found",
      description: "That page does not exist.",
    }),
    h("a", { href: "#/" }, "Back to Home"),
  );
}

export function forbiddenPage() {
  return h(
    "div",
    { class: "page" },
    pageHeader({
      icon: "alert",
      title: "No Access",
      description: "Your account does not have permission to open this page.",
    }),
    h("a", { href: "#/" }, "Back to Home"),
  );
}
