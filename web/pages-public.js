// Public pages (PLAN 9.2): the leaderboard and the latest results, for visitors who are not signed in.
//   * Each page exists only when the club has switched it on (Settings > Public pages); while it is off the server sends no
//     names at all and this page says so.
//   * What is shown is fixed by the server: display name, category and rank for the leaderboard; division, category, date and
//     the podium (top three, display names) for results. No member IDs, contact details, scores or history.
import { badge, dataTable, h, pageHeader, tabs } from "./ui.js";

export function createPublicPages({ api }) {
  function leaderboardPage() {
    const page = h("div", { class: "page" });
    const tabsHost = h("div", {});
    const body = h("div", { class: "public-body" });
    const state = {
      tab: "leaderboard",
      status: "loading",
      board: null,
      results: null,
      category: "",
    };

    async function load() {
      state.status = state.board ? "refreshing" : "loading";
      draw();
      try {
        const [board, results] = await Promise.all([
          api.rpc("public_leaderboard", {
            p_category_id: state.category || null,
          }),
          state.results ?? api.rpc("public_results"),
        ]);
        state.board = board;
        state.results = results;
        if (!board?.enabled && results?.enabled) state.tab = "results";
        state.status = "ready";
      } catch {
        state.status = "error";
      }
      draw();
    }

    function notPublished(what) {
      return h(
        "div",
        { class: "card" },
        h("h2", {}, `${what} is not published`),
        h(
          "p",
          { class: "muted" },
          "The club has not made this page public. Members can see it after signing in.",
        ),
        h("a", { class: "btn btn-primary", href: "#/signin" }, "Sign in"),
      );
    }

    function leaderboardView() {
      if (!state.board?.enabled) {
        return state.status === "ready"
          ? notPublished("The leaderboard")
          : dataTable({
            schema: {
              columns: [{ key: "n", label: "Player", render: () => "" }],
            },
            rows: [],
            state: state.status === "error" ? "error" : "loading",
            onRetry: load,
            ariaLabel: "Leaderboard",
          });
      }
      const players = state.board.players ?? [];
      return h(
        "div",
        { class: "stack" },
        h(
          "div",
          { class: "field" },
          h("label", { for: "pb-cat" }, "Category"),
          h(
            "select",
            {
              class: "input select-input",
              id: "pb-cat",
              onChange: (e) => {
                state.category = e.target.value;
                load();
              },
            },
            h("option", { value: "" }, "All categories"),
            ...(state.board.categories ?? []).map((c) =>
              h(
                "option",
                { value: c.id, selected: c.id === state.category },
                c.name,
              )
            ),
          ),
        ),
        dataTable({
          schema: {
            columns: [
              {
                key: "no",
                label: "#",
                align: "right",
                render: (p) => String(players.indexOf(p) + 1),
              },
              { key: "name", label: "Player", render: (p) => p.name },
              { key: "category", label: "Category", render: (p) => p.category },
              { key: "rank", label: "Rank", render: (p) => p.rank },
            ],
          },
          rows: players,
          state: state.status === "refreshing" ? "ready" : "ready",
          ariaLabel: "Leaderboard",
          emptyTitle: "No ranked players yet",
          emptyText: "Players appear here once they hold a rank.",
        }),
      );
    }

    function resultsView() {
      if (!state.results?.enabled) {
        return state.status === "ready" ? notPublished("Results") : dataTable({
          schema: {
            columns: [{ key: "n", label: "Division", render: () => "" }],
          },
          rows: [],
          state: state.status === "error" ? "error" : "loading",
          onRetry: load,
          ariaLabel: "Results",
        });
      }
      const divisions = state.results.divisions ?? [];
      if (!divisions.length) {
        return dataTable({
          schema: {
            columns: [{ key: "n", label: "Division", render: () => "" }],
          },
          rows: [],
          state: "ready",
          ariaLabel: "Results",
          emptyTitle: "No results yet",
          emptyText: "Final results appear here when a division finishes.",
        });
      }
      return h(
        "div",
        { class: "stack" },
        ...divisions.map((d) =>
          h(
            "section",
            { class: "card stack" },
            h("h3", {}, `${d.event} · ${d.division}`),
            h(
              "p",
              { class: "muted" },
              [
                d.category,
                d.format === "doubles" ? "Doubles" : "Singles",
                d.finished_on,
              ].filter(Boolean).join(" · "),
            ),
            h(
              "ol",
              { class: "podium" },
              ...(d.podium ?? []).map((p) =>
                h(
                  "li",
                  {},
                  badge(
                    p.placement === 1
                      ? "1st"
                      : p.placement === 2
                      ? "2nd"
                      : "3rd",
                    p.placement === 1 ? "success" : "neutral",
                  ),
                  " ",
                  p.name,
                )
              ),
            ),
          )
        ),
      );
    }

    function draw() {
      tabsHost.replaceChildren(tabs({
        activeId: state.tab,
        tabs: [
          { id: "leaderboard", label: "Leaderboard" },
          { id: "results", label: "Results" },
        ],
        onChange: (id) => {
          state.tab = id;
          draw();
        },
      }));
      body.replaceChildren(
        state.tab === "leaderboard" ? leaderboardView() : resultsView(),
      );
    }

    page.append(
      pageHeader({
        icon: "trophy",
        eyebrow: "Capitol Pickleball Club",
        title: "Leaderboard and results",
        description:
          "What the club has chosen to share publicly. Sign in for the full ranking and your own history.",
      }),
      tabsHost,
      body,
    );
    load();
    return page;
  }

  return { leaderboardPage };
}
