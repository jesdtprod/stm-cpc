// Shared public/member tournament summary. Registration actions stay with each page.
import { badge, formatTemplateLabel, h, icon } from "./ui.js";
import { formatDate, formatDateTime } from "./lib/dates.js";
import { formatMoney } from "./lib/money.js";
import { avatarImage } from "./lib/avatar.js";

const STATUS = {
  registration_open: ["Registration Open", "success"],
  registration_closed: ["Registration Closed", "neutral"],
  drawn: ["Draw Made", "info"],
  in_progress: ["Under Way", "warning"],
  completed: ["Completed", "success"],
  cancelled: ["Cancelled", "danger"],
};
const day = (value) => formatDate(`${value}T00:00:00+08:00`);
const detail = (label, value, symbol, className = "") =>
  h(
    "div",
    { class: className },
    h("dt", {}, icon(symbol), label),
    h("dd", {}, value),
  );

export function eventSummary(event) {
  const [label, tone] = STATUS[event.status] ?? [event.status, "neutral"];
  const cpc = event.apply_cpc_rank_changes ? "Club Ranked" : "No Club Rank Movement";
  const dupr = event.dupr_rated ? "DUPR Rated" : "DUPR Unrated";
  const count = Number(event.divisions_count ?? 0);
  const opens = event.registration_opens_at;
  const closes = event.registration_closes_at;
  const window = opens && closes
    ? `${formatDateTime(opens)} – ${formatDateTime(closes)}`
    : opens
    ? `Opens ${formatDateTime(opens)}`
    : closes
    ? `Closes ${formatDateTime(closes)}`
    : "Schedule unannounced";
  return [
    h(
      "div",
      { class: "public-card-header event-summary-header" },
      h(
        "div",
        { class: "public-card-title-group" },
        h("span", {
          class: "section-icon member-event-icon",
          "aria-hidden": "true",
        }, icon("trophy")),
        h(
          "div",
          { class: "public-card-title-copy" },
          h("span", { class: "eyebrow" }, "Club Event"),
          h("h2", { class: "public-card-title" }, event.name),
        ),
      ),
      h(
        "div",
        { class: "public-card-status" },
        badge(label, tone),
        h("div", { class: "public-card-rating-status" },
          event.apply_cpc_rank_changes ? badge(cpc, "info") : null,
          badge(dupr, event.dupr_rated ? "success" : "neutral"),
        ),
      ),
    ),
    h(
      "dl",
      { class: "public-event-meta" },
      detail(
        "Schedule",
        event.starts_on === event.ends_on
          ? day(event.starts_on)
          : `${day(event.starts_on)} – ${day(event.ends_on)}`,
        "calendar",
      ),
      detail("Registration Window", window, "clock", "public-meta-span2"),
      detail(
        "Entry Fee",
        Number(event.fee) > 0 ? formatMoney(event.fee) : "Free",
        "currency",
        "public-meta-entry-fee",
      ),
      detail(
        "Divisions",
        `${count} ${count === 1 ? "Division" : "Divisions"}`,
        "layers",
      ),
      detail(
        "Format Template",
        formatTemplateLabel(
          event.default_format_template_name || "Standard Format",
        ),
        "copy",
      ),
      detail(
        "Venue",
        event.location || "To Be Announced",
        "grid",
        "public-meta-span2",
      ),
    ),
  ];
}

const GENDER_LABEL = { male: "Men", female: "Women", mixed: "Mixed" };

// Public division cards: type, who may enter, and entries taken against the limit (counts only).
// "View Bracketing": a link once the division is drawn, otherwise the same card shown disabled.
function bracketLink(info) {
  const open = Boolean(info.drawn || info.finished);
  const body = [
    h("span", { class: "public-roster-avatar public-roster-bracket-icon", "aria-hidden": "true" }, icon("trophy")),
    h(
      "span",
      { class: "public-roster-text" },
      h("strong", { class: "public-roster-team-name" }, info.finished ? "View Final Results" : "View Bracketing"),
      h(
        "span",
        { class: "sub public-roster-players" },
        info.finished ? "Final Standings & Champion" : open ? "Official Draw & Match Schedule" : "Available once the draw is made",
      ),
    ),
    h("span", { class: "public-roster-index public-roster-bracket-arrow", "aria-hidden": "true" }, icon("chevr")),
  ];
  return open
    ? h("a", { class: "btn btn-secondary public-roster-bracket", href: `#/bracketing?division=${encodeURIComponent(info.divisionId)}&tab=matches` }, ...body)
    : h("span", { class: "btn btn-secondary public-roster-bracket is-disabled", role: "link", "aria-disabled": "true" }, ...body);
}

// rosterFor(division) -> { teams: [{ team, players: [{ name, photo }] }], divisionId, drawn } (optional): shown under each
// card as the official roster, photo first, then the team name with the players' names as the subtext. Once the division
// is drawn, a button below the roster opens its bracket.
function officialRoster(info) {
  if (info?.finished && info.divisionId) {
    return h("div", { class: "public-division-roster is-finished" }, bracketLink(info));
  }
  const teams = info?.teams;
  if (!teams?.length) return null;
  const isDoubles = teams.some((t) => t.team || (t.players?.length ?? 0) > 1);
  const unit = isDoubles
    ? (teams.length === 1 ? "Team" : "Teams")
    : (teams.length === 1 ? "Player" : "Players");
  const matchRows = new Map();
  const highlightPair = (matchNo, highlighted) => {
    for (const row of matchRows.get(matchNo) ?? []) {
      row.classList.toggle("is-match-highlighted", highlighted);
    }
  };
  return h(
    "div",
    { class: "public-division-roster" },
    h(
      "div",
      { class: "public-division-roster-head" },
      h(
        "span",
        { class: "public-division-roster-title" },
        h("span", { class: "public-division-roster-icon", "aria-hidden": "true" }, icon("users")),
        "Official Roster",
      ),
      h("span", { class: "public-division-roster-count" }, `${teams.length} ${unit}`),
    ),
    h(
      "ul",
      { class: "public-roster-list", "aria-label": "Official roster" },
      ...teams.map((t, idx) => {
        const row = h(
          "li",
          {
            class: `public-roster-team${t.matchNo ? ` match-tone-${((t.matchNo - 1) % 8) + 1}` : ""}`,
            tabindex: t.matchNo ? 0 : null,
            onPointerEnter: () => highlightPair(t.matchNo, true),
            onPointerLeave: () => highlightPair(t.matchNo, false),
            onFocus: () => highlightPair(t.matchNo, true),
            onBlur: () => highlightPair(t.matchNo, false),
          },
          h(
            "span",
            { class: "public-roster-index", "aria-hidden": "true" },
            h("span", { class: "public-roster-glyph" }, String(idx + 1).padStart(2, "0")),
          ),
          h(
            "span",
            { class: "public-roster-photos", "aria-hidden": "true" },
            ...t.players.map((p) => h("span", { class: "member-avatar public-roster-avatar" },
              h("span", { class: "public-roster-glyph" }, avatarImage(p.photo, p.name)))),
          ),
          h(
            "span",
            { class: "public-roster-text" },
            h("span", { class: "public-roster-name-row" },
              t.matchNo ? h("span", { class: "public-roster-match", title: `Match ${t.matchNo}` },
                h("span", { class: "public-roster-glyph" }, String(t.matchNo).padStart(2, "0"))) : null,
              h("strong", { class: "public-roster-team-name" }, t.team ?? t.players[0]?.name ?? "—"),
            ),
            t.team ? h("span", { class: "sub public-roster-players" }, t.players.map((p) => p.name).join(" · ")) : null,
          ),
        );
        if (t.matchNo) {
          if (!matchRows.has(t.matchNo)) matchRows.set(t.matchNo, []);
          matchRows.get(t.matchNo).push(row);
        }
        return row;
      }),
    ),
    info.divisionId ? bracketLink(info) : null,
  );
}

export function eventDivisions(divisions = [], rosterFor = null) {
  if (!divisions.length) return null;
  return h(
    "section",
    { class: "public-event-divisions", "aria-label": "Divisions" },
    h(
      "h3",
      { class: "public-event-divisions-title" },
      icon("layers"),
      "Divisions",
    ),
    h(
      "ul",
      { class: "public-division-grid" },
      ...divisions.map((d) => {
        const taken = Number(d.taken ?? 0);
        const max = Number(d.max_entries ?? 0);
        const full = max > 0 && taken >= max;
        const ranks = d.min_rank && d.max_rank
          ? d.min_rank === d.max_rank
            ? `Rank ${d.min_rank}`
            : `Ranks ${d.min_rank} – ${d.max_rank}`
          : d.min_rank
          ? `Rank ${d.min_rank} and Up`
          : d.max_rank
          ? `Up to Rank ${d.max_rank}`
          : null;
        return h(
          "li",
          { class: "public-division-card" },
          h(
            "div",
            { class: "public-division-header" },
            h(
              "div",
              { class: "public-division-head" },
              h(
                "div",
                { class: "public-division-copy" },
                h("strong", { class: "public-division-name" }, d.name),
                h(
                  "span",
                  { class: "sub" },
                  [
                    d.format === "doubles" ? "Doubles" : "Singles",
                    GENDER_LABEL[d.gender],
                  ].filter(Boolean).join(" · "),
                ),
              ),
              full ? badge("Full", "warning") : badge("Open", "success"),
            ),
            h(
              "div",
              { class: "public-division-who" },
              icon("user"),
              h(
                "span",
                {},
                [d.category, ranks, d.age_group].filter(Boolean).join(" · ") ||
                  "All Members",
              ),
            ),
            h(
              "div",
              { class: "public-division-entries" },
              h("span", { class: "sub" }, "Registered"),
              h(
                "strong",
                {},
                max > 0 ? `${taken} / ${max}` : `${taken} · No Limit`,
              ),
            ),
            max > 0
              ? h("progress", {
                class: "member-event-capacity public-division-capacity",
                value: Math.min(taken, max),
                max,
                "aria-label":
                  `${taken} of ${max} entries registered for ${d.name}`,
              })
              : null,
          ),
          officialRoster(rosterFor?.(d)),
        );
      }),
    ),
  );
}

export function eventSummarySkeleton() {
  const sk = (shape = "w-70") => h("span", { class: `sk ${shape}` });
  return [
    h(
      "div",
      { class: "public-card-header event-summary-header" },
      h(
        "div",
        { class: "public-card-title-group" },
        h("span", {
          class: "sk section-icon member-event-icon",
          style: "border-radius: var(--r-control);",
        }),
        h(
          "div",
          { class: "public-card-title-copy", style: "flex: 1;" },
          sk("w-30 sk-sub public-card-eyebrow-skeleton"),
          sk("w-70 public-card-title-skeleton"),
        ),
      ),
      h(
        "div",
        { class: "public-card-status" },
        h("span", { class: "sk sk-pill", style: "width: 110px; height: 24px;" }),
        h("div", { class: "public-card-rating-status" },
          h("span", { class: "sk sk-pill", style: "width: 85px; height: 24px;" }),
          h("span", { class: "sk sk-pill", style: "width: 95px; height: 24px;" }),
        ),
      ),
    ),
    h(
      "dl",
      { class: "public-event-meta" },
      ...Array.from({ length: 6 }, (_, i) =>
        h(
          "div",
          { class: i === 1 || i === 5 ? "public-meta-span2" : "" },
          h("dt", {}, sk("w-40 sk-sub")),
          h("dd", {}, sk("w-70")),
        )),
    ),
  ];
}
