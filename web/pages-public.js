// Public pages (PLAN 9.2): the leaderboard and the latest results, for visitors who are not signed in.
//   * Each page exists only when the club has switched it on (Settings > Public pages); while it is off the server sends no
//     names at all and this page says so.
//   * What is shown is fixed by the server: display name, category and rank for the leaderboard; division, category, date and
//     the podium (top three, display names) for results. No member IDs, contact details, scores or history.
import {
  badge,
  button,
  dataTable,
  h,
  icon,
  memberHero,
  pagination,
  searchControl,
  tabs,
} from "./ui.js";
import { avatarImage, signedAvatarUrls } from "./lib/avatar.js";
import { formatMemberName } from "./lib/names.js";
import { formatPoints } from "./cpc-points.js";

function splitRankLabel(rank) {
  const match = String(rank ?? "").match(/^(.*?)\s*\((\d\.\d{3}\s*[–-]\s*\d\.\d{3})\)$/);
  return match
    ? { name: match[1].trim(), band: match[2].replace(/\s+/g, "") }
    : { name: rank, band: null };
}

export function createPublicPages({ api, client }) {
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
        h("a", { class: "btn btn-primary", href: "#/signin" }, "Sign In"),
      );
    }

    function leaderboardView() {
      if (!state.board?.enabled) {
        return state.status === "ready"
          ? notPublished("The Leaderboard")
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
            h("option", { value: "" }, "All Categories"),
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
      memberHero({
        iconName: "trophy",
        eyebrow: "Club",
        title: "Leaderboard and Results",
        chip: "Club Results",
        titleBadge: true,
        description:
          "What the club has chosen to share publicly. Sign in for the full ranking and your own history.",
      }),
      tabsHost,
      body,
    );
    load();
    return page;
  }

  // Members: directory names, CPC numbers, photos and ranks; internal IDs stay private.
  function membersPage() {
    const page = h("div", { class: "page public-members-page" });
    const body = h("div", { class: "public-body" });
    const state = {
      status: "loading",
      info: null,
      photos: new Map(),
      search: "",
      page: 1,
      pageSize: 12,
    };

    const searchInput = searchControl({
      class: "input",
      placeholder: "Search members",
      "aria-label": "Search members",
      value: "",
      disabled: true,
      onInput: (e) => {
        state.search = e.target.value;
        state.page = 1;
        renderCards();
      },
    });

    const searchWrap = h(
      "div",
      { class: "public-members-search-wrap" },
      searchInput,
    );
    const contentArea = h("div", { class: "public-members-content" });

    function renderCards() {
      if (state.status === "ready" && !state.info?.enabled) {
        searchWrap.hidden = true;
        contentArea.replaceChildren(
          h(
            "div",
            { class: "card public-members-not-published" },
            h("h2", {}, "The member list is not published"),
            h(
              "p",
              { class: "muted" },
              "The club has not made this page public. Members can see the ranking after signing in.",
            ),
            h("a", { class: "btn btn-primary", href: "#/signin" }, "Sign In"),
          ),
        );
        return;
      }

      searchWrap.hidden = false;

      if (state.status === "loading") {
        searchInput.disabled = true;
        const skeletonGrid = h("div", {
          class: "public-members-grid",
          "aria-busy": "true",
          "aria-label": "Loading members",
        });
        for (let i = 0; i < 12; i++) {
          skeletonGrid.append(
            h(
              "article",
              { class: "public-member-card is-skeleton", "aria-hidden": "true" },
              h(
                "div",
                { class: "public-member-card-header" },
                h("span", { class: "sk sk-avatar" }),
                h(
                  "div",
                  { class: "public-member-card-identity" },
                  h("span", { class: "sk sk-name" }),
                  h("span", { class: "sk sk-sub" }),
                ),
              ),
              h("div", { class: "public-member-card-divider" }),
              h(
                "div",
                { class: "public-member-meta-grid" },
                ...Array.from({ length: 4 }, () => h(
                  "div",
                  { class: "public-member-meta-tile" },
                  h("span", { class: "sk sk-tile-label" }),
                  h("span", { class: "sk sk-tile-badge" }),
                )),
              ),
            ),
          );
        }
        contentArea.replaceChildren(skeletonGrid);
        return;
      }

      if (state.status === "error") {
        searchInput.disabled = true;
        contentArea.replaceChildren(
          h(
            "div",
            { class: "tbl-state error public-members-state", role: "alert" },
            h("span", { class: "badge-icon" }, icon("alert")),
            h("h2", {}, "Could not load members"),
            h(
              "p",
              { class: "muted" },
              "Something went wrong loading the club member list. Try again.",
            ),
            button({ label: "Retry", icon: "refresh", onClick: load }),
          ),
        );
        return;
      }

      searchInput.disabled = false;
      const allMembers = state.info?.members ?? [];
      if (allMembers.length === 0) {
        contentArea.replaceChildren(
          h(
            "div",
            { class: "tbl-state public-members-state" },
            h("span", { class: "badge-icon" }, icon("inbox")),
            h("h2", {}, "No members yet"),
            h(
              "p",
              { class: "muted" },
              "Club members appear here once they join.",
            ),
          ),
        );
        return;
      }

      const normalize = (text) =>
        String(text || "")
          .normalize("NFKD")
          .replace(/\p{M}/gu, "")
          .toLocaleLowerCase();
      const terms = normalize(state.search).trim().split(/\s+/).filter(Boolean);
      const filtered = allMembers.filter((m) => {
        if (!terms.length) return true;
        const text = normalize(
          `${m.name} ${m.member_no ?? ""} ${m.category ?? ""} ${m.rank ?? ""}`,
        );
        return terms.every((t) => text.includes(t));
      });

      if (filtered.length === 0) {
        contentArea.replaceChildren(
          h(
            "div",
            {
              class: "tbl-state tbl-search-empty public-members-state",
              role: "status",
            },
            h("span", { class: "badge-icon" }, icon("search")),
            h("h2", {}, "No matching members"),
            h(
              "p",
              { class: "muted" },
              "Try another search or clear the search box.",
            ),
            button({
              label: "Clear Search",
              icon: "x",
              onClick: () => {
                searchInput.value = "";
                state.search = "";
                state.page = 1;
                renderCards();
                searchInput.focus();
              },
            }),
          ),
        );
        return;
      }

      const pages = Math.max(1, Math.ceil(filtered.length / state.pageSize));
      if (state.page > pages) state.page = pages;
      const start = (state.page - 1) * state.pageSize;
      const visible = filtered.slice(start, start + state.pageSize);

      const grid = h("div", {
        class: "public-members-grid",
        role: "region",
        "aria-label": "Club Members Cards",
      });

      for (const m of visible) {
        const active = m.is_active === true;
        const status = badge(
          icon(active ? "check" : "clock"),
          active ? "success" : "neutral",
        );
        status.classList.add("public-member-status");
        status.classList.add(active ? "is-active" : "is-inactive");
        status.setAttribute("role", "img");
        status.setAttribute("aria-label", active ? "Active" : "Not Active");
        status.setAttribute("title", active ? "Active" : "Not Active");
        grid.append(
          h(
            "article",
            { class: "public-member-card" },
            h(
              "div",
              { class: "public-member-card-header" },
              h(
                "span",
                {
                  class: "member-avatar ranking-player-photo public-member-avatar",
                  "aria-hidden": "true",
                },
                avatarImage(state.photos.get(m.photo), m.name),
              ),
              h(
                "div",
                { class: "public-member-card-identity" },
                h("h3", { class: "public-member-name", title: m.name }, m.name),
                h(
                  "span",
                  { class: "public-member-sub sub" },
                  m.member_no || "Club Member",
                ),
              ),
              status,
            ),
            h("div", {
              class: "public-member-card-divider",
              "aria-hidden": "true",
            }),
            h(
              "div",
              { class: "public-member-meta-grid" },
              h(
                "div",
                { class: "public-member-meta-tile" },
                h(
                  "span",
                  { class: "public-member-meta-label" },
                  icon("layers"),
                  "Category",
                ),
                h(
                  "div",
                  { class: "public-member-meta-value" },
                  m.category
                    ? badge(m.category, "info")
                    : h("span", { class: "public-member-unranked" }, "—"),
                ),
              ),
              h(
                "div",
                { class: "public-member-meta-tile" },
                h(
                  "span",
                  { class: "public-member-meta-label" },
                  icon("medal"),
                  "Club Rank",
                ),
                (() => {
                  const rank = splitRankLabel(m.rank);
                  return h(
                    "div",
                    { class: "public-member-meta-value" },
                    m.rank ? badge(rank.name, "success") : badge("Not Ranked", "neutral"),
                  );
                })(),
              ),
              ...[["singles_points", "Singles Rating"], ["doubles_points", "Doubles Rating"]].map(([key, label]) =>
                h("div", { class: "public-member-meta-tile" },
                  h("span", { class: "public-member-meta-label" }, icon("trophy"), label),
                  h("div", { class: "public-member-meta-value" },
                    badge(m[key] == null ? "Unrated" : formatPoints(m[key]), m[key] == null ? "neutral" : "success"),
                  ),
                )
              ),
            ),
          ),
        );
      }

      const pager = pagination({
        compactMobile: true,
        page: state.page,
        pageSize: state.pageSize,
        total: filtered.length,
        onPage: (p) => {
          state.page = p;
          renderCards();
          grid.scrollIntoView?.({ behavior: "smooth", block: "start" });
        },
      });

      const pagerWrap = h(
        "div",
        { class: "public-members-pager-wrap" },
        pager,
      );

      contentArea.replaceChildren(grid, pagerWrap);
    }

    async function load() {
      state.status = "loading";
      renderCards();
      try {
        state.info = await api.rpc("public_members");
        if (state.info?.members) {
          state.info.members = state.info.members.map((m) => ({
            ...m,
            name: formatMemberName({ ...m, display_name: m.name }),
          }));
        }
        state.status = "ready";
        renderCards();
        // photos follow the names, so the list never waits for them
        const paths = (state.info?.members ?? []).map((m) => m.photo);
        if (client && paths.some(Boolean)) {
          state.photos = await signedAvatarUrls(client, paths);
          if (page.isConnected) renderCards();
        }
      } catch {
        state.status = "error";
        renderCards();
      }
    }

    body.append(searchWrap, contentArea);
    page.append(
      memberHero({
        iconName: "user",
        eyebrow: "Club",
        title: "Our Members",
        publicHeader: true,
        chip: "Club Members",
        titleBadge: true,
        description:
          "The players of Capitol Pickleball Club and their current Club Rank.",
      }),
      body,
    );
    load();
    return page;
  }

  return { leaderboardPage, membersPage };
}
