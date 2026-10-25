// Member import page (PLAN 4.5): the report of each import and the rows that need a look.
// The file itself is imported with the secure import tool (docs/SECURITY.md), so the member list never travels
// through the web; this page shows the counts and the row numbers and codes it left behind. Marking an issue as
// reviewed goes through resolve_import_issue (permissioned, idempotent, audited).
import {
  adminHero,
  adminStatCard,
  attachPagePattern,
  badge,
  button,
  dataTable,
  h,
  icon,
  iconButton,
  openModal,
  pagination,
  searchControl,
  selectField,
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
      term: "",
      page: 1,
      rows: [],
      total: 0,
      status: "loading",
      latest: null,
      openCount: null,
      summaryReady: false,
    };
    const page = h("div", {
      class: "page admin-dashboard admin-members-page admin-import-page",
    });
    attachPagePattern(page);
    const kpis = h("div", { class: "home-grid kpis is-quad" });
    const tableHost = h("div", { class: "table-host" });
    const pagerHost = h("div", {});
    let timer = null;

    const statusField = selectField({
      id: "import-status",
      value: state.tab,
      ariaLabel: "Filter import records",
      options: TABS.map((item) => ({ value: item.id, label: item.label })),
      onChange: (event) => {
        clearTimeout(timer);
        state.tab = event.target.value;
        state.term = search.value;
        state.page = 1;
        load();
      },
    });
    const statusFilter = h(
      "div",
      { class: "member-status-filter" },
      statusField,
    );

    function drawStatusFilter() {
      statusField.setOptions(
        TABS.map((item) => ({
          value: item.id,
          label: item.id === "open" && state.openCount != null
            ? `${item.label} (${state.openCount})`
            : item.label,
        })),
        state.tab,
      );
    }

    const search = searchControl({
      class: "input",
      id: "import-search",
      type: "search",
      placeholder: "Search by member ID, row, or issue…",
      "aria-label": "Search import records",
      onInput: (e) => {
        clearTimeout(timer);
        timer = setTimeout(() => {
          state.term = e.target.value;
          state.page = 1;
          draw();
        }, 250);
      },
    });
    const searchBox = search;

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
      state.summaryReady = true;
      drawKpis();
      drawStatusFilter();
    }

    function drawKpis() {
      const l = state.latest;
      const loading = !state.summaryReady;
      const problems = l
        ? l.skipped_count + l.held_back_count + l.failed_count
        : null;
      kpis.replaceChildren(
        adminStatCard({
          label: "Last import",
          value: l ? formatDateTime(l.created_at) : "—",
          hint: l ? "Most recent import run" : "No import has run yet",
          iconName: "calendar",
          tone: "teal",
          text: true,
          loading,
          pill: h("span", { class: "card-status-pill is-clean" }, "Latest"),
        }),
        adminStatCard({
          label: "Rows in the file",
          value: l?.row_count ?? "—",
          hint: "Rows read from the member file",
          iconName: "file",
          tone: "emerald",
          loading,
          pill: h("span", { class: "card-status-pill is-clean" }, "Rows"),
        }),
        adminStatCard({
          label: "Members created",
          value: l?.created_count ?? "—",
          hint: "Accounts made by the import",
          iconName: "user",
          tone: "emerald",
          loading,
          pill: h(
            "span",
            { class: "card-status-pill is-clean" },
            icon("check"),
            "Created",
          ),
        }),
        adminStatCard({
          label: "Skipped, held back or failed",
          value: problems ?? "—",
          hint: problems
            ? "Rows that did not become members"
            : "Every row was handled",
          iconName: "alert",
          tone: problems ? "amber" : "emerald",
          loading,
          pill: problems
            ? h(
              "span",
              { class: "card-status-pill is-attention" },
              h("span", { class: "pill-pulse-dot", "aria-hidden": "true" }),
              "Needs a look",
            )
            : h(
              "span",
              { class: "card-status-pill is-clean" },
              icon("check"),
              "All clear",
            ),
        }),
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
          key: "name",
          label: "Import row",
          render: (r) =>
            h(
              "div",
              { class: "member-cell" },
              h(
                "span",
                { class: "member-avatar is-icon", "aria-hidden": "true" },
                icon(r.resolved_at ? "check" : "alert"),
              ),
              h(
                "div",
                { class: "member-meta" },
                h("span", { class: "member-name" }, `Row ${r.source_row}`),
                h(
                  "span",
                  { class: "sub member-subtext" },
                  r.member_no_claimed ?? "No member ID",
                ),
              ),
            ),
        },
        {
          key: "issue",
          label: "Issue",
          skeleton: "stack",
          render: (r) =>
            h(
              "div",
              { class: "member-table-stack" },
              ISSUE_LABEL[r.issue_code] ?? r.issue_code,
              h(
                "span",
                { class: "sub" },
                r.detail || r.issue_code || "Import issue",
              ),
            ),
        },
        {
          key: "no",
          label: "Member ID in the file",
          skeleton: "stack",
          render: (r) =>
            h(
              "div",
              { class: "member-table-stack" },
              r.member_no_claimed ?? "—",
              h("span", { class: "sub" }, `Source row #${r.source_row}`),
            ),
        },
        {
          key: "status",
          label: "Status",
          skeleton: "badge-stack",
          render: (r) =>
            r.resolved_at
              ? h(
                "div",
                { class: "member-table-stack" },
                badge("Reviewed", "success"),
                h(
                  "span",
                  { class: "sub" },
                  r.meta?.resolution_note || "Marked as reviewed",
                ),
              )
              : h(
                "div",
                { class: "member-table-stack" },
                badge("Needs review", "warning"),
                h("span", { class: "sub" }, "Awaiting admin check"),
              ),
        },
        {
          key: "resolved",
          label: "Resolution",
          skeleton: "stack",
          render: (r) =>
            h(
              "div",
              { class: "member-table-stack" },
              r.resolved_at ? formatDateTime(r.resolved_at) : "Pending",
              h(
                "span",
                { class: "sub" },
                r.resolved_at ? "Reviewed" : "Not reviewed yet",
              ),
            ),
        },
        {
          key: "actions",
          label: "Action",
          align: "center",
          actionCount: 1,
          render: (r) =>
            !r.resolved_at && can("members.review_import")
              ? h(
                "div",
                { class: "row-actions" },
                iconButton({
                  label: `Mark row ${r.source_row} as reviewed`,
                  icon: "check",
                  size: "sm",
                  variant: "success",
                  onClick: () => resolveModal(r),
                }),
              )
              : "—",
        },
      ],
    };
    const batchSchema = {
      columns: [
        {
          key: "name",
          label: "Imported",
          render: (r) =>
            h(
              "div",
              { class: "member-cell" },
              h(
                "span",
                { class: "member-avatar is-icon", "aria-hidden": "true" },
                icon("file"),
              ),
              h(
                "div",
                { class: "member-meta" },
                h(
                  "span",
                  { class: "member-name" },
                  formatDateTime(r.created_at),
                ),
                h(
                  "span",
                  { class: "sub member-subtext" },
                  `${r.row_count} total rows`,
                ),
              ),
            ),
        },
        {
          key: "created",
          label: "Created",
          skeleton: "stack",
          render: (r) =>
            h(
              "div",
              { class: "member-table-stack" },
              String(r.created_count),
              h("span", { class: "sub" }, `of ${r.row_count} rows`),
            ),
        },
        {
          key: "skipped",
          label: "Skipped",
          skeleton: "stack",
          render: (r) =>
            h(
              "div",
              { class: "member-table-stack" },
              String(r.skipped_count),
              h("span", { class: "sub" }, "Already imported or skipped"),
            ),
        },
        {
          key: "held",
          label: "Held back / Failed",
          skeleton: "stack",
          render: (r) =>
            h(
              "div",
              { class: "member-table-stack" },
              `${r.held_back_count} held · ${r.failed_count} failed`,
              h("span", { class: "sub" }, "Flagged during import"),
            ),
        },
        {
          key: "status",
          label: "Result",
          skeleton: "badge-stack",
          render: (r) =>
            h(
              "div",
              { class: "member-table-stack" },
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
              h("span", { class: "sub" }, "Import batch status"),
            ),
        },
        {
          key: "actions",
          label: "Action",
          align: "center",
          actionCount: 1,
          render: () => "—",
        },
      ],
    };

    function filteredRows() {
      const q = state.term.trim().toLowerCase();
      if (!q) return state.rows;
      if (state.tab === "batches") {
        return state.rows.filter((r) =>
          formatDateTime(r.created_at).toLowerCase().includes(q) ||
          String(r.status ?? "").toLowerCase().includes(q) ||
          String(r.row_count ?? "").includes(q)
        );
      }
      return state.rows.filter((r) => {
        const label = ISSUE_LABEL[r.issue_code] ?? r.issue_code ?? "";
        return String(r.source_row ?? "").includes(q) ||
          String(r.member_no_claimed ?? "").toLowerCase().includes(q) ||
          String(r.issue_code ?? "").toLowerCase().includes(q) ||
          label.toLowerCase().includes(q) ||
          String(r.detail ?? "").toLowerCase().includes(q);
      });
    }

    function draw() {
      const rows = filteredRows();
      let emptyTitle = state.tab === "open"
        ? "Nothing needs review"
        : (state.tab === "done" ? "Nothing reviewed yet" : "No imports yet");
      let emptyText = state.tab === "open"
        ? "Rows the import could not handle on its own appear here."
        : "";
      if (state.term.trim()) {
        emptyTitle = `No records match "${state.term.trim()}"`;
        emptyText =
          "Try searching by another member ID, row number, or issue description.";
      }
      tableHost.replaceChildren(dataTable({
        schema: state.tab === "batches" ? batchSchema : issueSchema,
        rows,
        state: state.status,
        searchable: false,
        hasFilters: Boolean(state.term.trim()),
        ariaLabel: state.tab === "batches" ? "Import history" : "Import issues",
        onRetry: load,
        onReset: () => {
          clearTimeout(timer);
          search.value = "";
          state.term = "";
          state.page = 1;
          draw();
        },
        resetLabel: "Clear search",
        emptyTitle,
        emptyText,
      }));
      pagerHost.replaceChildren(
        state.status === "ready"
          ? pagination({
            page: state.page,
            pageSize: PAGE_SIZE,
            total: state.term.trim() ? rows.length : state.total,
            onPage: (p) => {
              state.page = p;
              load();
            },
          })
          : "",
      );
    }

    page.append(
      adminHero({
        title: "Member import",
        chip: "Import Management",
        description:
          "What the import did, and the rows that need a look. The member file is imported with the secure import tool, not through the web.",
        actions: [
          button({
            label: "Members",
            icon: "user",
            variant: "secondary",
            onClick: () => (location.hash = "#/admin/members"),
          }),
        ],
      }),
      kpis,
      h(
        "div",
        { class: "toolbar admin-members-toolbar" },
        searchBox,
        statusFilter,
      ),
      h(
        "div",
        { class: "member-directory-card" },
        tableHost,
        pagerHost,
      ),
    );
    drawKpis();
    drawStatusFilter();
    load();
    loadSummary();
    return page;
  }

  return { importPage };
}
