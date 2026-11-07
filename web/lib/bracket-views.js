// The bracket drawings shared by the staff Bracket page and the public bracketing page: Round 1 pair cards, the connected
// H / L knockout trees and the champion card. Pure drawing: the caller supplies the matches, and (for staff) makes a card clickable.
import { badge, h, icon } from "../ui.js";

export const MATCH_STATUS = {
  scheduled: ["Scheduled", "neutral"],
  in_progress: ["In Progress", "info"],
  completed: ["Final", "success"],
  forfeited: ["Forfeit", "warning"],
  cancelled: ["Cancelled", "neutral"],
};

export function roundName(round, total) {
  const fromEnd = total - round;
  if (fromEnd === 0) return "Final";
  if (fromEnd === 1) return "Semifinals";
  if (fromEnd === 2) return "Quarterfinals";
  return `Round of ${2 ** (fromEnd + 1)}`;
}

/**
 * getMatches() -> rows { round_no, match_no, group_label, status, entry_a_id, entry_b_id, winner_entry_id, a_name, b_name,
 * a_players, b_players, a_label, b_label, games: [{a, b}] }.  clickable(card, match) may add behaviour to a match card.
 */
export function createBracketViews({ getMatches, getDivisionName = () => null, getPlayers = () => null, clickable = (card) => card }) {
  const SVG_NS = "http://www.w3.org/2000/svg";
  const done = (m) => ["completed", "forfeited"].includes(m.status) && m.winner_entry_id;

  /** The points this side scored in each game, shown after the team name. */
  const sideScore = (m, side) => {
    const points = (m.games ?? []).map((g) => (side === "a" ? g.a : g.b));
    return points.length
      ? h("span", { class: "bt-points", "aria-label": `Score ${points.join(", ")}` }, points.join(" · "))
      : null;
  };

  function slot(m, side, { showPlayers = false } = {}) {
    const id = side === "a" ? m.entry_a_id : m.entry_b_id;
    const name = side === "a" ? m.a_name : m.b_name;
    const label = side === "a" ? m.a_label : m.b_label;
    const win = done(m) && id && m.winner_entry_id === id;
    const loss = done(m) && id && !win;
    const players = showPlayers && name
      ? (side === "a" ? m.a_players : m.b_players) ?? getPlayers(name) ?? null
      : null;
    if (showPlayers) {
      return h(
        "div",
        { class: `bt-slot is-detailed${name ? "" : " is-empty"}${win ? " is-winner" : ""}${loss ? " is-loser" : ""}` },
        h(
          "div",
          { class: "bt-slot-top" },
          win ? h("span", { class: "bt-result bt-result-w", "aria-label": "Winner" }, "W") : null,
          loss ? h("span", { class: "bt-result bt-result-l", "aria-label": "Eliminated" }, "L") : null,
          h("span", { class: "bt-slot-name", title: name ?? label ?? "" }, name ?? label ?? "To be decided"),
          win || loss ? sideScore(m, side) : null,
        ),
        players ? h("span", { class: "sub bt-slot-players" }, players) : null,
      );
    }
    return h(
      "div",
      { class: `bt-slot${name ? "" : " is-empty"}${win ? " is-winner" : ""}${loss ? " is-loser" : ""}` },
      win ? h("span", { class: "bt-result bt-result-w", "aria-label": "Winner" }, "W") : null,
      loss ? h("span", { class: "bt-result bt-result-l", "aria-label": "Eliminated" }, "L") : null,
      h("span", { class: "bt-slot-name", title: name ?? label ?? "" }, name ?? label ?? "To be decided"),
      win || loss ? sideScore(m, side) : null,
    );
  }

  // Each side shows outcome, team name and score without a separate score line.
  const matchFoot = () => null;


  /** Round 1 of a split bracket: a pair card with the two sides facing each other. */
  function pairCard(m) {
    return clickable(h(
      "article",
      { class: `bt-pair${done(m) ? " is-complete" : ""}` },
      h(
        "div",
        { class: "bt-index", "aria-label": `Match ${m.round_no}.${m.match_no}` },
        h("span", {}, "M"),
        String(m.match_no).padStart(2, "0"),
      ),
      slot(m, "a", { showPlayers: true }),
      h("span", { class: "bt-vs", "aria-hidden": "true" }, "VS"),
      slot(m, "b", { showPlayers: true }),
      matchFoot(m),
    ), m);
  }

  function treeMatch(m) {
    return clickable(h(
      "article",
      { class: `bt-node${done(m) ? " is-complete" : ""}` },
      h(
        "div",
        { class: "bt-node-head" },
        h("span", { class: "bt-code" }, `Match ${m.match_no > 100 ? m.match_no - 100 : m.match_no}`),
        badge(...(MATCH_STATUS[m.status] ?? [m.status, "neutral"])),
      ),
      slot(m, "a"),
      slot(m, "b"),
      matchFoot(m),
    ), m);
  }

  function connectorSvg(single) {
    const svg = document.createElementNS(SVG_NS, "svg");
    svg.setAttribute("viewBox", "0 0 36 100");
    svg.setAttribute("preserveAspectRatio", "none");
    svg.setAttribute("class", "bt-svg");
    const path = document.createElementNS(SVG_NS, "path");
    path.setAttribute("d", single ? "M 0 50 H 36" : "M 0 25 H 18 V 75 H 0 M 18 50 H 36");
    path.setAttribute("fill", "none");
    path.setAttribute("stroke-linecap", "round");
    path.setAttribute("stroke-linejoin", "round");
    svg.append(path);
    return svg;
  }

  const connectorCol = (cells, single) =>
    h(
      "div",
      { class: "bt-connector", "aria-hidden": "true" },
      h("div", { class: "bt-spacer" }),
      h("div", { class: "bt-connector-body" }, ...Array.from({ length: cells }, () => h("div", { class: "bt-connector-cell" }, connectorSvg(single)))),
    );

  /** Connected knockout tree: a column per round, connectors between rounds, the champion at the end. */
  function bracketTree(rows, title, tone, teamCount) {
    const rs = [...new Set(rows.map((m) => m.round_no))].sort((a, b) => a - b);
    const columns = rs.map((r) => rows.filter((m) => m.round_no === r).sort((a, b) => a.match_no - b.match_no));
    // Later rounds say where each side comes from until it is known ("Winner of Quarterfinals 1").
    columns.forEach((col, i) => {
      if (!i) return;
      col.forEach((m, idx) => {
        const from = (side) => `Winner of ${roundName(i, rs.length)} ${idx * 2 + side}`;
        if (!m.a_label) m.a_label = from(1);
        if (!m.b_label) m.b_label = from(2);
      });
    });
    const last = columns.at(-1)?.[0];
    const champion = last && done(last) ? (last.winner_entry_id === last.entry_a_id ? last.a_name : last.b_name) : null;
    const parts = [];
    columns.forEach((col, i) => {
      parts.push(h(
        "div",
        { class: `bt-round bt-round-${rs.length - i === 1 ? "final" : rs.length - i === 2 ? "semifinal" : rs.length - i === 3 ? "quarterfinal" : "early"}` },
        h("div", { class: "bt-round-head" }, h("span", { class: "bt-pill" }, roundName(i + 1, rs.length))),
        h("div", { class: "bt-round-matches" }, ...col.map(treeMatch)),
      ));
      const next = columns[i + 1];
      if (next) parts.push(connectorCol(next.length, false));
    });
    parts.push(connectorCol(1, true));
    parts.push(h(
      "div",
      { class: "bt-round bt-round-champion" },
      h("div", { class: "bt-round-head" }, h("span", { class: "bt-pill is-champion-pill" }, "Champion")),
      h(
        "div",
        { class: "bt-round-matches" },
        h(
          "div",
          { class: `bt-champion${champion ? " is-crowned" : ""}` },
          h("span", { class: "bt-champion-medal", "aria-hidden": "true" }, icon("trophy")),
          h("span", { class: "bt-champion-eyebrow" }, "Championship"),
          h("strong", {}, `${title} Champion`),
          h("span", { class: `sub bt-champion-name${champion ? " is-decided" : ""}` }, champion ?? "To be decided"),
        ),
      ),
    ));
    return h(
      "section",
      { class: `bt-panel bt-${tone}`, "aria-label": title },
      h(
        "div",
        { class: "bt-panel-head" },
        h(
          "div",
          { class: "bt-panel-title" },
          h("span", { class: "bt-panel-icon", "aria-hidden": "true" }, icon(tone === "low" ? "medal" : "trophy")),
          h("h3", {}, title),
        ),
        h(
          "div",
          { class: "bt-tags" },
          teamCount ? h("span", { class: "bt-tag" }, `${teamCount} Teams`) : null,
          h("span", { class: "bt-tag" }, "Single Elimination"),
        ),
      ),
      h("div", { class: "bt-scroller" }, h("div", { class: "bt-tree" }, ...parts)),
    );
  }

  function splitView() {
    const part = (label) => getMatches().filter((m) => m.group_label === label);
    const first = getMatches().filter((m) => !m.group_label).sort((a, b) => a.match_no - b.match_no);
    const teams = (rows) => {
      const r1 = Math.min(...rows.map((m) => m.round_no));
      return rows.filter((m) => m.round_no === r1).length * 2;
    };
    // The database builds the H and L matches only when every Round 1 match is finished; until then the trees are
    // shown empty, with the slots named after the Round 1 match they will be filled from.
    const planned = (prefix) => {
      const rows = [];
      let count = Math.floor(first.length / 2);
      let round = 1;
      while (count >= 1) {
        for (let i = 1; i <= count; i++) {
          const from = (side) =>
            round === 1
              ? `${prefix === "H" ? "Winner" : "Loser"} of Match ${(i - 1) * 2 + side}`
              : `Winner of ${roundName(round - 1, Math.log2(first.length))} ${(i - 1) * 2 + side}`;
          rows.push({
            match_id: `plan-${prefix}-${round}-${i}`,
            round_no: round,
            match_no: i,
            group_label: prefix,
            status: "scheduled",
            a_name: null,
            b_name: null,
            a_label: from(1),
            b_label: from(2),
            games: [],
          });
        }
        count = Math.floor(count / 2);
        round += 1;
      }
      return rows;
    };
    const waiting = !part("H").length && !part("L").length && first.length >= 2;
    const hRows = waiting ? planned("H") : part("H");
    const lRows = waiting ? planned("L") : part("L");
    const rulesCard = (tone, iconName, title, items) =>
      h(
        "section",
        { class: `bt-rules-card is-${tone}`, "aria-label": title },
        h(
          "div",
          { class: "bt-rules-head" },
          h("span", { class: "bt-rules-icon", "aria-hidden": "true" }, icon(iconName)),
          h("h4", {}, title),
        ),
        h(
          "ol",
          { class: "bt-rules-list" },
          ...items.map((text, idx) =>
            h(
              "li",
              { class: "bt-rules-item" },
              h("span", { class: "bt-rules-num", "aria-hidden": "true" }, `${idx + 1}.`),
              h("span", {}, text),
            )
          ),
        ),
      );
    return h(
      "div",
      { class: "bt-layout" },
      first.length
        ? h(
          "div",
          { class: "bt-left-col" },
          h(
            "aside",
            { class: "bt-initial", "aria-label": "Round 1" },
            h(
              "div",
              { class: "bt-initial-head" },
              h(
                "div",
                { class: "bt-initial-head-top" },
                h(
                  "div",
                  { class: "bt-initial-badges" },
                  h("span", { class: "bt-initial-icon", "aria-hidden": "true" }, icon("layers")),
                  h("span", { class: "bt-stage-tag" }, "Round 1"),
                  h("span", { class: "bt-initial-kicker" }, "Initial Stage"),
                ),
                h("span", { class: "bt-initial-pill" }, `${first.length} Matches`),
              ),
              h("h3", { class: "bt-initial-division" }, getDivisionName() ?? "Division"),
              h(
                "div",
                { class: "bt-initial-chips" },
                h(
                  "div",
                  { class: "bt-initial-chip" },
                  h("span", { class: "bt-initial-chip-icon", "aria-hidden": "true" }, icon("users")),
                  h(
                    "div",
                    { class: "bt-initial-chip-text" },
                    h("strong", {}, `${first.length * 2} Teams`),
                    h("span", { class: "sub" }, "Initial Round"),
                  ),
                ),
                h(
                  "div",
                  { class: "bt-initial-chip" },
                  h("span", { class: "bt-initial-chip-icon", "aria-hidden": "true" }, icon("grid")),
                  h(
                    "div",
                    { class: "bt-initial-chip-text" },
                    h("strong", {}, `${first.length} Matches`),
                    h("span", { class: "sub" }, "Classification"),
                  ),
                ),
              ),
            ),
            h("div", { class: "bt-pairs" }, ...first.map(pairCard)),
            h(
              "div",
              { class: "bt-advance" },
              h(
                "div",
                { class: "bt-advance-box is-h" },
                h("span", {}, "H Pathway"),
                h("strong", {}, `${first.length} Winners Advance`),
              ),
              h(
                "div",
                { class: "bt-advance-box is-l" },
                h("span", {}, "L Pathway"),
                h("strong", {}, `${first.length} Losers Advance`),
              ),
            ),
          ),
          rulesCard("h", "trophy", "H Bracket Rules", [
            `${first.length} winning teams from the initial round advance here.`,
            "Single elimination knockout format.",
            "Champion will receive a prestigious official award.",
            "H Champion will not play against L Champion.",
          ]),
          rulesCard("l", "medal", "L Bracket Rules", [
            `${first.length} losing teams from the initial round advance here.`,
            "Single elimination knockout format.",
            "Champion will receive a distinct recognition award.",
            "L Champion will not play against H Champion.",
          ]),
        )
        : null,
      h(
        "div",
        { class: "bt-brackets" },
        waiting
          ? h(
            "div",
            { class: "bt-waiting" },
            h("span", { class: "bt-waiting-icon", "aria-hidden": "true" }, icon("info")),
            h("p", { class: "sub" }, "The H and L brackets are built automatically once every Round 1 match is final."),
          )
          : null,
        hRows.length ? bracketTree(hRows, "H Bracket", "high", teams(hRows)) : null,
        lRows.length ? bracketTree(lRows, "L Bracket", "low", teams(lRows)) : null,
      ),
    );
  }


  return { done, slot, pairCard, treeMatch, bracketTree, splitView };
}

export function bracketTreeSkeleton(_title = "Bracket", tone = "gold") {
  const SVG_NS = "http://www.w3.org/2000/svg";
  const connectorSvg = (single) => {
    const svg = document.createElementNS(SVG_NS, "svg");
    svg.setAttribute("viewBox", "0 0 36 100");
    svg.setAttribute("preserveAspectRatio", "none");
    svg.setAttribute("class", "bt-svg");
    const path = document.createElementNS(SVG_NS, "path");
    path.setAttribute("d", single ? "M 0 50 H 36" : "M 0 25 H 18 V 75 H 0 M 18 50 H 36");
    path.setAttribute("fill", "none");
    path.setAttribute("stroke-linecap", "round");
    path.setAttribute("stroke-linejoin", "round");
    svg.append(path);
    return svg;
  };
  const connectorCol = (cells, single) =>
    h(
      "div",
      { class: "bt-connector", "aria-hidden": "true" },
      h("div", { class: "bt-spacer" }),
      h(
        "div",
        { class: "bt-connector-body" },
        ...Array.from({ length: cells }, () => h("div", { class: "bt-connector-cell" }, connectorSvg(single))),
      ),
    );
  const nodeSk = (i) =>
    h(
      "article",
      { class: "bt-node is-skeleton", "aria-hidden": "true" },
      h(
        "div",
        { class: "bt-node-head" },
        h("span", { class: "sk bt-sk-node-code" }),
        h("span", { class: "sk sk-pill bt-sk-node-status" }),
      ),
      h(
        "div",
        { class: "bt-slot" },
        h("span", { class: `sk ${i % 2 ? "w-50" : "w-70"}` }),
      ),
      h(
        "div",
        { class: "bt-slot" },
        h("span", { class: `sk ${i % 2 ? "w-70" : "w-50"}` }),
      ),
    );

  return h(
    "section",
    { class: `bt-panel bt-${tone} is-skeleton`, "aria-hidden": "true" },
    h(
      "div",
      { class: "bt-panel-head" },
      h(
        "div",
        { class: "bt-panel-title" },
        h("span", { class: "bt-panel-icon" }, icon(tone === "low" ? "medal" : "trophy")),
        h("span", { class: "sk bt-sk-panel-title" }),
      ),
      h(
        "div",
        { class: "bt-tags" },
        h("span", { class: "sk sk-pill bt-sk-tag" }),
        h("span", { class: "sk sk-pill bt-sk-tag-lg" }),
      ),
    ),
    h(
      "div",
      { class: "bt-scroller" },
      h(
        "div",
        { class: "bt-tree" },
        h(
          "div",
          { class: "bt-round bt-round-quarterfinal" },
          h("div", { class: "bt-round-head" }, h("span", { class: "sk sk-pill bt-sk-round-pill" })),
          h("div", { class: "bt-round-matches" }, nodeSk(0), nodeSk(1), nodeSk(2), nodeSk(3)),
        ),
        connectorCol(2, false),
        h(
          "div",
          { class: "bt-round bt-round-semifinal" },
          h("div", { class: "bt-round-head" }, h("span", { class: "sk sk-pill bt-sk-round-pill" })),
          h("div", { class: "bt-round-matches" }, nodeSk(4), nodeSk(5)),
        ),
        connectorCol(1, false),
        h(
          "div",
          { class: "bt-round bt-round-final" },
          h("div", { class: "bt-round-head" }, h("span", { class: "sk sk-pill bt-sk-round-pill" })),
          h("div", { class: "bt-round-matches" }, nodeSk(6)),
        ),
        connectorCol(1, true),
        h(
          "div",
          { class: "bt-round bt-round-champion" },
          h("div", { class: "bt-round-head" }, h("span", { class: "sk sk-pill bt-sk-round-pill" })),
          h(
            "div",
            { class: "bt-round-matches" },
            h(
              "div",
              { class: "bt-champion is-skeleton" },
              h("span", { class: "bt-champion-medal" }, icon("trophy")),
              h("span", { class: "sk sk-sub bt-sk-champ-kicker" }),
              h("span", { class: "sk bt-sk-champ-title" }),
              h("span", { class: "sk sk-sub bt-sk-champ-sub" }),
            ),
          ),
        ),
      ),
    ),
  );
}

export function splitBracketSkeleton() {
  const pairSk = (i) =>
    h(
      "article",
      { class: "bt-pair is-skeleton", "aria-hidden": "true" },
      h("div", { class: "bt-index" }, h("span", { class: "sk bt-sk-pair-idx" })),
      h(
        "div",
        { class: "bt-slot is-detailed" },
        h("div", { class: "bt-slot-top" }, h("span", { class: `sk ${i % 2 ? "w-50" : "w-70"}` })),
        h("span", { class: "sk sk-sub w-50" }),
      ),
      h("span", { class: "bt-vs", "aria-hidden": "true" }, "VS"),
      h(
        "div",
        { class: "bt-slot is-detailed" },
        h("div", { class: "bt-slot-top" }, h("span", { class: `sk ${i % 2 ? "w-70" : "w-50"}` })),
        h("span", { class: "sk sk-sub w-50" }),
      ),
    );

  return h(
    "div",
    { class: "bt-layout is-skeleton", "aria-busy": "true", "aria-label": "Loading bracket matches" },
    h(
      "div",
      { class: "bt-left-col", "aria-hidden": "true" },
      h(
        "aside",
        { class: "bt-initial" },
        h(
          "div",
          { class: "bt-initial-head" },
          h(
            "div",
            { class: "bt-initial-head-top" },
            h(
              "div",
              { class: "bt-initial-badges" },
              h("span", { class: "bt-initial-icon" }, icon("layers")),
              h("span", { class: "sk sk-pill bt-sk-tag" }),
            ),
            h("span", { class: "sk sk-pill bt-sk-tag" }),
          ),
          h("span", { class: "sk bt-sk-initial-title" }),
          h(
            "div",
            { class: "bt-initial-chips" },
            h(
              "div",
              { class: "bt-initial-chip" },
              h("span", { class: "bt-initial-chip-icon" }, icon("users")),
              h(
                "div",
                { class: "bt-initial-chip-text bt-sk-chip-text" },
                h("span", { class: "sk w-70" }),
                h("span", { class: "sk sk-sub w-50" }),
              ),
            ),
            h(
              "div",
              { class: "bt-initial-chip" },
              h("span", { class: "bt-initial-chip-icon" }, icon("grid")),
              h(
                "div",
                { class: "bt-initial-chip-text bt-sk-chip-text" },
                h("span", { class: "sk w-70" }),
                h("span", { class: "sk sk-sub w-50" }),
              ),
            ),
          ),
        ),
        h("div", { class: "bt-pairs" }, ...Array.from({ length: 6 }, (_, i) => pairSk(i))),
        h(
          "div",
          { class: "bt-advance" },
          h(
            "div",
            { class: "bt-advance-box is-h bt-sk-advance-box" },
            h("span", { class: "sk sk-sub w-50" }),
            h("span", { class: "sk w-70" }),
          ),
          h(
            "div",
            { class: "bt-advance-box is-l bt-sk-advance-box" },
            h("span", { class: "sk sk-sub w-50" }),
            h("span", { class: "sk w-70" }),
          ),
        ),
      ),
    ),
    h(
      "div",
      { class: "bt-brackets", "aria-hidden": "true" },
      bracketTreeSkeleton("H Bracket", "high"),
      bracketTreeSkeleton("L Bracket", "low"),
    ),
  );
}
