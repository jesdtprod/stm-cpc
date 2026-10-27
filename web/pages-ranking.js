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

function messageOf(e, fallback) {
  const own = ["22023", "42501", "CP422"].includes(e?.code) && e.cause?.message;
  return own || e?.message || fallback;
}

export function createRankingPages({ api }) {
  function historyTable(rows, state, onRetry, filter) {
    return dataTable({
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
            render: (r) =>
              h(
                "span",
                {},
                r.from_name === r.to_name
                  ? `${r.to_name} (no change)`
                  : r.from_name
                  ? `${r.from_name} → ${r.to_name}`
                  : `Set to ${r.to_name}`,
                r.is_reversal
                  ? badge("Reversal", "warning")
                  : r.reversed
                  ? badge("Reversed", "neutral")
                  : null,
              ),
          },
          {
            key: "why",
            label: "Why",
            render: (r) =>
              h(
                "span",
                {},
                r.reason ?? r.rule_name ?? "—",
                r.event_name
                  ? h(
                    "span",
                    { class: "sub" },
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
    };

    async function load() {
      state.status = state.list.length ? "refreshing" : "loading";
      draw();
      try {
        const [list, categories] = await Promise.all([
          api.rpc("ranking_list", { p_category_id: state.category || null }),
          state.categories.length
            ? state.categories
            : api.read((c) =>
              c.from("categories").select("id,name").is("deleted_at", null)
                .order("sort_order")
            ),
        ]);
        state.list = list ?? [];
        state.categories = categories ?? [];
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
          align: "right",
          width: 64,
          render: (r) => String(state.list.indexOf(r) + 1),
        },
        {
          key: "name",
          label: "Player",
          render: (r) => {
            const memberId = r.member_no || (r.member_id ? `CPC-${r.member_id.slice(-5).toUpperCase()}` : "");
            return h(
              "div",
              { class: "ranking-player-meta" },
              h("strong", { class: "ranking-player-name" }, r.display_name),
              memberId ? h("span", { class: "sub ranking-player-id" }, memberId) : null,
            );
          },
        },
        {
          key: "category",
          label: "Category",
          render: (r) => badge(r.category_name, "info"),
        },
        {
          key: "rank",
          label: "Rank",
          render: (r) => badge(r.rank_name, "success"),
        },
        {
          key: "since",
          label: "Since",
          render: (r) => formatDateTime(r.since),
        },
      ];
      if (staff) {
        columns.push({
          key: "actions",
          label: "Action",
          align: "center",
          actionCount: 2,
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
          label: "Category",
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
          emptyTitle: "No ranked players yet",
          emptyText: "Players appear here once they hold a rank.",
        }),
      );
    }

    function draw() {
      tabsHost.replaceChildren(tableFilter({
        activeId: state.tab,
        tabs: [
          { id: "ranking", label: "Ranking", badge: state.list.length },
          { id: "mine", label: "My Rank History", badge: state.mine.length },
        ],
        onChange: (id) => {
          state.tab = id;
          if (id === "mine" && state.mineStatus === "loading") loadMine();
          draw();
        },
      }));
      body.replaceChildren(
        state.tab === "ranking" ? rankingView() : historyTable(
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
        chip: "Ranks and History",
        titleBadge: true,
        description:
          "Every ranked player, highest first, and how ranks have changed.",
      }),
      body,
    );
    load();
    return page;
  }

  return { rankingPage };
}
