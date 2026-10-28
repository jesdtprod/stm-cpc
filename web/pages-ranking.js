// Ranking page (PLAN 8.3): the club's ranking list and rank histories.
//   * Ranking: every active member who holds a rank, highest first, optionally for one category. Display names only; staff who
//     can read members also see member IDs, the history of anyone, and (with ranks.override) the button to set a rank by hand.
//   * My rank history: the member's own rank_history exactly as recorded: moves, reversals after a correction and the moves
//     that were reversed. Nothing here changes a rank except the override, which the database checks and audits.
import {
  adminHero,
  attachPagePattern,
  badge,
  button,
  dataTable,
  h,
  iconButton,
  openModal,
} from "./ui.js";
import { can } from "./lib/permissions.js";
import { formatDateTime } from "./lib/dates.js";
import { avatarImage, signedAvatarUrls } from "./lib/avatar.js";
import {
  assessPointsModal,
  cpcAdminPanel,
  loadRatingBands,
  ratingCell,
  pointsHistoryModal,
  pointsHistoryTable,
} from "./cpc-points.js";

export function createRankingPages({ api, client, session }) {
  function historyTable(rows, state, onRetry, filter, searchable = false) {
    const table = dataTable({
      filter,
      searchable,
      schema: {
        columns: [
          {
            key: "when",
            label: "When",
            render: (r) => formatDateTime(r.occurred_at),
          },
          {
            key: "change",
            label: "Rank Change",
            render: (r) => {
              const flow = r.from_name && r.from_name !== r.to_name
                ? h(
                  "span",
                  { class: "rank-change-flow" },
                  badge(r.from_name, "neutral"),
                  h("span", { class: "rank-change-arrow", "aria-hidden": "true" }, "→"),
                  badge(r.to_name, "success"),
                )
                : r.from_name === r.to_name
                ? h(
                  "span",
                  { class: "rank-change-flow" },
                  badge(r.to_name, "neutral"),
                  h("span", { class: "sub rank-change-sub" }, "(no change)"),
                )
                : h(
                  "span",
                  { class: "rank-change-flow" },
                  h("span", { class: "rank-change-prefix" }, "Set to"),
                  badge(r.to_name ?? "Unranked", "success"),
                );
              const statusBadge = r.is_reversal
                ? badge("Reversal", "warning")
                : r.reversed
                ? badge("Reversed", "neutral")
                : null;
              return h(
                "div",
                { class: "rank-history-change" },
                flow,
                statusBadge,
              );
            },
          },
          {
            key: "why",
            label: "Why",
            render: (r) =>
              h(
                "div",
                { class: "rank-history-why" },
                h("span", { class: "rank-history-reason" }, r.reason ?? r.rule_name ?? "—"),
                r.event_name
                  ? h(
                    "span",
                    { class: "sub rank-history-event" },
                    [r.event_name, r.division_name].filter(Boolean).join(" · "),
                  )
                  : null,
              ),
          },
        ],
      },
      rows,
      state,
      ariaLabel: "Rank History",
      onRetry,
      emptyTitle: "No rank changes yet",
      emptyText:
        "A rank change appears here after a division is finalized or an administrator sets a rank.",
    });
    table.classList.add("rank-history-table-wrap");
    return table;
  }

  function rankingPage() {
    const page = h("div", {
      class: "page admin-dashboard admin-members-page member-ranking-page ranking-page",
    });
    attachPagePattern(page);

    const state = {
      tab: "ranking",
      status: "loading",
      list: [],
      ranks: [],
      mine: [],
      mineStatus: "loading",
      points: [],
      pointsStatus: "loading",
      bands: [],
      photos: new Map(),
    };

    const TABS = [
      { id: "ranking", label: "Ranking" },
      { id: "mine", label: "My Rank History" },
      { id: "points", label: "My Rating History" },
    ];

    const statusButtons = TABS.map((item) =>
      h("button", {
        type: "button",
        class: "tab-btn",
        "aria-pressed": String(item.id === state.tab),
        onClick: () => {
          state.tab = item.id;
          drawStatusFilter();
          draw();
        },
      }, item.label, badge("0", "neutral"))
    );

    const statusFilter = h(
      "div",
      {
        class: "member-status-badges ranking-status-badges",
        role: "group",
        "aria-label": "Filter ranking view",
      },
      ...statusButtons,
    );

    const toolbar = h(
      "div",
      { class: "toolbar admin-members-toolbar ranking-toolbar has-status-badges" },
      statusFilter,
    );

    const tableHost = h("div", { class: "table-host" });
    const directoryCard = h(
      "div",
      { class: "member-directory-card ranking-directory-card" },
      tableHost,
    );

    function drawStatusFilter() {
      const counts = {
        ranking: state.list.length,
        mine: state.mine.length,
        points: state.points.length,
      };
      TABS.forEach((item, index) => {
        const count = counts[item.id] ?? 0;
        statusButtons[index].replaceChildren(
          item.label,
          badge(String(count), "neutral"),
        );
        statusButtons[index].setAttribute(
          "aria-pressed",
          String(item.id === state.tab),
        );
      });
    }

    async function load() {
      state.status = state.list.length ? "refreshing" : "loading";
      draw();
      try {
        const [list, bands] = await Promise.all([
          api.rpc("cpc_ranking_list", { p_category_id: null }),
          state.bands.length ? state.bands : loadRatingBands(api).catch(() => []),
        ]);
        state.bands = bands ?? [];
        const memberId = session?.getState().access?.member_id;
        state.list = (list ?? []).map((row, index) => ({
          ...row,
          position: index + 1,
        })).filter((row) => can("members.read") || row.member_id === memberId);
        if (client && state.list.length) {
          try {
            const photos = await api.rpc("ranking_photos", {
              p_member_ids: state.list.map((row) => row.member_id),
            });
            const urls = await signedAvatarUrls(
              client,
              (photos ?? []).map((row) => row.avatar_path),
            );
            state.photos = new Map(
              (photos ?? []).map((
                row,
              ) => [row.member_id, urls.get(row.avatar_path)]),
            );
          } catch {
            state.photos = new Map();
          }
        }
        state.status = "ready";
      } catch {
        state.status = "error";
      }
      draw();
    }

    async function loadMine() {
      state.mineStatus = state.mine.length ? "refreshing" : "loading";
      try {
        state.mine = await api.rpc("rank_history_view") ?? [];
        state.mineStatus = "ready";
      } catch {
        state.mineStatus = "error";
      }
      draw();
    }

    async function loadPoints() {
      state.pointsStatus = state.points.length ? "refreshing" : "loading";
      try {
        state.points = await api.rpc("cpc_points_history_view") ?? [];
        state.pointsStatus = "ready";
      } catch {
        state.pointsStatus = "error";
      }
      draw();
    }

    // ------------------------------------------------------------ modals
    async function historyModal(row) {
      let rows = [];
      let status = "ready";
      try {
        rows =
          await api.rpc("rank_history_view", { p_member_id: row.member_id }) ??
            [];
      } catch {
        status = "error";
      }
      return openModal({
        title: "Rank History",
        eyebrow: row.display_name,
        icon: "clock",
        size: "lg",
        confirmLabel: "Close",
        body: historyTable(rows, status),
        onConfirm: () => {},
      });
    }

    // ------------------------------------------------------------ views
    function rankingView() {
      const staff = can("members.read");
      const columns = [
        {
          key: "no",
          label: "#",
          align: "center",
          width: 80,
          render: (r) =>
            h(
              "span",
              {
                class: "ranking-position",
                "aria-label": `Position ${r.position}`,
              },
              String(r.position),
            ),
        },
        {
          key: "name",
          label: "Player",
          render: (r) => {
            const memberId = r.member_no;
            return h(
              "div",
              { class: "member-cell ranking-player-identity" },
              h("span", {
                class: "member-avatar ranking-player-photo",
                "aria-hidden": "true",
              }, avatarImage(state.photos.get(r.member_id), r.display_name)),
              h(
                "div",
                { class: "ranking-player-meta" },
                h("strong", { class: "ranking-player-name" }, r.display_name),
                memberId
                  ? h("span", { class: "sub ranking-player-id" }, memberId)
                  : null,
              ),
            );
          },
        },
        {
          key: "singles",
          label: "Singles Rating",
          align: "right",
          render: (r) => ratingCell(r, "singles", Boolean(r.rank_name), state.bands),
        },
        {
          key: "doubles",
          label: "Doubles Rating",
          align: "right",
          render: (r) => ratingCell(r, "doubles", Boolean(r.rank_name), state.bands),
        },
        {
          key: "category",
          label: "Category",
          render: (r) => r.category_name ? badge(r.category_name, "info") : h("span", { class: "sub" }, "—"),
        },
        {
          key: "rank",
          label: "Rank",
          render: (r) => {
            if (!r.rank_name) return badge("No rank yet", "neutral");
            return badge(r.rank_name.replace(/\s*\(\d\.\d{3}\s*[–-]\s*\d\.\d{3}\)$/, ""), "success");
          },
        },
      ];
      if (staff) {
        columns.push({
          key: "actions",
          label: "Action",
          align: "center",
          actionCount: can("ranks.override") ? 3 : 2,
          render: (r) =>
            h(
              "span",
              { class: "row-actions" },
              iconButton({
                label: `Rank history of ${r.display_name}`,
                icon: "clock",
                variant: "info",
                onClick: () => historyModal(r),
              }),
              iconButton({
                label: `Rating history of ${r.display_name}`,
                icon: "trophy",
                variant: "info",
                onClick: () => pointsHistoryModal(api, r.member_id, r.display_name),
              }),
              can("ranks.override")
                ? iconButton({
                  label: `Assess ratings of ${r.display_name}`,
                  icon: "sliders",
                  variant: "edit",
                  onClick: () => assessPointsModal({ api, row: r, onDone: load }),
                })
                : null,
            ),
        });
      }
      return dataTable({
        pageSize: 10,
        schema: { columns },
        rows: state.list,
        state: state.status === "refreshing" ? "ready" : state.status,
        searchable: false,
        ariaLabel: "Ranking",
        onRetry: load,
        emptyTitle: can("members.read") ? "No players yet" : "No rank to show",
        emptyText: can("members.read")
          ? "Active members appear here with their Singles and Doubles ratings and rank."
          : "Your rank will appear here once assigned and matching the selected category.",
      });
    }

    function draw() {
      drawStatusFilter();
      tableHost.replaceChildren(
        state.tab === "ranking"
          ? rankingView()
          : state.tab === "points"
          ? pointsHistoryTable(
            state.points,
            state.pointsStatus === "refreshing" ? "ready" : state.pointsStatus,
            loadPoints,
            null,
            false,
          )
          : historyTable(
            state.mine,
            state.mineStatus === "refreshing" ? "ready" : state.mineStatus,
            loadMine,
            null,
            false,
          ),
      );
    }

    const isAdmin = can("members.read");
    const hero = adminHero({
      title: "Club Ranking",
      chip: "Ratings & Ranking",
      roleLabel: isAdmin ? "Admin Console" : "Club Member",
      description: isAdmin
        ? "Every player by Singles and Doubles rating, highest first, and how ratings and ranks have changed."
        : "Your Singles and Doubles ratings, current rank and how they have changed.",
      actions: [
        button({
          label: "Refresh List",
          icon: "refresh",
          variant: "secondary",
          onClick: () => {
            load();
            loadMine();
            loadPoints();
          },
        }),
      ],
    });

    page.append(
      hero,
      ...(can("members.read") ? [cpcAdminPanel({ api, onChange: load })] : []),
      toolbar,
      directoryCard,
    );
    // both lists load up front so each tab's count is right before it is opened
    load();
    loadMine();
    loadPoints();
    return page;
  }

  return { rankingPage };
}
