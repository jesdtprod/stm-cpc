import { badge, button, h, icon, kpiCard, memberHero, pageHeader } from "./ui.js";
import { formatCourtTime as time } from "./lib/dates.js";
import { signedAvatarUrls } from "./lib/avatar.js";
import {
  eventDivisions,
  eventSummary,
  eventSummarySkeleton,
} from "./event-summary.js";

export { componentsPage } from "./pages-components.js";
export { checkinSkeleton } from "./pages-checkin.js";

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
function publicListPage({ api, hero, pick, renderCards, rpc = "public_landing_info", extra = null, refreshMs = 0 }) {
  const host = h("div", { class: "public-page-body" });
  let signature = "";
  // silent = a background refresh: no loading cards, and the page is only redrawn when the data really changed.
  async function load(silent = false) {
    if (!silent) host.replaceChildren(renderCards([], "loading", () => load()));
    try {
      const info = await api.rpc(rpc);
      // optional extra data (the events page's rosters); the page still works if it cannot be loaded
      const more = extra ? await extra().catch(() => null) : null;
      const next = JSON.stringify(info) + (more?.signature ?? "");
      if (silent && next === signature) return;
      signature = next;
      host.replaceChildren(renderCards(pick(info) ?? [], "ready", () => load(), more));
    } catch {
      if (!silent) host.replaceChildren(renderCards([], "error", () => load()));
    }
  }
  load();
  // Keep the page current while it is open (a draw or undraw shows up by itself); stops when the page is left.
  if (refreshMs) {
    const stop = () => {
      clearInterval(timer);
      document.removeEventListener("visibilitychange", onVisible);
    };
    const tick = () => {
      if (!host.isConnected) return stop();
      if (!document.hidden) load(true);
    };
    const onVisible = () => { if (!document.hidden) tick(); };
    const timer = setInterval(tick, refreshMs);
    document.addEventListener("visibilitychange", onVisible);
  }
  return h("div", { class: "page public-page" }, hero, host);
}

function renderCourtCards(rows, state, onRetry) {
  if (state === "loading") {
    return h(
      "div",
      { class: "public-courts-grid", "aria-busy": "true" },
      ...Array.from({ length: 4 }, () =>
        h(
          "article",
          { class: "public-card public-court-card is-skeleton", "aria-hidden": "true" },
          h(
            "div",
            { class: "public-court-header" },
            h(
              "div",
              { class: "public-court-title-group" },
              h("span", {
                class: "sk member-avatar is-icon public-court-avatar sk-court-avatar",
              }),
              h(
                "div",
                { class: "public-court-title-copy", style: "flex: 1;" },
                h("span", { class: "sk sk-court-title" }),
              ),
            ),
            h("span", { class: "sk sk-pill sk-court-badge" }),
          ),
          h(
            "div",
            { class: "public-court-meta" },
            h(
              "div",
              { class: "public-court-meta-tile" },
              h("span", { class: "sk sk-meta-label", style: "width: 105px;" }),
              h("span", { class: "sk sk-court-hours-val" }),
              h("span", { class: "sk sk-sub", style: "width: 58px;" }),
            ),
            h(
              "div",
              { class: "public-court-meta-tile" },
              h("span", { class: "sk sk-meta-label", style: "width: 52px;" }),
              h("span", { class: "sk sk-court-surface-val" }),
            ),
          ),
          h(
            "dl",
            { class: "public-court-counts", "aria-hidden": "true" },
            h(
              "div",
              {},
              h("dt", {}, h("span", { class: "sk sk-meta-label", style: "width: 76px;" })),
              h("dd", {}, h("span", { class: "sk sk-court-count-val sk-vacant" })),
            ),
            h(
              "div",
              {},
              h("dt", {}, h("span", { class: "sk sk-meta-label", style: "width: 86px;" })),
              h("dd", {}, h("span", { class: "sk sk-court-count-val" })),
            ),
          ),
          h(
            "div",
            { class: "public-court-footer" },
            h("span", {
              class: "sk sk-court-btn-primary",
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


function renderEventCards(rows, state, onRetry, rosters = null) {
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
      h("h2", {}, "No public events yet"),
      h(
        "p",
        { class: "muted" },
        "Published club events and tournaments will appear here with their current status.",
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
        eventDivisions(e.divisions, rosters ? (d) => rosters.get(`${e.name}|${e.starts_on}|${d.name}`) : null),
        acceptsRegistrations(e)
          ? h(
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
            ),
          )
          : null,
      );
    }),
  );
}

/** The sign-in-to-register footer only makes sense while people can still join: registration is open and a division has room. */
function acceptsRegistrations(e) {
  if (e.status !== "registration_open") return false;
  const divisions = e.divisions ?? [];
  if (!divisions.length) return true;
  return divisions.some((d) => !(Number(d.max_entries ?? 0) > 0 && Number(d.taken ?? 0) >= Number(d.max_entries)));
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

// One request for every published event's approved teams, then one batch of signed photo links.
async function loadRosters(api, client) {
  const rows = (await api.rpc("public_event_rosters")) ?? [];
  const urls = client
    ? await signedAvatarUrls(client, rows.flatMap((r) => [r.p1_path, r.p2_path]))
    : new Map();
  const byDivision = new Map();
  for (const r of rows) {
    const key = `${r.event_name}|${r.starts_on}|${r.division_name}`;
    const players = [{ name: r.p1_name, photo: urls.get(r.p1_path) }];
    if (r.p2_name) players.push({ name: r.p2_name, photo: urls.get(r.p2_path) });
    if (!byDivision.has(key)) byDivision.set(key, { divisionId: r.division_id, drawn: Boolean(r.drawn), finished: Boolean(r.finished), teams: [] });
    byDivision.get(key).teams.push({ team: r.team_name, players, matchNo: r.match_no ?? null, opponent: r.opponent ?? null });
  }
  // what the roster rows say (not the photo links, which change every time they are signed): used to see if anything changed
  byDivision.signature = JSON.stringify(rows);
  return byDivision;
}

export function eventsPage({ api, client = null }) {
  return publicListPage({
    api,
    extra: () => loadRosters(api, client),
    refreshMs: 20000,
    hero: memberHero({
      iconName: "trophy",
      eyebrow: "Competition",
      title: "Club Events & Tournaments",
      publicHeader: true,
      description:
        "Club events and tournaments, including their current status.",
      chip: "Public Events",
    }),
    // The newest event first; finished events stay on the list.
    pick: (info) =>
      [...(info?.events ?? [])].sort((a, b) =>
        String(b.starts_on).localeCompare(String(a.starts_on)) || String(a.name).localeCompare(String(b.name))
      ),
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
