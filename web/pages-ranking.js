// Ranking page (PLAN 8.3): the club's ranking list and rank histories.
//   * Ranking: every active member who holds a rank, highest first, optionally for one category. Display names only; staff who
//     can read members also see member IDs, the history of anyone, and (with ranks.override) the button to set a rank by hand.
//   * My rank history: the member's own rank_history exactly as recorded: moves, reversals after a correction and the moves
//     that were reversed. Nothing here changes a rank except the override, which the database checks and audits.
import {
  badge,
  dataTable,
  h,
  iconButton,
  memberHero,
  openModal,
  selectField,
  tableFilter,
  toast,
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

function messageOf(e, fallback) {
  const own = ["22023", "42501", "CP422"].includes(e?.code) && e.cause?.message;
  return own || e?.message || fallback;
}

function splitRankLabel(rank) {
  const match = String(rank ?? "").match(/^(.*?)\s*\((\d\.\d{3}\s*[–-]\s*\d\.\d{3})\)$/);
  return match
    ? { name: match[1].trim(), band: match[2].replace(/\s+/g, "") }
    : { name: rank, band: null };
}

export function createRankingPages({ api, client, session }) {
  function historyTable(rows, state, onRetry, filter) {
    const table = dataTable({
      filter,
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
    const page = h("div", { class: "page member-ranking-page" });
    const tabsHost = h("div", {});
    const body = h("div", { class: "ranking-body" });
    const state = {
      tab: "ranking",
      status: "loading",
      list: [],
      categories: [],
      ranks: [],
      category: "",
      mine: [],
      mineStatus: "loading",
      points: [],
      pointsStatus: "loading",
      bands: [],
      photos: new Map(),
    };

    async function load() {
      state.status = state.list.length ? "refreshing" : "loading";
      draw();
      try {
        const [list, categories, bands] = await Promise.all([
          api.rpc("cpc_ranking_list", { p_category_id: state.category || null }),
          state.categories.length
            ? state.categories
            : api.read((c) =>
              c.from("categories").select("id,name").is("deleted_at", null)
                .order("sort_order")
            ),
          state.bands.length ? state.bands : loadRatingBands(api).catch(() => []),
        ]);
        state.bands = bands ?? [];
        const memberId = session?.getState().access?.member_id;
        state.list = (list ?? []).map((row, index) => ({
          ...row,
          position: index + 1,
        })).filter((row) => can("members.read") || row.member_id === memberId);
        state.categories = categories ?? [];
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

    async function loadRanks() {
      if (state.ranks.length) return;
      const rows = await api.read((c) =>
        c.from("ranks").select(
          "id,name,sort_order,ladder:rank_ladders(category:categories(name,sort_order))",
        ).is("deleted_at", null)
      ) ?? [];
      state.ranks = rows.sort((a, b) =>
        (a.ladder?.category?.sort_order ?? 0) -
          (b.ladder?.category?.sort_order ?? 0) || a.sort_order - b.sort_order
      );
    }

    // ------------------------------------------------------------ modals
    const errorLine = () =>
      h("p", { class: "field-error form-error", role: "alert", hidden: true });

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

    async function overrideModal(row) {
      try {
        await loadRanks();
      } catch {
        toast("The ranks could not be loaded.", { tone: "danger" });
        return;
      }
      const key = api.newKey();
      const error = errorLine();
      const select = h(
        "select",
        { class: "input select-input", id: "ov-rank", name: "rank_id" },
        ...state.ranks.map((r) =>
          h(
            "option",
            { value: r.id, selected: r.id === row.rank_id },
            `${r.ladder?.category?.name ?? ""} · ${r.name}`,
          )
        ),
      );
      return openModal({
        title: "Change Rank by Hand",
        eyebrow: `${row.display_name} · now ${row.rank_name}`,
        icon: "medal",
        confirmLabel: "Set Rank",
        destructive: true,
        body: h(
          "div",
          { class: "stack" },
          h(
            "p",
            { class: "muted" },
            "This overrides the rank rules. It is kept in the member's rank history and the audit log. You cannot change your own rank.",
          ),
          h(
            "div",
            { class: "field" },
            h("label", { for: "ov-rank" }, "New Rank *"),
            select,
          ),
          h(
            "div",
            { class: "field" },
            h("label", { for: "ov-reason" }, "Reason *"),
            h("textarea", {
              class: "input textarea",
              id: "ov-reason",
              name: "reason",
              rows: 3,
              maxlength: 500,
              required: true,
            }),
          ),
          error,
        ),
        onConfirm: async (form) => {
          const reason = String(form.get("reason") ?? "").trim();
          const fail = (m) => {
            error.textContent = m;
            error.hidden = false;
            return false;
          };
          if (reason.length < 3) {
            return fail("Give a reason of at least 3 characters.");
          }
          try {
            await api.rpc("override_member_rank", {
              p_member_id: row.member_id,
              p_rank_id: String(form.get("rank_id")),
              p_reason: reason,
              p_key: key,
            });
            toast("Rank changed.", { tone: "success" });
            await load();
          } catch (e) {
            return fail(messageOf(e, "That did not work. Try again."));
          }
        },
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
          align: "center",
          render: (r) => {
            if (!r.rank_name) return badge("No rank yet", "neutral");
            const rank = splitRankLabel(r.rank_name);
            return h(
              "div",
              { class: "ranking-rank-value" },
              badge(rank.name, "success"),
              rank.band
                ? h("span", { class: "ranking-rank-band sub" }, rank.band)
                : null,
            );
          },
        },
        {
          key: "since",
          label: "Since",
          render: (r) => r.since ? formatDateTime(r.since) : h("span", { class: "sub" }, "—"),
        },
      ];
      if (staff) {
        columns.push({
          key: "actions",
          label: "Action",
          align: "center",
          actionCount: can("ranks.override") ? 4 : 2,
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
              can("ranks.override")
                ? iconButton({
                  label: `Change the rank of ${r.display_name}`,
                  icon: "edit",
                  variant: "edit",
                  onClick: () => overrideModal(r),
                })
                : null,
            ),
        });
      }
      const filter = h(
        "div",
        { class: "ranking-category-filter" },
        selectField({
          id: "rk-cat",
          ariaLabel: "Filter ranking by category",
          value: state.category,
          options: [
            { value: "", label: "All Categories" },
            ...state.categories.map((c) => ({ value: c.id, label: c.name })),
          ],
          onChange: (e) => {
            state.category = e.target.value;
            load();
          },
        }),
      );
      return h(
        "div",
        { class: "stack" },
        dataTable({
          searchState: state,
          filter: tabsHost,
          searchActions: filter,
          schema: { columns },
          rows: state.list,
          state: state.status === "refreshing" ? "ready" : state.status,
          ariaLabel: "Ranking",
          onRetry: load,
          emptyTitle: can("members.read") ? "No players yet" : "No rank to show",
          emptyText: can("members.read")
            ? "Active members appear here with their Singles and Doubles ratings and rank."
            : "Your rank will appear here once assigned and matching the selected category.",
        }),
      );
    }

    function draw() {
      tabsHost.replaceChildren(tableFilter({
        activeId: state.tab,
        tabs: [
          { id: "ranking", label: "Ranking", badge: state.list.length },
          { id: "mine", label: "My Rank History", badge: state.mine.length },
          { id: "points", label: "My Rating History", badge: state.points.length },
        ],
        onChange: (id) => {
          state.tab = id;
          draw();
        },
      }));
      body.replaceChildren(
        state.tab === "ranking"
          ? rankingView()
          : state.tab === "points"
          ? pointsHistoryTable(
            state.points,
            state.pointsStatus === "refreshing" ? "ready" : state.pointsStatus,
            loadPoints,
            tabsHost,
          )
          : historyTable(
            state.mine,
            state.mineStatus === "refreshing" ? "ready" : state.mineStatus,
            loadMine,
            tabsHost,
          ),
      );
    }

    page.append(
      memberHero({
        iconName: "medal",
        eyebrow: "Club",
        title: "Ranking",
        chip: "Ratings, Ranks and History",
        titleBadge: true,
        description:
          can("members.read")
            ? "Every player by Singles and Doubles rating, highest first, and how ratings and ranks have changed."
            : "Your Singles and Doubles ratings, current rank and how they have changed.",
      }),
      ...(can("members.read") ? [cpcAdminPanel({ api, onChange: load })] : []),
      body,
    );
    // both lists load up front so each tab's count is right before it is opened
    load();
    loadMine();
    loadPoints();
    return page;
  }

  return { rankingPage };
}
