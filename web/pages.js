import { badge, button, h, icon, kpiCard, memberHero, pageHeader } from "./ui.js";
import { formatCourtTime as time } from "./lib/dates.js";
import {
  eventDivisions,
  eventSummary,
  eventSummarySkeleton,
} from "./event-summary.js";

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
function publicListPage({ api, hero, pick, renderCards, rpc = "public_landing_info" }) {
  const host = h("div", { class: "public-page-body" });
  async function load() {
    host.replaceChildren(renderCards([], "loading", load));
    try {
      const info = await api.rpc(rpc);
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
          { class: "public-card public-court-card", "aria-hidden": "true" },
          h(
            "div",
            { class: "public-court-header" },
            h(
              "div",
              { class: "public-court-title-group" },
              h("span", {
                class: "sk member-avatar is-icon public-court-avatar",
                style: "border-radius: var(--r-control);",
              }),
              h(
                "div",
                { class: "public-court-title-copy", style: "flex: 1;" },
                sk("w-50"),
              ),
            ),
            h("span", { class: "sk sk-pill", style: "width: 70px; height: 22px;" }),
          ),
          h(
            "div",
            { class: "public-court-meta" },
            h(
              "div",
              { class: "public-court-meta-tile" },
              sk("w-40 sk-sub"),
              sk("w-70"),
              sk("w-40 sk-sub"),
            ),
            h(
              "div",
              { class: "public-court-meta-tile" },
              sk("w-40 sk-sub"),
              sk("w-70"),
            ),
          ),
          h(
            "div",
            { class: "public-court-counts" },
            ...Array.from({ length: 2 }, () =>
              h("div", {}, sk("w-70 sk-sub"), sk("w-30"))
            ),
          ),
          h(
            "div",
            { class: "public-court-footer" },
            h("span", {
              class: "sk",
              style: "width: 100%; height: 44px; border-radius: var(--r-control);",
            }),
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
        ? "Everyday"
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
            h(
              "span",
              { class: "public-court-meta-label" },
              icon("clock"),
              "Operating Hours",
            ),
            h("span", { class: "public-court-meta-val" }, hoursText),
            h("span", { class: "sub" }, daysText),
          ),
          h(
            "div",
            { class: "public-court-meta-tile" },
            h("span", { class: "public-court-meta-label" }, icon("layers"), "Surface"),
            h("span", { class: "public-court-meta-val" }, c.surface || "Standard"),
          ),
        ),
        h(
          "dl",
          { class: "public-court-counts", "aria-label": "Today's court slots" },
          h(
            "div",
            {},
            h("dt", {}, "Vacant Today"),
            h("dd", {}, c.availability?.vacant ?? "—"),
          ),
          h(
            "div",
            {},
            h("dt", {}, "Occupied Today"),
            h("dd", {}, c.availability?.occupied ?? "—"),
          ),
        ),
        c.notes?.trim()
          ? h(
            "p",
            { class: "court-card-note" },
            icon("info"),
            h("span", { class: "sub" }, c.notes.trim()),
          )
          : null,
        h(
          "div",
          { class: "public-court-footer" },
          h(
            "a",
            { class: "btn btn-primary btn-block", href: "#/book" },
            h(
              "span",
              { class: "public-court-reserve-label" },
              icon("calendar"),
              "Reserve Court",
            ),
            icon("chevr"),
          ),
        ),
      );
    }),
  );
}


function renderEventCards(rows, state, onRetry) {
  if (state === "loading") {
    return h(
      "div",
      { class: "public-cards-list", "aria-busy": "true" },
      ...Array.from({ length: 2 }, () =>
        h(
          "div",
          { class: "public-card public-event-card", "aria-hidden": "true" },
          ...eventSummarySkeleton(),
          h(
            "div",
            { class: "public-card-footer" },
            h(
              "div",
              { class: "public-card-footer-note" },
              h("span", {
                class: "sk",
                style: "width: 15px; height: 15px; border-radius: 50%; flex-shrink: 0;",
              }),
              h("span", {
                class: "sk",
                style: "width: 260px; max-width: 70%;",
              }),
            ),
            h(
              "div",
              { class: "public-card-actions" },
              h("span", {
                class: "sk",
                style: "width: 140px; height: 38px; border-radius: var(--r-control);",
              }),
              h("span", {
                class: "sk",
                style: "width: 88px; height: 38px; border-radius: var(--r-control);",
              }),
            ),
          ),
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
        eventDivisions(e.divisions),
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
    rpc: "public_courts",
    hero: memberHero({
      iconName: "calendar",
      eyebrow: "Courts",
      title: "Court Booking",
      publicHeader: true,
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
      publicHeader: true,
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
