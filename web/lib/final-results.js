import { h, icon, emptyState } from "../ui.js";
import { avatarImage } from "./avatar.js";

// Shared champion cards and placement lists for public and staff results.
export function createFinalResultsView({ playersFor }) {
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
      const isHChamp = (tier === "H" && (r.result === "won" || place === 1)) || (!tier && (r.result === "won" || place === 1));
      const isLChamp = tier === "L" && (r.result === "won" || place === 9);

      if (isHChamp) {
        return {
          text: tier ? `${tier} Champion` : "Champion",
          tone: "gold",
          badgeTone: "is-gold",
          rowTone: "is-champion-row",
          icon: "trophy",
        };
      }
      if (isLChamp) {
        return {
          text: "L Champion",
          tone: "gold",
          badgeTone: "is-gold",
          rowTone: "is-champion-row",
          icon: "medal",
        };
      }
      if (tier === "H" && place === 2) {
        return {
          text: "Runner-Up",
          tone: "silver",
          badgeTone: "is-silver",
          rowTone: "is-runner-up-row",
          icon: "medal",
        };
      }
      if (tier === "L" && place === 10) {
        return {
          text: "L Runner-Up",
          tone: "silver",
          badgeTone: "is-silver",
          rowTone: "is-runner-up-row",
          icon: "medal",
        };
      }
      if (tier === "H" && place === 3) {
        return {
          text: "Semifinalist",
          tone: "bronze",
          badgeTone: "is-bronze",
          rowTone: "is-semifinalist-row",
          icon: null,
        };
      }
      if (tier === "L" && place === 11) {
        return {
          text: "L Semifinalist",
          tone: "bronze",
          badgeTone: "is-bronze",
          rowTone: "is-semifinalist-row",
          icon: null,
        };
      }
      if (tier === "H" && place === 5) {
        return {
          text: "Quarterfinalist",
          tone: "subtle",
          badgeTone: "is-quarter",
          rowTone: "is-quarterfinalist-row",
          icon: null,
        };
      }
      if (tier === "L" && place === 13) {
        return {
          text: "L Quarterfinalist",
          tone: "subtle",
          badgeTone: "is-quarter",
          rowTone: "is-quarterfinalist-row",
          icon: null,
        };
      }
      if (place === 2) {
        return { text: "2nd Place", tone: "silver", badgeTone: "is-silver", rowTone: "is-runner-up-row", icon: "medal" };
      }
      if (place === 3) {
        return { text: "3rd Place", tone: "bronze", badgeTone: "is-bronze", rowTone: "is-semifinalist-row", icon: null };
      }
      return {
        text: `${tier ? `${tier} · ` : ""}Place ${place}`,
        tone: "muted",
        badgeTone: "",
        rowTone: "",
        icon: null,
      };
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

    function standingsView(info, { showPlacements = true, showLeagues = true } = {}) {
      const out = [];
      const places = showPlacements ? info.placements ?? [] : [];
      const champions = places.filter((p) => p.result === "won");
      if (champions.length) {
        out.push(h(
          "div",
          { class: "public-bracket-champions" },
          ...champions.map((c) => {
            const players = playersFor(c.name, c.players);
            const isH = c.tier === "H";
            const isL = c.tier === "L";
            const tierClass = isL ? "is-gold is-l-champ" : "is-gold is-h-champ";
            const eyebrowText = c.tier ? `${c.tier} Bracket Champion` : "Division Champion";
            const iconName = isH ? "trophy" : isL ? "medal" : "trophy";

            return h(
              "div",
              { class: `public-bracket-champion ${tierClass}` },
              h(
                "div",
                { class: "public-champion-head" },
                h("span", { class: "public-champion-badge" }, icon(iconName), eyebrowText),
              ),
              h(
                "div",
                { class: "public-champion-stage" },
                renderPlayerPhotos(players, "is-lg public-champion-photos"),
              ),
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
      for (const r of showLeagues ? info.standings ?? [] : []) {
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
            { class: "public-placements-brackets" },
            ...[...new Set(places.map((r) => r.tier || "Overall"))].map((tier) => {
              const tierPlaces = places.filter((r) => (r.tier || "Overall") === tier);
              const isDoubles = tierPlaces.some((r) => r.players && r.players.includes("&"));
              const countUnit = isDoubles
                ? (tierPlaces.length === 1 ? "Team" : "Teams")
                : (tierPlaces.length === 1 ? "Entry" : "Entries");
              const kickerText = tier === "H"
                ? "Championship Flight"
                : tier === "L"
                ? "Challenger Flight"
                : "Final Standings";
              return h(
                "section",
                { class: `public-placements-bracket is-${tier.toLowerCase()}` },
                h(
                  "div",
                  { class: "public-placements-bracket-head" },
                  h(
                    "div",
                    { class: "public-placements-bracket-heading" },
                    h(
                      "span",
                      { class: "public-placements-bracket-icon", "aria-hidden": "true" },
                      icon(tier === "L" ? "medal" : "trophy"),
                    ),
                    h(
                      "div",
                      { class: "public-placements-bracket-titles" },
                      h("span", { class: "public-placements-bracket-kicker" }, kickerText),
                      h("h4", { class: "public-placements-bracket-title" }, tier === "Overall" ? "Overall Standings" : `${tier} Bracket`),
                    ),
                  ),
                  h("span", { class: "public-placements-count" }, `${tierPlaces.length} ${countUnit}`),
                ),
                h("div", { class: "public-placements-list" }, ...tierPlaces.map((r) => {
                  const players = playersFor(r.name, r.players);
                  const pill = achievementPill(r);
                  const badgeClass = [
                    "public-placement-badge",
                    pill.badgeTone || "",
                  ].filter(Boolean).join(" ");
                  const rowClass = [
                    "public-placement-row",
                    pill.rowTone || "",
                  ].filter(Boolean).join(" ");

                  return h(
                    "div",
                    { class: rowClass },
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
                            { class: `public-placement-pill is-${pill.tone || "subtle"}` },
                            pill.icon ? icon(pill.icon) : null,
                            pill.text,
                          ),
                        )
                      : null,
                  );
                })),
              );
            }),
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

  return standingsView;
}

export function finalResultsSkeleton({ split = true } = {}) {
  const championCard = (toneClass) =>
    h(
      "div",
      { class: `public-bracket-champion ${toneClass} is-skeleton`, "aria-hidden": "true" },
      h("div", { class: "public-bracket-champion-top" }, h("span", { class: "sk sk-pill bt-sk-champ-pill" })),
      h(
        "div",
        { class: "public-bracket-champion-body" },
        h(
          "div",
          { class: "public-roster-photos is-lg" },
          h("span", { class: "sk sk-avatar round bt-sk-avatar-lg" }),
          h("span", { class: "sk sk-avatar round bt-sk-avatar-lg" }),
        ),
        h(
          "div",
          { class: "public-bracket-champion-names bt-sk-champ-names" },
          h("span", { class: "sk bt-sk-champ-team" }),
          h("span", { class: "sk sk-sub bt-sk-champ-players" }),
        ),
      ),
    );

  const placementRow = (i) =>
    h(
      "div",
      { class: `public-placement-row${i === 0 ? " is-champion-row" : ""}`, "aria-hidden": "true" },
      h("span", { class: "sk bt-sk-place-badge" }),
      h(
        "div",
        { class: "public-roster-photos public-placement-photos" },
        h("span", { class: "sk sk-avatar round bt-sk-avatar-sm" }),
        h("span", { class: "sk sk-avatar round bt-sk-avatar-sm" }),
      ),
      h(
        "div",
        { class: "public-placement-info bt-sk-place-info" },
        h("span", { class: `sk ${i % 2 ? "w-50" : "w-70"}` }),
        h("span", { class: `sk sk-sub ${i % 2 ? "w-70" : "w-50"}` }),
      ),
      h(
        "div",
        { class: "public-placement-pill-wrap" },
        h("span", { class: "sk sk-pill bt-sk-place-pill" }),
      ),
    );

  const placementBracket = (tierClass) =>
    h(
      "section",
      { class: `public-placements-bracket ${tierClass} is-skeleton`, "aria-hidden": "true" },
      h(
        "div",
        { class: "public-placements-bracket-head" },
        h(
          "div",
          { class: "public-placements-bracket-heading" },
          h("span", { class: "sk bt-sk-bracket-icon" }),
          h(
            "div",
            { class: "public-placements-bracket-titles bt-sk-bracket-titles" },
            h("span", { class: "sk sk-sub bt-sk-bracket-kicker" }),
            h("span", { class: "sk bt-sk-bracket-title" }),
          ),
        ),
        h("span", { class: "sk sk-pill bt-sk-bracket-count" }),
      ),
      h(
        "div",
        { class: "public-placements-list" },
        ...Array.from({ length: 6 }, (_, i) => placementRow(i)),
      ),
    );

  return h(
    "div",
    { class: "bt-stack", "aria-busy": "true", "aria-label": "Loading final standings" },
    h(
      "div",
      { class: `public-bracket-champions${split ? "" : " is-single"}` },
      championCard("is-gold"),
      split ? championCard("is-emerald") : null,
    ),
    h(
      "section",
      { class: "public-bracket-section public-placements-section" },
      h(
        "div",
        { class: `public-placements-brackets${split ? "" : " is-single"}` },
        placementBracket("is-h"),
        split ? placementBracket("is-l") : null,
      ),
    ),
  );
}
