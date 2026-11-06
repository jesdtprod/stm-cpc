// Public bracketing page: opened from "View Bracketing" / "View Final Results" on a public event card (#/bracketing?division=<id>).
// Read only and open to visitors. Two tabs: Standings (champions, final placements, league tables) and Matches (every round,
// with scores). It refreshes by itself while the page is open so a result shows up without reloading.
import { attachPagePattern, badge, button, emptyState, h, icon, memberHero, skeleton, tableFilter } from "./ui.js";
import { createBracketViews } from "./lib/bracket-views.js";
import { avatarImage, signedAvatarUrls } from "./lib/avatar.js";

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

    function renderPlayerPhotos(players, extraClass = "") {
      const list = players && players.length ? players : [{ name: "?", photo: null }];
      return h(
        "span",
        { class: `public-roster-photos ${extraClass}`.trim(), "aria-hidden": "true" },
        ...list.map((p) =>
          h(
            "span",
            { class: "member-avatar public-roster-avatar", title: p.name ?? "" },
            h("span", { class: "public-roster-glyph" }, avatarImage(p.photo, p.name || "?")),
          )
        ),
      );
    }

    function achievementPill(r) {
      const tier = r.tier ? String(r.tier).toUpperCase() : "";
      const place = Number(r.place);
      const isChamp = r.result === "won" || (tier === "H" && place === 1) || (!tier && place === 1);

      if (isChamp) {
        return { text: tier ? `${tier} Champion` : "Champion", tone: "gold", icon: "trophy" };
      }
      if (tier === "L" && (r.result === "won" || place === 9)) {
        return { text: "L Champion", tone: "blue", icon: "medal" };
      }
      if (tier === "H" && place === 2) {
        return { text: "Runner-Up", tone: "silver", icon: "medal" };
      }
      if (tier === "L" && place === 10) {
        return { text: "L Runner-Up", tone: "silver-blue", icon: "medal" };
      }
      if (tier === "H" && place === 3) {
        return { text: "Semifinalist", tone: "bronze", icon: null };
      }
      if (tier === "L" && place === 11) {
        return { text: "L Semifinalist", tone: "blue-subtle", icon: null };
      }
      if (tier === "H" && place === 5) {
        return { text: "Quarterfinalist", tone: "subtle", icon: null };
      }
      if (tier === "L" && place === 13) {
        return { text: "L Quarterfinalist", tone: "subtle", icon: null };
      }
      if (place === 2) return { text: "2nd Place", tone: "silver", icon: "medal" };
      if (place === 3) return { text: "3rd Place", tone: "bronze", icon: null };
      return { text: `${tier ? `${tier} · ` : ""}Place ${place}`, tone: "muted", icon: null };
    }

    const teamCell = (r) => {
      const players = playersFor(r.name, r.players);
      return h(
        "div",
        { class: "public-bracket-team-cell" },
        renderPlayerPhotos(players, "is-sm"),
        h(
          "div",
          { class: "public-bracket-team" },
          h("strong", {}, r.name ?? "—"),
          r.players && r.players !== r.name ? h("span", { class: "sub" }, r.players) : null,
        ),
      );
    };

    function table(headers, rows, numericFrom = Infinity) {
      return h(
        "div",
        { class: "public-bracket-table-wrap" },
        h(
          "table",
          { class: "public-bracket-table" },
          h("thead", {}, h("tr", {}, ...headers.map((t, i) => h("th", { class: i >= numericFrom ? "num" : "" }, t)))),
          h("tbody", {}, ...rows.map((cells) => h("tr", {}, ...cells.map((c, i) => h("td", { class: i >= numericFrom ? "num" : "" }, c))))),
        ),
      );
    }

    function standingsView(info) {
      const out = [];
      const places = info.placements ?? [];
      const champions = places.filter((p) => p.result === "won");
      if (champions.length) {
        out.push(h(
          "div",
          { class: "public-bracket-champions" },
          ...champions.map((c) => {
            const players = playersFor(c.name, c.players);
            const isH = c.tier === "H";
            const isL = c.tier === "L";
            const tierClass = isH ? "is-h" : isL ? "is-l" : "is-gold";
            const eyebrowText = c.tier ? `${c.tier} Bracket Champion` : "Champion";
            const iconName = isH ? "trophy" : isL ? "medal" : "trophy";

            return h(
              "div",
              { class: `public-bracket-champion ${tierClass}` },
              h(
                "div",
                { class: "public-champion-head" },
                h("span", { class: "public-champion-badge" }, icon(iconName), eyebrowText),
              ),
              renderPlayerPhotos(players, "is-lg public-champion-photos"),
              h(
                "div",
                { class: "public-champion-meta" },
                h("strong", { class: "public-champion-name" }, c.name ?? "—"),
                c.players && c.players !== c.name
                  ? h("span", { class: "sub public-champion-players" }, c.players)
                  : null,
              ),
            );
          }),
        ));
      }
      const leagues = new Map();
      for (const r of info.standings ?? []) {
        const key = `${r.stage_no}|${r.group_label ?? ""}`;
        if (!leagues.has(key)) leagues.set(key, { group: r.group_label, rows: [] });
        leagues.get(key).rows.push(r);
      }
      for (const lg of leagues.values()) {
        out.push(h(
          "section",
          { class: "public-bracket-section" },
          h("h3", {}, lg.group ? `Bracket ${lg.group}` : "Standings"),
          table(
            ["Place", "Team", "Played", "W", "L", "Points"],
            lg.rows.map((r) => [`${r.place}${r.tied ? " (tied)" : ""}`, teamCell(r), r.played, r.wins, r.losses, `${r.points_for}–${r.points_against}`]),
            2,
          ),
        ));
      }
      if (places.length) {
        out.push(h(
          "section",
          { class: "public-bracket-section public-placements-section" },
          h(
            "div",
            { class: "public-placements-header" },
            h("h3", { class: "public-placements-title" }, "Final Placements"),
            h("span", { class: "public-placements-count" }, `${places.length} Teams`),
          ),
          h(
            "div",
            { class: "public-placements-brackets" },
            ...[...new Set(places.map((r) => r.tier || "Overall"))].map((tier) => h(
              "section",
              { class: `public-placements-bracket is-${tier.toLowerCase()}` },
              h("h4", { class: "public-placements-bracket-title" }, icon("trophy"), tier === "Overall" ? "Overall Standings" : `${tier} Bracket`),
              h("div", { class: "public-placements-list" }, ...places.filter((r) => (r.tier || "Overall") === tier).map((r) => {
              const players = playersFor(r.name, r.players);
              const pill = achievementPill(r);
              const isH = r.tier === "H" || (!r.tier && r.place <= 8);
              const isL = r.tier === "L";
              const placeNum = Number(r.place);
              const isChamp = r.result === "won" || (r.tier === "H" && placeNum === 1) || (r.tier === "L" && placeNum === 9);
              const badgeClass = [
                "public-placement-badge",
                (placeNum === 1 || r.result === "won") ? "is-gold" : "",
                (placeNum === 2 || (isL && placeNum === 10)) ? "is-silver" : "",
                (placeNum === 3 || (isL && placeNum === 11)) ? "is-bronze" : "",
                isH ? "is-tier-h" : "",
                isL ? "is-tier-l" : "",
              ].filter(Boolean).join(" ");

              return h(
                "div",
                { class: `public-placement-row ${isChamp ? "is-champion-row" : ""}`.trim() },
                h(
                  "div",
                  { class: badgeClass },
                  h("span", { class: "public-placement-badge-tier" }, r.tier ? `${r.tier} · ` : ""),
                  h("span", { class: "public-placement-badge-num" }, r.place ?? "—"),
                ),
                renderPlayerPhotos(players, "public-placement-photos"),
                h(
                  "div",
                  { class: "public-placement-info" },
                  h("strong", { class: "public-placement-team" }, r.name ?? "—"),
                  r.players && r.players !== r.name
                    ? h("span", { class: "sub public-placement-players" }, r.players)
                    : null,
                ),
                pill
                  ? h(
                      "div",
                      { class: "public-placement-pill-wrap" },
                      h(
                        "span",
                        { class: `public-placement-pill is-${pill.tone}` },
                        pill.icon ? icon(pill.icon) : null,
                        pill.text,
                      ),
                    )
                  : null,
              );
            })),
            )),
          ),
        ));
      }
      if (!out.length) {
        return emptyState({
          icon: "medal",
          title: "Standings are not ready yet",
          description: "They appear as matches are played, and the champion is shown once the division is finished.",
        });
      }
      return h("div", { class: "bt-stack" }, ...out);
    }

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
              { id: "standings", label: "Standings", badge: (info.placements?.length || info.standings?.length || 0) },
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
        body.replaceChildren(skeleton({ count: 3, variant: "text", height: "96px" }));
      } else if (state.status === "error") {
        body.replaceChildren(emptyState({ icon: "alert", title: "Could not load this division", description: "Check your connection and try again.", resetLabel: "Try Again", onReset: () => load() }));
      } else if (state.status === "missing") {
        body.replaceChildren(emptyState({ icon: "trophy", title: "Bracketing is not available", description: "This division has not been drawn yet, or it is not public." }));
      } else {
        body.replaceChildren(state.tab === "matches" ? matchesView(info) : standingsView(info));
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
