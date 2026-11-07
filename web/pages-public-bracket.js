// Public bracketing page: opened from "View Bracketing" / "View Final Results" on a public event card (#/bracketing?division=<id>).
// Read only and open to visitors. Two tabs: Standings (champions, final placements, league tables) and Matches (every round,
// with scores). It refreshes by itself while the page is open so a result shows up without reloading.
import { attachPagePattern, badge, button, emptyState, h, icon, memberHero, tableFilter } from "./ui.js";
import { createFinalResultsView, finalResultsSkeleton } from "./lib/final-results.js";
import { createBracketViews, splitBracketSkeleton } from "./lib/bracket-views.js";
import { signedAvatarUrls } from "./lib/avatar.js";

const MATCH_STATUS = {
  scheduled: ["Scheduled", "neutral"],
  in_progress: ["In Progress", "info"],
  completed: ["Final", "success"],
  forfeited: ["Forfeit", "warning"],
};

function roundName(round, total) {
  const fromEnd = total - round;
  if (fromEnd === 0) return "Final";
  if (fromEnd === 1) return "Semifinals";
  if (fromEnd === 2) return "Quarterfinals";
  return `Round ${round}`;
}

const sectionTitle = (g, stageType) =>
  g.group === "H" ? "H Bracket"
  : g.group === "L" ? "L Bracket"
  : g.group ? `Bracket ${g.group}`
  : stageType === "split_single_elimination" ? "Round 1"
  : stageType === "single_elimination" ? "Bracket"
  : "Matches";

export function createPublicBracketPages({ api, client = api?.client }) {
  function publicBracketPage() {
    const params = new URLSearchParams(location.hash.split("?")[1] ?? "");
    const divisionId = params.get("division") ?? "";
    const page = h("div", { class: "page bracket-page public-bracket-page" });
    attachPagePattern(page);
    const state = { tab: "standings", info: null, teamPhotos: new Map(), playerPhotos: new Map(), status: "loading" };
    if (["matches", "standings"].includes(params.get("tab"))) {
      // A link may open a tab (&tab=matches) once; the address is then cleaned so that a refresh starts on Standings.
      state.tab = params.get("tab");
      try {
        history.replaceState(null, "", `#/bracketing?division=${encodeURIComponent(divisionId)}`);
      } catch {
        // the tab still opens; only the address keeps the parameter
      }
    }
    const heroHost = h("div", {});
    const filterHost = h("div", { class: "member-status-filter" });
    const body = h("div", { class: "public-bracket-body", "aria-live": "polite" });
    let signature = "";
    let timer = null;

    async function load(silent = false) {
      if (!silent) {
        state.status = "loading";
        draw();
      }
      try {
        const [info, rosters] = await Promise.all([
          api.rpc("public_division_bracket", { p_division_id: divisionId }),
          Promise.resolve(api.rpc("public_event_rosters")).catch(() => []),
        ]);
        const next = JSON.stringify(info);
        if (silent && next === signature) return;
        signature = next;
        state.info = info;

        // Build player photos map from rosters
        let divRosters = (rosters ?? []).filter((r) => !divisionId || !r.division_id || r.division_id === divisionId);
        if (!divRosters.length && (rosters ?? []).length) divRosters = rosters;
        const paths = divRosters.flatMap((r) => [r.p1_path, r.p2_path]).filter(Boolean);
        const photoUrls = client ? await signedAvatarUrls(client, paths) : new Map();
        const teamPhotos = new Map();
        const playerPhotos = new Map();
        for (const r of divRosters) {
          const players = [];
          if (r.p1_name) {
            const photo = photoUrls.get(r.p1_path) ?? null;
            players.push({ name: r.p1_name, photo });
            playerPhotos.set(String(r.p1_name).trim().toUpperCase(), photo);
          }
          if (r.p2_name) {
            const photo = photoUrls.get(r.p2_path) ?? null;
            players.push({ name: r.p2_name, photo });
            playerPhotos.set(String(r.p2_name).trim().toUpperCase(), photo);
          }
          if (r.team_name) teamPhotos.set(String(r.team_name).trim().toUpperCase(), players);
          const fullKey = players.map((p) => p.name).join(" & ").toUpperCase();
          if (fullKey) teamPhotos.set(fullKey, players);
        }
        state.teamPhotos = teamPhotos;
        state.playerPhotos = playerPhotos;
        state.status = info ? "ready" : "missing";
      } catch {
        if (silent) return;
        state.status = "error";
      }
      draw();
    }

    const slot = (m, side) => {
      const name = side === "a" ? m.a_name : m.b_name;
      const players = side === "a" ? m.a_players : m.b_players;
      const label = side === "a" ? m.a_label : m.b_label;
      const win = m.winner === side;
      const loss = m.winner && m.winner !== side;
      const points = (m.games ?? []).map((g) => (side === "a" ? g.a : g.b));
      return h(
        "div",
        { class: `bt-slot${name ? "" : " is-empty"}${win ? " is-winner" : ""}${loss ? " is-loser" : ""}` },
        h(
          "span",
          { class: "bt-slot-name", title: name ?? label ?? "" },
          name ?? label ?? "To be decided",
          name && players && players !== name ? h("span", { class: "sub public-bracket-players" }, players) : null,
        ),
        win ? h("span", { class: "bt-result bt-result-w", "aria-label": "Winner" }, "W") : null,
        loss ? h("span", { class: "bt-result bt-result-l", "aria-label": "Eliminated" }, "L") : null,
        win || loss ? (points.length ? h("span", { class: "bt-points" }, points.join(" · ")) : null) : null,
      );
    };

    const matchCard = (m) =>
      h(
        "article",
        { class: `bt-node${m.winner ? " is-complete" : ""}` },
        h(
          "div",
          { class: "bt-node-head" },
          h("span", { class: "bt-code" }, `Match ${m.match_no > 100 ? m.match_no - 100 : m.match_no}`),
          badge(...(MATCH_STATUS[m.status] ?? [m.status, "neutral"])),
        ),
        slot(m, "a"),
        slot(m, "b"),
      );

    // The same drawings as the staff Bracket page (Round 1 pair cards, H / L trees, champion), read only.
    const asRow = (m) => ({
      ...m,
      match_id: `${m.stage_no}-${m.group_label ?? ""}-${m.round_no}-${m.match_no}`,
      entry_a_id: m.a_name ? "a" : null,
      entry_b_id: m.b_name ? "b" : null,
      winner_entry_id: m.winner ? m.winner : null,
    });

    function matchesView(info) {
      const stageType = new Map((info.stages ?? []).map((s) => [s.stage_no, s.stage_type]));
      const drawn = [];
      const plain = { ...info, matches: [] };
      for (const st of info.stages ?? []) {
        const rows = (info.matches ?? []).filter((m) => m.stage_no === st.stage_no).map(asRow);
        if (!rows.length) continue;
        if (st.stage_type === "split_single_elimination" || st.stage_type === "single_elimination") {
          const views = createBracketViews({ getMatches: () => rows, getDivisionName: () => info.division_name });
          drawn.push(st.stage_type === "split_single_elimination"
            ? views.splitView()
            : h("div", { class: "bt-stack" }, views.bracketTree(rows, "Bracket", "gold")));
        } else {
          plain.matches.push(...rows);
        }
      }
      if (drawn.length) {
        return h("div", { class: "bt-stack" }, ...drawn, plain.matches.length ? matchesList(plain, stageType) : null);
      }
      return matchesList(info, stageType);
    }

    // Round robin and pool play: the matches of each group, round by round.
    function matchesList(info, stageType) {
      const sections = new Map();
      for (const m of info.matches ?? []) {
        const key = `${m.stage_no}|${m.group_label ?? ""}`;
        if (!sections.has(key)) sections.set(key, { stage: m.stage_no, group: m.group_label, rows: [] });
        sections.get(key).rows.push(m);
      }
      if (!sections.size) {
        return emptyState({ icon: "trophy", title: "No matches yet", description: "Matches appear once the draw is made." });
      }
      return h(
        "div",
        { class: "bt-stack" },
        ...[...sections.values()].map((g) => {
          const type = stageType.get(g.stage);
          const rounds = [...new Set(g.rows.map((m) => m.round_no))].sort((a, b) => a - b);
          const knockout = g.group === "H" || g.group === "L" || type === "single_elimination";
          return h(
            "section",
            { class: `bt-panel ${g.group === "H" ? "bt-high" : g.group === "L" ? "bt-low" : "bt-gold"}`, "aria-label": sectionTitle(g, type) },
            h(
              "div",
              { class: "bt-panel-head" },
              h("div", { class: "bt-panel-title" }, h("span", { class: "bt-panel-icon", "aria-hidden": "true" }, icon("trophy")), h("h3", {}, sectionTitle(g, type))),
            ),
            h(
              "div",
              { class: "bt-scroller" },
              h(
                "div",
                { class: "bt-tree" },
                ...rounds.map((r, i) =>
                  h(
                    "div",
                    { class: "bt-round" },
                    h(
                      "div",
                      { class: "bt-round-head" },
                      h("span", { class: "bt-pill" }, knockout ? roundName(i + 1, rounds.length) : `Round ${r}`),
                    ),
                    h(
                      "div",
                      { class: "bt-round-matches" },
                      ...g.rows.filter((m) => m.round_no === r).sort((a, b) => a.match_no - b.match_no).map(matchCard),
                    ),
                  )
                ),
              ),
            ),
          );
        }),
      );
    }

    function playersFor(teamName, playersStr) {
      if (teamName) {
        const found = state.teamPhotos.get(String(teamName).trim().toUpperCase());
        if (found && found.length) return found;
      }
      if (playersStr) {
        const found = state.teamPhotos.get(String(playersStr).trim().toUpperCase());
        if (found && found.length) return found;
        const names = playersStr.split(/\s*(?:&|,)\s*/).map((s) => s.trim()).filter(Boolean);
        if (names.length) {
          return names.map((name) => ({
            name,
            photo: state.playerPhotos?.get(name.toUpperCase()) ?? null,
          }));
        }
      }
      if (teamName) {
        return [{ name: teamName, photo: null }];
      }
      return [];
    }

    const standingsView = createFinalResultsView({ playersFor });

    function draw() {
      const info = state.info;
      heroHost.replaceChildren(
        memberHero({
          iconName: "trophy",
          eyebrow: info?.event_name ?? "Club Event",
          title: info?.division_name ?? "Division",
          publicHeader: true,
          chip: info?.finished ? "Final Results" : "Bracketing",
          description: info?.finished
            ? "Final standings, the champion and every match."
            : "The official draw and match results, updated as games finish.",
          actions: [
            button({ label: "Back to Events", variant: "secondary", icon: "chevronLeft", onClick: () => (location.hash = "#/events") }),
          ],
        }),
      );
      filterHost.replaceChildren(
        state.status === "ready"
          ? tableFilter({
            activeId: state.tab,
            tabs: [
              { id: "standings", label: "Standings", badge: info.finished ? (info.placements?.length || info.standings?.length || 0) : 0 },
              { id: "matches", label: "Matches", badge: (info.matches ?? []).length },
            ],
            onChange: (id) => {
              state.tab = id;
              draw();
            },
          })
          : "",
      );
      if (state.status === "loading") {
        body.replaceChildren(
          state.tab === "matches" ? splitBracketSkeleton() : finalResultsSkeleton({ split: true }),
        );
      } else if (state.status === "error") {
        body.replaceChildren(emptyState({ icon: "alert", title: "Could not load this division", description: "Check your connection and try again.", resetLabel: "Try Again", onReset: () => load() }));
      } else if (state.status === "missing") {
        body.replaceChildren(emptyState({ icon: "trophy", title: "Bracketing is not available", description: "This division has not been drawn yet, or it is not public." }));
      } else {
        // Standings stay empty until the division is finalized; only Matches show live results.
        body.replaceChildren(state.tab === "matches" ? matchesView(info) : standingsView(info.finished ? info : { ...info, placements: [], standings: [] }));
      }
    }

    page.append(heroHost, filterHost, body);
    load();
    timer = setInterval(() => {
      if (!page.isConnected) {
        clearInterval(timer);
        return;
      }
      if (document.visibilityState === "visible") load(true);
    }, 20000);
    return page;
  }

  return { publicBracketPage };
}
