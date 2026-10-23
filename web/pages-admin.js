// Admin pages (PLAN 3.5): the members list with the approval flow (approve, reject, reconsider, suspend, restore).
// Every decision goes through the decide_member function, which checks the permission, takes an idempotency key
// (one per intent, reused if the request is retried), and writes the audit row. The buttons shown here follow the
// caller's permissions, but that is convenience only: the database decides.
import {
  badge,
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

const TABS = [
  {
    id: "pending",
    label: "Waiting for approval",
    statuses: ["pending_approval"],
  },
  { id: "active", label: "Active", statuses: ["active"] },
  { id: "suspended", label: "Suspended", statuses: ["suspended"] },
  { id: "rejected", label: "Rejected", statuses: ["rejected"] },
  { id: "archived", label: "Archived", statuses: ["archived"] },
  { id: "new", label: "Not signed in yet", statuses: ["imported", "invited"] },
  {
    id: "all",
    label: "All",
    statuses: [
      "imported",
      "invited",
      "pending_approval",
      "active",
      "rejected",
      "suspended",
      "archived",
    ],
  },
  {
    id: "deleted",
    label: "Deleted",
    deleted: true,
    statuses: [
      "imported",
      "invited",
      "pending_approval",
      "active",
      "rejected",
      "suspended",
      "archived",
    ],
  },
];

const STATUS_LABEL = {
  imported: "not signed in",
  invited: "profile incomplete",
  pending_approval: "waiting",
  active: "active",
  rejected: "rejected",
  suspended: "suspended",
  archived: "archived",
};
const STATUS_TONE = {
  imported: "neutral",
  invited: "neutral",
  pending_approval: "warning",
  active: "success",
  rejected: "danger",
  suspended: "danger",
  archived: "neutral",
};
const FLAG_LABEL = {
  possible_duplicate_name_dob: "Same name and birth date as another member",
  possible_duplicate_mobile: "Same mobile number as another member",
  minor: "Under 18: needs a guardian and a signed waiver",
};
const FLAG_SHORT = {
  possible_duplicate_name_dob: "duplicate?",
  possible_duplicate_mobile: "same mobile",
  minor: "under 18",
};

const SELECT =
  "id,member_no,status,status_reason,joined_on,created_at,profile_id,deleted_at,delete_reason," +
  "persons!inner(display_name,mobile,email,gender,date_of_birth,address_text,emergency_name,emergency_relationship,emergency_phone)," +
  "flags:member_review_flags!member_review_flags_member_id_fkey(kind,resolved_at)";

const openFlags = (row) => (row.flags ?? []).filter((f) => !f.resolved_at);
const cleanTerm = (t) => t.replace(/[%_,()*]/g, " ").trim().slice(0, 60);

export function createAdminPages({ client, api }) {
  async function countOf(statuses) {
    const { count, error } = await client.from("members").select("id", {
      count: "exact",
      head: true,
    }).in("status", statuses).is("deleted_at", null);
    if (error) throw error;
    return count ?? 0;
  }

  async function loadPage({ statuses, term, page, deleted = false }) {
    let q = client.from("members").select(SELECT, { count: "exact" }).in(
      "status",
      statuses,
    ).order("created_at", { ascending: false })
      .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);
    q = deleted ? q.not("deleted_at", "is", null) : q.is("deleted_at", null);
    const t = cleanTerm(term);
    if (t) {
      q = /^(cpc|\d)/i.test(t)
        ? q.ilike("member_no", `%${t}%`)
        : q.ilike("persons.display_name", `%${t}%`);
    }
    const { data, error, count } = await q;
    if (error) throw error;
    return { rows: data ?? [], total: count ?? 0 };
  }

  // ------------------------------------------------------------------ modals
  const reasonField = (label, required) =>
    h(
      "div",
      { class: "field" },
      h("label", { for: "decision-reason" }, label + (required ? " *" : "")),
      h("textarea", {
        class: "input textarea",
        id: "decision-reason",
        name: "reason",
        rows: 3,
        maxlength: 500,
        required,
      }),
    );

  /** Runs a decision; on failure the message is shown inside the modal and it stays open. */
  function decide(
    {
      action,
      row,
      title,
      verb,
      destructive = false,
      body,
      extra = () => ({}),
      call = null,
      reasonRequired,
      onDone,
    },
  ) {
    const key = api.newKey(); // one key per intent: a retry of the same click is not a second decision
    const error = h("p", {
      class: "field-error form-error",
      role: "alert",
      hidden: true,
    });
    return openModal({
      title,
      eyebrow: `${row.persons.display_name} · ${row.member_no}`,
      icon: destructive ? "alert" : "check",
      body: h("div", { class: "stack" }, body, error),
      confirmLabel: verb,
      destructive,
      onConfirm: async (form) => {
        const reason = String(form.get("reason") ?? "").trim();
        if (reasonRequired && reason.length < 3) {
          error.textContent = "Please give a reason (at least 3 characters).";
          error.hidden = false;
          return false;
        }
        try {
          await (call ? call({ reason, key }) : api.rpc("decide_member", {
            p_action: action,
            p_member_id: row.id,
            p_reason: reason || null,
            p_key: key,
            ...extra(form),
          }));
          toast(`${row.persons.display_name}: ${verb.toLowerCase()} done.`, {
            tone: "success",
          });
          await onDone();
        } catch (e) {
          // The decision function's own messages (open review flags, wrong state, no permission) are written for
          // people, so they are shown as they are; anything else gets the generic wording.
          const own =
            ["22023", "42501", "23503", "CP422", "CP409"].includes(e.code) &&
            e.cause?.message;
          error.textContent = own || e.message ||
            "That did not work. Please try again.";
          error.hidden = false;
          return false;
        }
      },
    });
  }

  async function approveModal(row, onDone) {
    const flags = openFlags(row);
    let ranks = [];
    try {
      ranks = await api.read((c) =>
        c.from("ranks").select(
          "id,name,sort_order,rank_ladders!inner(categories!inner(name,sort_order))",
        ).is("deleted_at", null).order("sort_order")
      );
    } catch { /* the rank list is optional */ }
    ranks.sort((a, b) =>
      (a.rank_ladders.categories.sort_order -
        b.rank_ladders.categories.sort_order) || (a.sort_order - b.sort_order)
    );
    const rankSelect = h(
      "select",
      { class: "input", id: "decision-rank", name: "rank" },
      h("option", { value: "" }, "No starting rank yet"),
      ...ranks.map((r) => h("option", { value: r.id }, r.name)),
    );
    const ack = h("input", {
      type: "checkbox",
      id: "decision-ack",
      name: "ack",
    });
    decide({
      action: "approve",
      row,
      title: "Approve this member",
      verb: "Approve",
      onDone,
      reasonRequired: false,
      body: h(
        "div",
        { class: "stack" },
        h(
          "p",
          {},
          "They will be able to book courts and join events right away.",
        ),
        flags.length
          ? h(
            "div",
            { class: "alert-box" },
            h("strong", {}, "Review flags"),
            h(
              "ul",
              {},
              flags.map((f) => h("li", {}, FLAG_LABEL[f.kind] ?? f.kind)),
            ),
            h(
              "div",
              { class: "check" },
              ack,
              h(
                "label",
                { for: "decision-ack" },
                "I have reviewed these flags.",
              ),
            ),
          )
          : null,
        h(
          "div",
          { class: "field" },
          h("label", { for: "decision-rank" }, "Starting rank (optional)"),
          rankSelect,
        ),
        reasonField("Note (optional)", false),
      ),
      extra: (form) => ({
        p_acknowledge_flags: form.get("ack") === "on",
        p_rank_id: form.get("rank") || null,
      }),
    });
  }

  function reasonModal(action, row, text, onDone) {
    const copy = {
      reject: {
        title: "Reject this application",
        verb: "Reject",
        destructive: true,
        label: "Reason (the member is not shown this)",
      },
      reconsider: {
        title: "Reconsider this application",
        verb: "Reconsider",
        destructive: false,
        label: "Reason",
      },
      suspend: {
        title: "Suspend this member",
        verb: "Suspend",
        destructive: true,
        label: "Reason",
      },
      restore: {
        title: "Restore this member",
        verb: "Restore",
        destructive: false,
        label: "Reason",
      },
      archive: {
        title: "Archive this member",
        verb: "Archive",
        destructive: true,
        label: "Reason",
      },
      delete: {
        title: "Delete this member record",
        verb: "Delete",
        destructive: true,
        label: "Reason",
      },
    }[action];
    const call = action === "archive"
      ? ({ reason, key }) =>
        api.rpc("archive_member", {
          p_member_id: row.id,
          p_reason: reason,
          p_key: key,
        })
      : (action === "delete"
        ? ({ reason, key }) =>
          api.rpc("soft_delete", {
            p_table: "members",
            p_id: row.id,
            p_reason: reason,
            p_key: key,
          })
        : null);
    decide({
      action,
      row,
      title: copy.title,
      verb: copy.verb,
      destructive: copy.destructive,
      call,
      reasonRequired: true,
      onDone,
      body: h(
        "div",
        { class: "stack" },
        h("p", {}, text),
        reasonField(copy.label, true),
      ),
    });
  }

  function detailsModal(row) {
    const p = row.persons;
    const line = (label, value) =>
      h("div", { class: "kv" }, h("dt", {}, label), h("dd", {}, value || "—"));
    const flags = row.flags ?? [];
    const history = h("div", { class: "muted" }, "Loading history…");
    const rank = h("span", {}, "Loading…");
    openModal({
      title: p.display_name,
      eyebrow: row.member_no,
      icon: "user",
      confirmLabel: "Close",
      cancelLabel: "Close",
      body: h(
        "dl",
        { class: "details" },
        line("Status", STATUS_LABEL[row.status] ?? row.status),
        line("Reason on record", row.status_reason),
        line("Mobile", p.mobile),
        line("Email", p.email),
        line("Date of birth", p.date_of_birth),
        line("Gender", p.gender),
        line("Address", p.address_text),
        line(
          "Emergency contact",
          [p.emergency_name, p.emergency_relationship, p.emergency_phone]
            .filter(Boolean).join(" · "),
        ),
        line(
          "Account",
          row.profile_id
            ? "has an account"
            : "no account yet (waiting for a birth date)",
        ),
        line(
          "Review flags",
          flags.length
            ? flags.map((f) =>
              `${FLAG_LABEL[f.kind] ?? f.kind}${
                f.resolved_at ? " (resolved)" : ""
              }`
            ).join("; ")
            : "none",
        ),
        h(
          "div",
          { class: "kv" },
          h("dt", {}, "Current rank"),
          h("dd", {}, rank),
        ),
        row.deleted_at
          ? line("Record", `deleted: ${row.delete_reason ?? ""}`)
          : null,
        h(
          "div",
          { class: "kv kv-wide" },
          h("dt", {}, "History"),
          h("dd", {}, history),
        ),
      ),
      onConfirm: () => {},
    });
    loadRank(row).then((text) => (rank.textContent = text)).catch(
      () => (rank.textContent = "—"),
    );
    loadHistory(row).then((items) => {
      history.className = "";
      history.replaceChildren(
        ...(items.length
          ? items.map((e) =>
            h(
              "div",
              {},
              `${formatDateTime(e.occurred_at)}: ${
                e.from_status
                  ? `${STATUS_LABEL[e.from_status] ?? e.from_status} to `
                  : ""
              }${STATUS_LABEL[e.to_status] ?? e.to_status}${
                e.reason ? ` (${e.reason})` : ""
              }`,
            )
          )
          : ["No changes recorded."]),
      );
    }).catch(() => {
      history.textContent = "The history could not be loaded.";
    });
  }

  async function loadRank(row) {
    const r = await api.read((c) =>
      c.from("member_ranks").select(
        "ranks(name,rank_ladders(categories(name)))",
      ).eq("member_id", row.id).is("deleted_at", null).maybeSingle()
    );
    const rk = r?.ranks;
    return rk
      ? `${rk.rank_ladders?.categories?.name ?? ""}: ${rk.name}`
      : "Not ranked yet";
  }

  async function loadHistory(row) {
    return await api.read((c) =>
      c.from("member_status_events").select(
        "from_status,to_status,reason,occurred_at",
      ).eq("member_id", row.id).order("occurred_at", { ascending: false })
        .limit(20)
    ) ?? [];
  }

  // ------------------------------------------------------------------ the page
  function membersPage() {
    const state = {
      tab: "pending",
      term: "",
      page: 1,
      rows: [],
      total: 0,
      status: "loading",
    };
    const counts = { pending: null, active: null, suspended: null };
    const root = h("div", { class: "page" });

    const kpis = h("div", { class: "kpis" });
    const tabsHost = h("div", {});
    const tableHost = h("div", { class: "card" });
    const pagerHost = h("div", {});
    let timer = null;

    const search = h("input", {
      class: "input",
      id: "members-search",
      type: "search",
      placeholder: "Search by name or member ID…",
      "aria-label": "Search members",
      onInput: (e) => {
        clearTimeout(timer);
        timer = setTimeout(() => {
          state.term = e.target.value;
          state.page = 1;
          load();
        }, 300);
      },
    });

    const actionsFor = (row) => {
      const buttons = [
        iconButton({
          label: "View details",
          icon: "info",
          onClick: () => detailsModal(row),
        }),
      ];
      const approve = can("members.approve");
      const suspend = can("members.suspend");
      const edit = can("members.update");
      if (row.deleted_at) {
        if (edit) {
          buttons.push(iconButton({
            label: "Restore the record",
            icon: "refresh",
            onClick: async () => {
              try {
                await api.rpc("restore_row", {
                  p_table: "members",
                  p_id: row.id,
                  p_key: api.newKey(),
                });
                toast(`${row.persons.display_name}: record restored.`, {
                  tone: "success",
                });
                await refresh();
              } catch (e) {
                toast(e.cause?.message || e.message || "That did not work.", {
                  tone: "error",
                });
              }
            },
          }));
        }
        return h("div", { class: "row-actions" }, buttons);
      }
      if (row.status === "pending_approval" && approve) {
        buttons.push(
          iconButton({
            label: "Approve",
            icon: "check",
            onClick: () => approveModal(row, refresh),
          }),
          iconButton({
            label: "Reject",
            icon: "x",
            onClick: () =>
              reasonModal(
                "reject",
                row,
                "The application will be marked rejected. You can reconsider it later.",
                refresh,
              ),
          }),
        );
      }
      if (row.status === "rejected" && approve) {
        buttons.push(iconButton({
          label: "Reconsider",
          icon: "refresh",
          onClick: () =>
            reasonModal(
              "reconsider",
              row,
              "The application goes back to waiting for approval.",
              refresh,
            ),
        }));
      }
      if (row.status === "active" && suspend) {
        buttons.push(iconButton({
          label: "Suspend",
          icon: "alert",
          onClick: () =>
            reasonModal(
              "suspend",
              row,
              "They lose access at once. You can restore them later.",
              refresh,
            ),
        }));
      }
      if (row.status === "suspended" && suspend) {
        buttons.push(iconButton({
          label: "Restore",
          icon: "refresh",
          onClick: () =>
            reasonModal("restore", row, "They get their access back.", refresh),
        }));
      }
      if (suspend && row.status !== "archived") {
        buttons.push(iconButton({
          label: "Archive",
          icon: "inbox",
          onClick: () =>
            reasonModal(
              "archive",
              row,
              "Archived is final: they lose access and cannot be brought back to active. Their history is kept.",
              refresh,
            ),
        }));
      }
      if (
        edit &&
        ["archived", "rejected", "imported", "invited"].includes(row.status)
      ) {
        buttons.push(iconButton({
          label: "Delete the record",
          icon: "trash",
          variant: "danger",
          onClick: () =>
            reasonModal(
              "delete",
              row,
              "The record is hidden from every list. You can restore it from the Deleted tab.",
              refresh,
            ),
        }));
      }
      return h("div", { class: "row-actions" }, buttons);
    };

    const schema = {
      columns: [
        {
          key: "name",
          label: "Member",
          render: (r) =>
            h(
              "span",
              {},
              r.persons.display_name,
              h("span", { class: "sub" }, r.member_no),
            ),
        },
        {
          key: "mobile",
          label: "Mobile",
          render: (r) => r.persons.mobile ?? "—",
        },
        {
          key: "status",
          label: "Status",
          render: (r) =>
            badge(
              STATUS_LABEL[r.status] ?? r.status,
              STATUS_TONE[r.status] ?? "neutral",
            ),
        },
        {
          key: "flags",
          label: "Review",
          render: (r) => {
            const open = openFlags(r);
            return open.length
              ? h(
                "span",
                { class: "badges" },
                open.map((f) => badge(FLAG_SHORT[f.kind] ?? f.kind, "warning")),
              )
              : "—";
          },
        },
        {
          key: "joined",
          label: "Added",
          render: (r) => (r.joined_on ?? r.created_at ?? "").slice(0, 10),
        },
        {
          key: "actions",
          label: "Action",
          align: "center",
          render: actionsFor,
        },
      ],
    };

    function drawTabs() {
      tabsHost.replaceChildren(tabs({
        activeId: state.tab,
        tabs: TABS.map((t) => ({
          id: t.id,
          label: t.label,
          badge: counts[t.id] ? String(counts[t.id]) : undefined,
        })),
        onChange: (id) => {
          state.tab = id;
          state.page = 1;
          load();
        },
      }));
    }

    function drawKpis() {
      kpis.replaceChildren(
        kpiCard("Waiting for approval", counts.pending ?? "—"),
        kpiCard("Active members", counts.active ?? "—"),
        kpiCard("Suspended", counts.suspended ?? "—"),
      );
    }

    function draw() {
      tableHost.replaceChildren(dataTable({
        schema,
        rows: state.rows,
        state: state.status,
        hasFilters: Boolean(state.term),
        onRetry: load,
        onReset: () => {
          search.value = "";
          state.term = "";
          load();
        },
        emptyTitle: state.term ? "No members match your search" : "Nobody here",
        emptyText: state.term
          ? "Try a different name or ID."
          : "Members will appear in this list.",
        resetLabel: "Clear search",
        ariaLabel: "Members",
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

    async function loadCounts() {
      try {
        [counts.pending, counts.active, counts.suspended] = await Promise.all([
          countOf(["pending_approval"]),
          countOf(["active"]),
          countOf(["suspended"]),
        ]);
      } catch { /* the numbers are a convenience */ }
      drawKpis();
      drawTabs();
    }

    async function load() {
      state.status = "loading";
      draw();
      try {
        const { rows, total } = await loadPage({
          statuses: TABS.find((t) => t.id === state.tab).statuses,
          deleted: Boolean(TABS.find((t) => t.id === state.tab).deleted),
          term: state.term,
          page: state.page,
        });
        state.rows = rows;
        state.total = total;
        state.status = "ready";
      } catch {
        state.status = "error";
      }
      draw();
    }

    async function refresh() {
      await Promise.all([load(), loadCounts()]);
    }

    root.append(
      pageHeader({
        icon: "user",
        eyebrow: "Admin",
        title: "Members",
        description:
          "Approve new members, and suspend or restore existing ones. Every decision is recorded.",
      }),
      kpis,
      tabsHost,
      h(
        "div",
        { class: "toolbar" },
        h(
          "div",
          { class: "grow field" },
          h("label", { for: "members-search", class: "muted" }, "Search"),
          search,
        ),
      ),
      tableHost,
      pagerHost,
    );
    drawKpis();
    drawTabs();
    draw();
    refresh();
    return root;
  }

  return { membersPage };
}
