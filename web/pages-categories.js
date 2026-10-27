// Categories page (PLAN 4.2): the club's skill levels, in order. Admins add, edit, retire, delete and restore them.
//   * the table's own rules decide what is allowed (a code is unique among active categories; a category that still
//     has a rank ladder cannot be deleted), so this page only shows the database's answer in plain words
//   * create is idempotent: the new row's ID is made when the form opens and reused if Save is pressed again
//   * edit checks the row's version, so two admins cannot silently overwrite each other
//   * delete and restore go through soft_delete / restore_row (reason required, audited)
import {
  adminHero,
  attachPagePattern,
  badge,
  dataTable,
  DEFAULT_PAGE_SIZE,
  h,
  icon,
  iconButton,
  inputWithIcon,
  openModal,
  pagination,
  searchControl,
  tableFilter,
  toast,
} from "./ui.js";
import { button } from "./ui.js";

const SELECT =
  "id,code,name,description,eligibility_notes,sort_order,is_active,deleted_at,delete_reason,version," +
  "ladders:rank_ladders(id,deleted_at)";

const TABS = [
  { id: "active", label: "Active" },
  { id: "retired", label: "Retired" },
  { id: "deleted", label: "Deleted" },
];

const CODE_RE = /^[a-z0-9][a-z0-9_-]{0,31}$/;
const codeFrom = (name) =>
  name.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "").slice(0, 32).replace(/-+$/g, "");

const liveLadders = (row) => (row.ladders ?? []).filter((l) => !l.deleted_at);
const tabOf = (row) =>
  row.deleted_at ? "deleted" : (row.is_active ? "active" : "retired");

/** The database's own messages are written for people; anything else gets a plain fallback. */
function messageOf(e, fallback) {
  const own = ["22023", "42501", "23503", "23505", "CP422", "CP409"].includes(
    e?.code,
  ) && e.cause?.message;
  if (e?.code === "23505" || e?.kind === "duplicate") {
    return "Another category already uses that code. Choose a different code.";
  }
  if (e?.code === "23503" && own) return own;
  return own || e?.message || fallback;
}

export function createCategoriesPages({ api, getOrgId }) {
  async function loadAll() {
    return await api.read((c) =>
      c.from("categories").select(SELECT).order("sort_order").order("name")
    ) ?? [];
  }

  function categoriesPage() {
    const page = h("div", {
      class: "page admin-dashboard admin-members-page admin-categories-page",
    });
    attachPagePattern(page);
    const tableHost = h("div", { class: "table-host" });
    const pagerHost = h("div", {});
    const state = {
      rows: [],
      status: "loading",
      tab: "active",
      term: "",
      page: 1,
    };
    const search = searchControl({
      class: "input",
      id: "categories-search",
      placeholder: "Search categories...",
      "aria-label": "Search Categories",
      onInput: () => {
        state.term = search.value;
        state.page = 1;
        draw();
      },
    });
    const statusFilter = tableFilter({
      id: "categories-status",
      activeId: state.tab,
      label: "Filter categories by status",
      tabs: TABS,
      onChange: (id) => {
        state.tab = id;
        state.page = 1;
        draw();
      },
    });

    // ---------------------------------------------------------------- form
    function formModal(row) {
      const editing = Boolean(row);
      const key = row?.id ?? api.newKey(); // the new row's ID: a retry of Save is not a second category
      const nextOrder = (Math.max(0, ...state.rows.map((r) => r.sort_order)) ||
        0) + 10;
      const error = h("p", {
        class: "field-error form-error",
        role: "alert",
        hidden: true,
      });
      const nameInput = h("input", {
        class: "input",
        id: "cat-name",
        name: "name",
        required: true,
        maxlength: 60,
        value: row?.name ?? "",
        placeholder: "e.g. Beginner",
      });
      const codeInput = h("input", {
        class: "input",
        id: "cat-code",
        name: "code",
        required: true,
        maxlength: 32,
        value: row?.code ?? "",
        readonly: editing,
        placeholder: "e.g. beginner",
        "aria-describedby": "cat-code-hint",
      });
      let codeTouched = editing;
      codeInput.addEventListener("input", () => (codeTouched = true));
      if (!editing) {
        nameInput.addEventListener("input", () => {
          if (!codeTouched) codeInput.value = codeFrom(nameInput.value);
        });
      }
      const field = (id, label, input, hint) =>
        h(
          "div",
          { class: "field" },
          h("label", { for: id }, label),
          input,
          hint
            ? h("span", { class: "field-hint", id: `${id}-hint` }, hint)
            : null,
        );
      const catField = (id, label, control, iconName, hint) =>
        field(id, label, inputWithIcon(control, iconName), hint);
      const body = h(
        "div",
        { class: "form-grid" },
        catField(
          "cat-name",
          "Category Name *",
          nameInput,
          "layers",
          "Shown on rankings, divisions and brackets.",
        ),
        catField(
          "cat-code",
          "Code *",
          codeInput,
          "idCard",
          editing
            ? "The code cannot be changed."
            : "Generated from the name; you can edit it.",
        ),
        h(
          "div",
          { class: "form-grid-wide" },
          catField(
            "cat-order",
            "Display Order *",
            h("input", {
              class: "input",
              id: "cat-order",
              name: "sort_order",
              type: "number",
              min: 0,
              max: 100000,
              step: 1,
              required: true,
              value: row?.sort_order ?? nextOrder,
            }),
            "layers",
            "Lower numbers come first in lists and menus.",
          ),
        ),
        h(
          "div",
          { class: "form-grid-wide" },
          catField(
            "cat-desc",
            "Description",
            h("textarea", {
              class: "input textarea",
              id: "cat-desc",
              name: "description",
              rows: 2,
              maxlength: 300,
              placeholder: "Skill level summary shown to members...",
            }, row?.description ?? ""),
            "file",
            "Optional. Up to 300 characters.",
          ),
        ),
        h(
          "div",
          { class: "form-grid-wide" },
          catField(
            "cat-elig",
            "Who it is for (eligibility notes)",
            h("textarea", {
              class: "input textarea",
              id: "cat-elig",
              name: "eligibility_notes",
              rows: 2,
              maxlength: 300,
              placeholder:
                "Experience, tournament history or rating guidelines...",
            }, row?.eligibility_notes ?? ""),
            "info",
            "Optional. Up to 300 characters.",
          ),
        ),
        h("div", { class: "form-grid-wide" }, error),
      );
      return openModal({
        title: editing ? "Edit Category" : "New Category",
        eyebrow: editing ? row.name : "Skill Levels",
        icon: "layers",
        description:
          "Set skill level details, eligibility notes and display order.",
        body,
        confirmLabel: editing ? "Save Changes" : "Add Category",
        onConfirm: async (form) => {
          const name = String(form.get("name") ?? "").trim();
          const code = String(form.get("code") ?? "").trim();
          const order = Number(form.get("sort_order"));
          const fail = (m) => {
            error.textContent = m;
            error.hidden = false;
            return false;
          };
          if (!name) return fail("Enter a name.");
          if (!CODE_RE.test(code)) {
            return fail(
              "The code uses lowercase letters, numbers, hyphen or underscore (up to 32), starting with a letter or number.",
            );
          }
          if (!Number.isInteger(order) || order < 0) {
            return fail("The order is a whole number, 0 or more.");
          }
          const fields = {
            name,
            description: String(form.get("description") ?? "").trim() || null,
            eligibility_notes:
              String(form.get("eligibility_notes") ?? "").trim() || null,
            sort_order: order,
          };
          try {
            if (editing) {
              const done = await api.read((c) =>
                c.from("categories").update(fields).eq("id", row.id).eq(
                  "version",
                  row.version,
                ).select("id")
              );
              if (!done?.length) {
                return fail(
                  "Someone else changed this category. Close this window and open it again.",
                );
              }
            } else {
              await api.create("categories", key, {
                org_id: getOrgId(),
                code,
                ...fields,
              });
            }
            toast(editing ? "Category saved." : "Category added.", {
              tone: "success",
            });
            await refresh();
          } catch (e) {
            return fail(messageOf(e, "That did not work. Please try again."));
          }
        },
      });
    }

    function reasonModal(row, { title, verb, run }) {
      const key = api.newKey();
      const error = h("p", {
        class: "field-error form-error",
        role: "alert",
        hidden: true,
      });
      const count = h("output", {
        class: "decision-reason-count",
        id: "cat-reason-count",
        for: "cat-reason",
      }, "0 / 500");
      return openModal({
        title,
        eyebrow: row.name,
        icon: "alert",
        destructive: true,
        confirmLabel: verb,
        body: h(
          "div",
          { class: "member-decision" },
          h(
            "div",
            { class: "member-decision-subject" },
            h(
              "span",
              { class: "member-avatar is-icon", "aria-hidden": "true" },
              icon("layers"),
            ),
            h(
              "div",
              { class: "member-meta" },
              h(
                "div",
                { class: "member-decision-name" },
                h("strong", { class: "member-name" }, row.name),
                badge(
                  row.is_active ? "Active" : "Retired",
                  row.is_active ? "success" : "neutral",
                ),
              ),
              h("span", { class: "sub member-subtext" }, row.code),
            ),
          ),
          h(
            "div",
            { class: "stack" },
            h(
              "div",
              { class: "modal-callout is-danger" },
              h(
                "span",
                { class: "modal-callout-icon", "aria-hidden": "true" },
                icon("trash"),
              ),
              h(
                "div",
                { class: "modal-callout-text" },
                h(
                  "strong",
                  { class: "decision-impact-title" },
                  "Category will be hidden",
                ),
                h(
                  "p",
                  { class: "decision-impact-text" },
                  "The category is hidden from lists. You can restore it later.",
                ),
              ),
            ),
            h(
              "div",
              { class: "field" },
              h(
                "div",
                { class: "decision-field-heading" },
                h(
                  "label",
                  { for: "cat-reason" },
                  "Reason",
                  h("span", { class: "decision-required" }, " *"),
                ),
                count,
              ),
              h("textarea", {
                class: "input textarea",
                id: "cat-reason",
                name: "reason",
                rows: 4,
                minlength: 3,
                maxlength: 500,
                required: true,
                placeholder:
                  "Provide context or explanation for this decision...",
                "aria-describedby": "cat-reason-help cat-reason-count",
                onInput: (event) => {
                  count.textContent = `${event.target.value.length} / 500`;
                },
              }),
              h("p", {
                class: "muted decision-reason-help",
                id: "cat-reason-help",
              }, "At least 3 characters. Maximum 500 characters."),
            ),
          ),
          error,
        ),
        onConfirm: async (form) => {
          const reason = String(form.get("reason") ?? "").trim();
          if (reason.length < 3) {
            error.textContent = "Please give a reason (at least 3 characters).";
            error.hidden = false;
            return false;
          }
          try {
            await run(reason, key);
            toast("Category deleted.", { tone: "success" });
            await refresh();
          } catch (e) {
            error.textContent = messageOf(
              e,
              "That did not work. Please try again.",
            );
            error.hidden = false;
            return false;
          }
        },
      });
    }

    // -------------------------------------------------------------- actions
    async function setActive(row, active) {
      try {
        const done = await api.read((c) =>
          c.from("categories").update({ is_active: active }).eq("id", row.id)
            .eq("version", row.version).select("id")
        );
        if (!done?.length) {
          throw new Error(
            "Someone else changed this category. Reload the page.",
          );
        }
        toast(active ? "Category is active again." : "Category retired.", {
          tone: "success",
        });
        await refresh();
      } catch (e) {
        toast(messageOf(e, "That did not work."), { tone: "error" });
      }
    }

    async function restore(row) {
      try {
        await api.rpc("restore_row", {
          p_table: "categories",
          p_id: row.id,
          p_key: api.newKey(),
        });
        toast("Category restored.", { tone: "success" });
        await refresh();
      } catch (e) {
        toast(messageOf(e, "That did not work."), { tone: "error" });
      }
    }

    function actionsFor(row) {
      const tab = tabOf(row);
      const buttons = [];
      if (tab === "deleted") {
        buttons.push(
          iconButton({
            label: `Restore ${row.name}`,
            icon: "refresh",
            size: "sm",
            variant: "restore",
            onClick: () => restore(row),
          }),
        );
      } else {
        const inUse = liveLadders(row).length > 0;
        buttons.push(
          iconButton({
            label: `Edit ${row.name}`,
            icon: "edit",
            size: "sm",
            variant: "edit",
            onClick: () => formModal(row),
          }),
          iconButton({
            label: tab === "active"
              ? `Retire ${row.name}`
              : `Make ${row.name} active again`,
            icon: tab === "active" ? "eye" : "check",
            size: "sm",
            variant: tab === "active" ? "warning" : "success",
            onClick: () => setActive(row, tab !== "active"),
          }),
          iconButton({
            label: inUse
              ? `${row.name} has a rank ladder and cannot be deleted`
              : `Delete ${row.name}`,
            icon: "trash",
            size: "sm",
            variant: "danger",
            disabled: inUse,
            onClick: () =>
              reasonModal(row, {
                title: "Delete This Category",
                verb: "Delete",
                run: (reason, key) =>
                  api.rpc("soft_delete", {
                    p_table: "categories",
                    p_id: row.id,
                    p_reason: reason,
                    p_key: key,
                  }),
              }),
          }),
        );
      }
      return h("span", { class: "row-actions" }, ...buttons);
    }

    // ---------------------------------------------------------------- table
    const schema = {
      columns: [
        {
          key: "name",
          label: "Category",
          render: (r) =>
            h(
              "div",
              { class: "member-cell" },
              h("span", {
                class: "member-avatar is-icon",
                "aria-hidden": "true",
              }, icon("layers")),
              h(
                "div",
                { class: "member-meta" },
                h("span", { class: "member-name" }, r.name),
                h("span", { class: "sub member-subtext" }, r.code),
              ),
            ),
        },
        {
          key: "description",
          label: "Description",
          render: (r) => r.description || "Not Specified",
        },
        {
          key: "ladder",
          label: "Rank Ladder",
          render: (r) =>
            liveLadders(r).length
              ? badge("Set Up", "success")
              : badge("None Yet", "neutral"),
        },
        {
          key: "status",
          label: "Status",
          render: (r) =>
            r.deleted_at
              ? badge("Deleted", "danger")
              : (r.is_active
                ? badge("Active", "success")
                : badge("Retired", "neutral")),
        },
        {
          key: "actions",
          label: "Action",
          align: "center",
          actionCount: 3,
          render: actionsFor,
        },
      ],
    };

    const rowsOf = (tab) =>
      state.rows.filter((r) => tabOf(r) === tab).sort((a, b) =>
        a.sort_order - b.sort_order || a.name.localeCompare(b.name)
      );

    function draw() {
      statusFilter.setOptions(TABS.map((item) => ({
        value: item.id,
        label: item.label,
        badge: state.status === "loading" ? "—" : rowsOf(item.id).length,
      })));
      const normalize = (text) =>
        String(text ?? "").normalize("NFKD").replace(/\p{M}/gu, "")
          .toLocaleLowerCase();
      const terms = normalize(state.term).trim().split(/\s+/).filter(Boolean);
      const rows = rowsOf(state.tab).filter((row) => {
        const text = normalize([
          row.name,
          row.code,
          row.description,
          liveLadders(row).length ? "Set Up" : "None Yet",
          TABS.find((item) => item.id === tabOf(row))?.label,
        ].join(" "));
        return terms.every((term) => text.includes(term));
      });
      state.page = Math.min(
        state.page,
        Math.max(1, Math.ceil(rows.length / DEFAULT_PAGE_SIZE)),
      );
      const pageRows = rows.slice(
        (state.page - 1) * DEFAULT_PAGE_SIZE,
        state.page * DEFAULT_PAGE_SIZE,
      );
      tableHost.replaceChildren(dataTable({
        searchable: false,
        hasFilters: Boolean(state.term.trim()),
        onReset: () => {
          state.term = "";
          search.value = "";
          state.page = 1;
          draw();
        },
        schema,
        rows: pageRows,
        state: state.status,
        ariaLabel: "Categories",
        onRetry: refresh,
        emptyTitle: state.term.trim()
          ? "No matching categories"
          : state.tab === "active"
          ? "No categories yet"
          : (state.tab === "retired" ? "Nothing Retired" : "Nothing Deleted"),
        emptyText: state.tab === "active"
          ? "Add the club's skill levels, for example Beginner, Novice, Intermediate and Advanced."
          : "Categories you retire or delete will be listed here.",
      }));
      pagerHost.replaceChildren(
        ...(state.status === "loading" || state.status === "error"
          ? []
          : [pagination({
            page: state.page,
            pageSize: DEFAULT_PAGE_SIZE,
            total: rows.length,
            onPage: (next) => {
              state.page = next;
              draw();
            },
          })]),
      );
    }

    async function refresh() {
      state.status = state.rows.length ? "refreshing" : "loading";
      draw();
      try {
        state.rows = await loadAll();
        state.status = "ready";
      } catch {
        state.status = "error";
      }
      draw();
    }

    page.append(
      adminHero({
        title: "Categories",
        chip: "Categories Management",
        description:
          "The club's skill levels, in order. Each category has its own ranked steps.",
        actions: [
          button({
            label: "New Category",
            variant: "primary",
            icon: "plus",
            onClick: () => formModal(null),
          }),
        ],
      }),
      h(
        "div",
        { class: "toolbar admin-members-toolbar has-status-badges" },
        search,
        statusFilter,
      ),
      h(
        "div",
        { class: "member-directory-card is-auto-grid" },
        tableHost,
        pagerHost,
      ),
    );
    refresh();
    return page;
  }

  return { categoriesPage };
}
