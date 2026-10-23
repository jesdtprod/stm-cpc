// Member import page (PLAN 4.5): the report of each import and the rows that need a look.
// The file itself is imported with the secure import tool (docs/SECURITY.md), so the member list never travels
// through the web; this page shows the counts and the row numbers and codes it left behind. Marking an issue as
// reviewed goes through resolve_import_issue (permissioned, idempotent, audited).
import {
  badge,
  button,
  dataTable,
  h,
  iconButton,
  kpiCard,
  openModal,
  pageHeader,
  pagination,
  tabs,
  toast,
} from "./ui.js";
import { can } from "./lib/permissions.js";
import { formatDateTime } from "./lib/dates.js";

const PAGE_SIZE = 25;
const ISSUE_LABEL = {
  duplicate_member_no: "Shared member ID",
  invalid_member_no: "Member ID not in the right format",
  member_no_normalized: "Member ID tidied up",
  invalid_birth_date: "Birth date missing or not valid (no account yet)",
  duplicate_rfid_cleared: "Card code used twice (cleared)",
  invalid_email: "Email address not valid",
};
const TABS = [
  { id: "open", label: "Needs review" },
  { id: "done", label: "Reviewed" },
  { id: "batches", label: "Import history" },
];

export function createImportPages({ api }) {
  function importPage() {
    const state = {
      tab: "open",
      page: 1,
      rows: [],
      total: 0,
      status: "loading",
      latest: null,
      openCount: null,
    };
    const page = h("div", { class: "page" });
    const kpis = h("div", { class: "kpis" });
    const tabsHost = h("div", {});
    const tableHost = h("div", { class: "card" });
    const pagerHost = h("div", {});

    async function load() {
      state.status = "loading";
      draw();
      try {
        if (state.tab === "batches") {
          const { data, error, count } = await rangeQuery((c) =>
            c.from("import_batches").select(
              "id,created_at,row_count,created_count,skipped_count,held_back_count,failed_count,status",
              { count: "exact" },
            ).order("created_at", { ascending: false })
          );
          if (error) throw error;
          state.rows = data ?? [];
          state.total = count ?? 0;
        } else {
          const { data, error, count } = await rangeQuery((c) => {
            let q = c.from("member_import_issues").select(
              "id,source_row,member_no_claimed,issue_code,detail,resolved_at,meta",
              { count: "exact" },
            ).is("deleted_at", null);
            q = state.tab === "open"
              ? q.is("resolved_at", null)
              : q.not("resolved_at", "is", null);
            return q.order("source_row");
          });
          if (error) throw error;
          state.rows = data ?? [];
          state.total = count ?? 0;
        }
        state.status = "ready";
      } catch {
        state.status = "error";
      }
      draw();
    }

    // api.read returns data only; the page needs the count too, so the query is run through the same retry wrapper.
    async function rangeQuery(build) {
      let out = null;
      await api.read((c) => {
        const q = build(c).range(
          (state.page - 1) * PAGE_SIZE,
          state.page * PAGE_SIZE - 1,
        );
        return q.then((r) => {
          out = r;
          return { data: r.data, error: r.error };
        });
      });
      return out;
    }

    async function loadSummary() {
      try {
        const latest = await api.read((c) =>
          c.from("import_batches").select(
            "created_at,row_count,created_count,skipped_count,held_back_count,failed_count",
          ).order("created_at", { ascending: false }).limit(1)
        );
        state.latest = latest?.[0] ?? null;
        let openResult = null;
        await api.read((c) =>
          c.from("member_import_issues").select("id", {
            count: "exact",
            head: true,
          }).is("deleted_at", null).is("resolved_at", null).then((r) => {
            openResult = r;
            return { data: r.data, error: r.error };
          })
        );
        state.openCount = openResult?.count ?? null;
      } catch { /* the summary is optional */ }
      drawKpis();
    }

    function drawKpis() {
      const l = state.latest;
      kpis.replaceChildren(
        kpiCard("Last import", l ? formatDateTime(l.created_at) : "—"),
        kpiCard("Rows in the file", l?.row_count ?? "—"),
        kpiCard("Members created", l?.created_count ?? "—"),
        kpiCard(
          "Skipped, held back or failed",
          l ? l.skipped_count + l.held_back_count + l.failed_count : "—",
        ),
      );
    }

    function resolveModal(row) {
      const key = api.newKey();
      const error = h("p", {
        class: "field-error form-error",
        role: "alert",
        hidden: true,
      });
      return openModal({
        title: "Mark as reviewed",
        eyebrow: `Row ${row.source_row}: ${
          ISSUE_LABEL[row.issue_code] ?? row.issue_code
        }`,
        icon: "check",
        confirmLabel: "Mark reviewed",
        body: h(
          "div",
          { class: "stack" },
          h(
            "p",
            {},
            "Use this when the row has been looked at and nothing more needs doing.",
          ),
          h(
            "div",
            { class: "field" },
            h("label", { for: "iss-note" }, "Note (optional)"),
            h("textarea", {
              class: "input textarea",
              id: "iss-note",
              name: "note",
              rows: 3,
              maxlength: 500,
            }),
          ),
          error,
        ),
        onConfirm: async (form) => {
          try {
            await api.rpc("resolve_import_issue", {
              p_issue_id: row.id,
              p_note: String(form.get("note") ?? "").trim() || null,
              p_key: key,
            });
            toast("Marked as reviewed.", { tone: "success" });
            await load();
            await loadSummary();
          } catch (e) {
            error.textContent = e.cause?.message || e.message ||
              "That did not work. Please try again.";
            error.hidden = false;
            return false;
          }
        },
      });
    }

    const issueSchema = {
      columns: [
        {
          key: "row",
          label: "Row",
          align: "right",
          render: (r) => String(r.source_row),
        },
        {
          key: "issue",
          label: "Issue",
          render: (r) =>
            h(
              "span",
              {},
              ISSUE_LABEL[r.issue_code] ?? r.issue_code,
              r.detail ? h("span", { class: "sub" }, r.detail) : null,
            ),
        },
        {
          key: "no",
          label: "Member ID in the file",
          render: (r) => r.member_no_claimed ?? "—",
        },
        {
          key: "status",
          label: "Status",
          render: (r) =>
            r.resolved_at
              ? h(
                "span",
                {},
                badge("Reviewed", "success"),
                r.meta?.resolution_note
                  ? h("span", { class: "sub" }, r.meta.resolution_note)
                  : null,
              )
              : badge("Needs review", "warning"),
        },
        {
          key: "actions",
          label: "Action",
          align: "center",
          render: (r) =>
            !r.resolved_at && can("members.review_import")
              ? iconButton({
                label: `Mark row ${r.source_row} as reviewed`,
                icon: "check",
                onClick: () => resolveModal(r),
              })
              : "—",
        },
      ],
    };
    const batchSchema = {
      columns: [
        {
          key: "when",
          label: "Imported",
          render: (r) => formatDateTime(r.created_at),
        },
        {
          key: "rows",
          label: "Rows",
          align: "right",
          render: (r) => String(r.row_count),
        },
        {
          key: "created",
          label: "Created",
          align: "right",
          render: (r) => String(r.created_count),
        },
        {
          key: "skipped",
          label: "Skipped",
          align: "right",
          render: (r) => String(r.skipped_count),
        },
        {
          key: "held",
          label: "Held back",
          align: "right",
          render: (r) => String(r.held_back_count),
        },
        {
          key: "failed",
          label: "Failed",
          align: "right",
          render: (r) => String(r.failed_count),
        },
        {
          key: "status",
          label: "Result",
          render: (r) =>
            badge(
              {
                completed: "Completed",
                running: "Running",
                failed: "Failed",
              }[r.status] ?? r.status,
              {
                completed: "success",
                running: "warning",
                failed: "danger",
              }[r.status] ?? "neutral",
            ),
        },
      ],
    };

    function draw() {
      tabsHost.replaceChildren(tabs({
        activeId: state.tab,
        tabs: TABS.map((t) => ({
          ...t,
          badge: t.id === "open" && state.openCount
            ? String(state.openCount)
            : undefined,
        })),
        onChange: (id) => {
          state.tab = id;
          state.page = 1;
          load();
        },
      }));
      tableHost.replaceChildren(dataTable({
        schema: state.tab === "batches" ? batchSchema : issueSchema,
        rows: state.rows,
        state: state.status,
        ariaLabel: state.tab === "batches" ? "Import history" : "Import issues",
        onRetry: load,
        emptyTitle: state.tab === "open"
          ? "Nothing needs review"
          : (state.tab === "done" ? "Nothing reviewed yet" : "No imports yet"),
        emptyText: state.tab === "open"
          ? "Rows the import could not handle on its own appear here."
          : "",
      }));
      pagerHost.replaceChildren(
        state.status === "ready" && state.total > PAGE_SIZE
          ? pagination({
            page: state.page,
            pageSize: PAGE_SIZE,
            total: state.total,
            onPage: (p) => {
              state.page = p;
              load();
            },
          })
          : "",
      );
    }

    page.append(
      pageHeader({
        icon: "upload",
        eyebrow: "Admin",
        title: "Member import",
        description:
          "What the import did, and the rows that need a look. The member file is imported with the secure import tool, not through the web.",
        actions: [
          button({
            label: "Members",
            icon: "user",
            onClick: () => (location.hash = "#/admin/members"),
          }),
        ],
      }),
      kpis,
      tabsHost,
      tableHost,
      pagerHost,
    );
    drawKpis();
    load();
    loadSummary();
    return page;
  }

  return { importPage };
}
