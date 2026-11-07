// My Games (Members Portal): the signed-in member's own matches, newest first, from the database function my_games().
// Each card shows the event, division and round, both teams with their players, the games from the member's side, the
// result, and (when the division is rated) how much the match moved their rating. Nothing here changes any data.
import {
  attachPagePattern,
  emptyState,
  h,
  icon,
  memberHero,
  tableFilter,
} from "./ui.js";
import { rememberView } from "./lib/view-memory.js";
import { formatDateTime } from "./lib/dates.js";

const FILTERS = [
  { id: "all", label: "All Games" },
  { id: "win", label: "Wins" },
  { id: "loss", label: "Losses" },
  { id: "upcoming", label: "Upcoming" },
];

const signed = (n) => `${n >= 0 ? "+" : "−"}${Math.abs(n).toFixed(3)}`;

export function createMyGamesPages({ api }) {
  function myGamesPage() {
    const page = h("div", { class: "page my-games-page" });
    attachPagePattern(page);
    const state = { filter: "all", rows: [], status: "loading" };
    rememberView(state, "my-games", ["filter"]);
    const filterHost = h("div", { class: "member-status-filter" });
    const summaryHost = h("div", { class: "my-games-summary" });
    const listHost = h("div", { class: "my-games-list", "aria-live": "polite" });

    const played = (r) => r.result === "win" || r.result === "loss";
    const matches = {
      all: () => true,
      win: (r) => r.result === "win",
      loss: (r) => r.result === "loss",
      upcoming: (r) => !played(r),
    };

    async function load() {
      state.status = state.rows.length ? "refreshing" : "loading";
      draw();
      try {
        state.rows = ((await api.rpc("my_games")) ?? []).sort((a, b) => {
          const time = (r) => {
            const value = Date.parse(r.played_at ?? "");
            return Number.isFinite(value) ? value : -Infinity;
          };
          const newest = time(b) - time(a);
          return newest || String(b.match_id ?? "").localeCompare(String(a.match_id ?? ""));
        });
        state.status = "ready";
      } catch {
        state.status = "error";
      }
      draw();
    }

    function statCard({
      label,
      value,
      badgeText = "",
      badgeTone = "",
      subtext = "",
      tone = "",
      iconName = "layers",
      progress = null,
    }) {
      return h(
        "div",
        { class: `my-games-stat${tone ? ` is-${tone}` : ""}` },
        h(
          "div",
          { class: "my-games-stat-top" },
          h("span", { class: "my-games-stat-label" }, label),
          h("span", { class: "my-games-stat-icon", "aria-hidden": "true" }, icon(iconName)),
        ),
        h(
          "div",
          { class: "my-games-stat-main" },
          h("strong", { class: "my-games-stat-value" }, value),
          badgeText
            ? h("span", { class: `my-games-stat-badge${badgeTone ? ` is-${badgeTone}` : ""}` }, badgeText)
            : null,
        ),
        progress != null
          ? h(
            "div",
            { class: "my-games-stat-meter", "aria-hidden": "true" },
            h("div", { class: "my-games-stat-bar", style: `width: ${Math.max(0, Math.min(100, progress))}%` }),
          )
          : null,
        subtext ? h("div", { class: "my-games-stat-footer" }, subtext) : null,
      );
    }

    function statSkeletonCard({ label, tone = "", iconName = "layers" }) {
      return h(
        "div",
        {
          class: `my-games-stat is-skeleton${tone ? ` is-${tone}` : ""}`,
          "aria-hidden": "true",
        },
        h(
          "div",
          { class: "my-games-stat-top" },
          h("span", { class: "my-games-stat-label" }, label),
          h(
            "span",
            { class: "my-games-stat-icon", "aria-hidden": "true" },
            icon(iconName),
          ),
        ),
        h(
          "div",
          { class: "my-games-stat-main" },
          h("span", { class: "sk my-games-sk-val" }),
          h("span", { class: "sk sk-pill my-games-sk-badge" }),
        ),
        h(
          "div",
          { class: "my-games-stat-footer" },
          h("span", { class: "sk w-70 sk-sub" }),
        ),
      );
    }

    function cardSkeleton() {
      const skSide = (me) =>
        h(
          "div",
          { class: `my-games-side${me ? " is-me" : ""}` },
          h(
            "div",
            { class: "my-games-side-header" },
            h(
              "span",
              { class: `my-games-side-tag${me ? " is-me-tag" : ""}` },
              me ? "Your Team" : "Opponent",
            ),
            h("span", { class: "sk my-games-sk-win-pill" }),
          ),
          h("span", { class: "sk w-70" }),
          h("span", { class: "sk w-50 sk-sub" }),
        );
      return h(
        "article",
        { class: "my-games-card is-skeleton", "aria-hidden": "true" },
        h(
          "div",
          { class: "my-games-head" },
          h(
            "div",
            { class: "my-games-title" },
            h(
              "div",
              { class: "my-games-event-row" },
              h(
                "span",
                { class: "my-games-event-icon", "aria-hidden": "true" },
                icon("trophy"),
              ),
              h("span", { class: "sk w-50 my-games-sk-event" }),
            ),
            h(
              "div",
              { class: "my-games-meta-pills" },
              h("span", { class: "sk sk-pill my-games-sk-meta-pill" }),
              h("span", { class: "sk sk-pill my-games-sk-meta-pill" }),
              h("span", { class: "sk sk-pill my-games-sk-meta-pill" }),
            ),
          ),
          h(
            "div",
            { class: "my-games-badges" },
            h("span", { class: "sk sk-pill my-games-sk-outcome" }),
            h("span", { class: "sk w-50 sk-sub" }),
          ),
        ),
        h(
          "div",
          { class: "my-games-versus" },
          skSide(true),
          h("span", { class: "my-games-vs", "aria-hidden": "true" }, "VS"),
          skSide(false),
        ),
        h(
          "div",
          { class: "my-games-foot" },
          h(
            "div",
            { class: "my-games-scores" },
            h("span", { class: "sk sk-pill my-games-sk-score" }),
            h("span", { class: "sk sk-pill my-games-sk-score" }),
          ),
          h("span", { class: "sk sk-pill my-games-sk-rating" }),
        ),
      );
    }

    function side(name, players, { me = false, winner = false, loser = false } = {}) {
      return h(
        "div",
        { class: `my-games-side${me ? " is-me" : ""}${winner ? " is-winner" : ""}${loser ? " is-loser" : ""}` },
        h(
          "div",
          { class: "my-games-side-header" },
          h(
            "span",
            { class: `my-games-side-tag${me ? " is-me-tag" : ""}` },
            me ? "Your Team" : "Opponent",
          ),
          winner
            ? h(
              "span",
              { class: "my-games-winner-badge" },
              icon("trophy"),
              h("span", {}, "Winner"),
            )
            : null,
        ),
        h("strong", { class: "my-games-team", title: name ?? "" }, name ?? "To be decided"),
        players ? h("span", { class: "sub my-games-players" }, players) : null,
      );
    }

    function card(r) {
      const win = r.result === "win";
      const loss = r.result === "loss";
      const games = Array.isArray(r.games) ? r.games : [];
      const change = r.rating_change == null ? null : Number(r.rating_change);
      return h(
        "article",
        { class: `my-games-card${win ? " is-win" : ""}${loss ? " is-loss" : ""}` },
        h(
          "div",
          { class: "my-games-head" },
          h(
            "div",
            { class: "my-games-title" },
            h(
              "div",
              { class: "my-games-event-row" },
              h("span", { class: "my-games-event-icon", "aria-hidden": "true" }, icon("trophy")),
              h("strong", { class: "my-games-event-name" }, r.event_name),
            ),
            h(
              "div",
              { class: "my-games-meta-pills" },
              h("span", { class: "my-games-meta-pill" }, r.division_name),
              r.stage_label ? h("span", { class: "my-games-meta-pill" }, r.stage_label) : null,
              r.match_no ? h("span", { class: "my-games-meta-pill is-match-no" }, `Match ${r.match_no}`) : null,
            ),
          ),
          h(
            "div",
            { class: "my-games-badges" },
            win
              ? h("span", { class: "my-games-outcome-pill is-win" }, icon("checkCircle"), "Won")
              : loss
              ? h("span", { class: "my-games-outcome-pill is-loss" }, icon("x"), "Lost")
              : h("span", { class: "my-games-outcome-pill is-pending" }, r.status === "in_progress" ? "In Progress" : "Scheduled"),
            r.played_at ? h("span", { class: "sub my-games-date" }, icon("clock"), formatDateTime(r.played_at)) : null,
          ),
        ),
        h(
          "div",
          { class: "my-games-versus" },
          side(r.my_team, r.my_players, { me: true, winner: win, loser: loss }),
          h("span", { class: "my-games-vs", "aria-hidden": "true" }, "VS"),
          side(r.opp_team, r.opp_players, { winner: loss, loser: win }),
        ),
        games.length || change !== null
          ? h(
            "div",
            { class: "my-games-foot" },
            games.length
              ? h(
                "div",
                { class: "my-games-scores", "aria-label": "Game scores, yours first" },
                ...games.map((g, i) =>
                  h(
                    "span",
                    { class: `my-games-score${g.me > g.opp ? " is-won" : ""}` },
                    h("span", { class: "my-games-score-tag" }, `GAME ${i + 1}`),
                    h(
                      "span",
                      { class: "my-games-score-nums" },
                      h("span", { class: g.me > g.opp ? "score-high" : "score-low" }, g.me),
                      h("span", { class: "score-dash" }, "–"),
                      h("span", { class: g.opp > g.me ? "score-high" : "score-low" }, g.opp),
                    ),
                  )
                ),
              )
              : null,
            change !== null
              ? h(
                "span",
                {
                  class: `my-games-rating ${change >= 0 ? "is-up" : "is-down"}`,
                  title: `${r.discipline === "singles" ? "Singles" : "Doubles"} rating change from this match`,
                },
                icon(change >= 0 ? "chevronUp" : "chevronDown"),
                `${r.discipline === "singles" ? "Singles" : "Doubles"} ${signed(change)}`,
              )
              : null,
          )
          : null,
      );
    }

    function draw() {
      const done = state.rows.filter(played);
      const wins = done.filter((r) => r.result === "win").length;
      const losses = done.filter((r) => r.result === "loss").length;
      const upcoming = state.rows.filter((r) => !played(r)).length;
      const totalMatches = state.rows.length;
      const winRate = done.length ? Math.round((wins / done.length) * 100) : 0;
      const total = state.rows.reduce((sum, r) => sum + (r.rating_change == null ? 0 : Number(r.rating_change)), 0);
      const hasRating = state.rows.some((r) => r.rating_change != null);
      const avgChange = done.length ? total / done.length : 0;


      // Streak calculation
      let streak = 0;
      if (done.length) {
        const first = done[0].result;
        for (const r of done) {
          if (r.result === first) streak++;
          else break;
        }
      }
      const isUndefeated = wins === done.length && done.length > 0;
      const streakLabel = isUndefeated
        ? "Undefeated"
        : streak
        ? `${streak}${done[0].result === "win" ? "W" : "L"} Streak`
        : "Level";
      const streakTone = isUndefeated || (streak && done[0].result === "win") ? "win" : "loss";

      filterHost.replaceChildren(tableFilter({
        activeId: state.filter,
        tabs: FILTERS.map((f) => ({
          id: f.id,
          label: f.label,
          badge: state.status === "loading" ? "—" : state.rows.filter(matches[f.id]).length,
        })),
        onChange: (id) => {
          state.filter = id;
          draw();
        },
      }));
      summaryHost.replaceChildren(
        ...(state.status === "loading"
          ? [
            statSkeletonCard({
              label: "Games Played",
              tone: "games",
              iconName: "layers",
            }),
            statSkeletonCard({
              label: "Match Record",
              tone: "record",
              iconName: "medal",
            }),
            statSkeletonCard({
              label: "Win Rate",
              tone: "winrate",
              iconName: "checkCircle",
            }),
            statSkeletonCard({
              label: "Rating Impact",
              tone: "up",
              iconName: "chevronUp",
            }),
          ]
          : state.status === "ready" && state.rows.length
          ? [
            statCard({
              label: "Games Played",
              value: String(totalMatches),
              badgeText: `${done.length} Finished`,
              badgeTone: "neutral",
              subtext: `${done.length} Completed · ${upcoming} Scheduled`,
              tone: "games",
              iconName: "layers",
            }),
            statCard({
              label: "Match Record",
              value: `${wins}–${losses}`,
              badgeText: streakLabel,
              badgeTone: streakTone,
              subtext: `${wins} Won · ${losses} Lost`,
              tone: "record",
              iconName: "medal",
            }),
            statCard({
              label: "Win Rate",
              value: done.length ? `${winRate}%` : "—",
              badgeText: done.length ? `${wins}/${done.length} Won` : "0 Played",
              badgeTone: winRate >= 50 ? "win" : "neutral",
              subtext: `${wins} of ${done.length} matches won`,
              tone: "winrate",
              iconName: "checkCircle",
              progress: done.length ? winRate : 0,
            }),
            hasRating
              ? statCard({
                label: "Rating Impact",
                value: signed(total),
                badgeText: done.length ? `${signed(avgChange)} / gm` : "Net",
                badgeTone: total >= 0 ? "win" : "loss",
                subtext: total >= 0 ? "Total rating points gained" : "Total rating points adjusted",
                tone: total >= 0 ? "up" : "down",
                iconName: total >= 0 ? "chevronUp" : "chevronDown",
              })
              : null,
          ].filter(Boolean)
          : []),
      );
      const shown = state.rows.filter(matches[state.filter]);
      if (state.status === "loading") {
        listHost.replaceChildren(
          cardSkeleton(),
          cardSkeleton(),
          cardSkeleton(),
        );
      } else if (state.status === "error") {
        listHost.replaceChildren(emptyState({
          icon: "alert",
          title: "Games could not be loaded",
          description: "Check your connection and try again.",
          resetLabel: "Try Again",
          onReset: load,
        }));
      } else if (!shown.length) {
        listHost.replaceChildren(emptyState({
          icon: "trophy",
          title: state.rows.length ? "No games here" : "No games yet",
          description: state.rows.length
            ? "Try another tab."
            : "Your matches appear here once a division you joined is drawn.",
        }));
      } else {
        listHost.replaceChildren(...shown.map(card));
      }
    }

    page.append(
      memberHero({
        iconName: "trophy",
        eyebrow: "Play",
        title: "My Games",
        titleBadge: true,
        chip: "Match History",
        description: "Your matches, scores and results, and how each one moved your rating.",
      }),
      filterHost,
      summaryHost,
      listHost,
    );
    load();
    return page;
  }

  return { myGamesPage };
}
