// Staff page (PLAN 4.6): who holds which role, and the roles themselves.
// Every change goes through assign_role (admin only; you cannot change your own role; the last admin cannot be
// demoted; a reason is required; idempotent; audited). The role list is a read-only reference: what each role may
// do is set up with the club and checked by the database on every call.
import {
  badge,
  button,
  dataTable,
  h,
  iconButton,
  openModal,
  pageHeader,
  tabs,
  toast,
} from "./ui.js";

const ASSIGNABLE = ["member", "referee", "front_desk", "manager", "admin"];
const TONE = {
  admin: "danger",
  manager: "warning",
  front_desk: "info",
  referee: "info",
  member: "neutral",
};

/** The database's own messages are written for people; anything else gets a plain fallback. */
const messageOf = (e, fallback) =>
  (["22023", "42501", "CP422", "CP409"].includes(e?.code) &&
    e.cause?.message) ||
  e?.message || fallback;

export function createStaffPages({ api }) {
  function staffPage() {
    const page = h("div", { class: "page" });
    const tabsHost = h("div", {});
    const body = h("div", { class: "staff-body" });
    const state = { tab: "staff", status: "loading", staff: [], roles: [] };

    async function refresh() {
      state.status = state.roles.length ? "refreshing" : "loading";
      draw();
      try {
        const [staff, roles] = await Promise.all([
          api.rpc("staff_directory", { p_term: null, p_only_staff: true }),
          api.rpc("role_catalog"),
        ]);
        state.staff = staff ?? [];
        state.roles = roles ?? [];
        state.status = "ready";
      } catch (e) {
        state.status = "error";
        state.error = messageOf(e, "The staff list could not be loaded.");
      }
      draw();
    }

    const roleOptions = () =>
      state.roles.filter((r) => ASSIGNABLE.includes(r.code));
    const errorLine = () =>
      h("p", { class: "field-error form-error", role: "alert", hidden: true });
    const showError = (el, message) => {
      el.textContent = message;
      el.hidden = false;
      return false;
    };
    const roleSelect = (id, value) =>
      h(
        "select",
        { class: "input select-input", id, name: "role" },
        ...roleOptions().map((r) =>
          h("option", { value: r.code, selected: r.code === value }, r.name)
        ),
      );
    const reasonField = () =>
      h(
        "div",
        { class: "field" },
        h("label", { for: "st-reason" }, "Reason *"),
        h("textarea", {
          class: "input textarea",
          id: "st-reason",
          name: "reason",
          rows: 3,
          maxlength: 500,
          required: true,
        }),
        h(
          "span",
          { class: "field-hint" },
          "Kept in the audit log with the old and new role.",
        ),
      );

    async function assign(memberId, form, key) {
      await api.rpc("assign_role", {
        p_member_id: memberId,
        p_role_code: String(form.get("role")),
        p_reason: String(form.get("reason") ?? "").trim(),
        p_key: key,
      });
    }

    function changeModal(row) {
      const key = api.newKey();
      const error = errorLine();
      return openModal({
        title: "Change role",
        eyebrow: `${row.display_name} · ${row.member_no}`,
        icon: "user",
        confirmLabel: "Change role",
        body: h(
          "div",
          { class: "stack" },
          h("p", {}, `Now: ${row.role_name}.`),
          h(
            "div",
            { class: "field" },
            h("label", { for: "st-role" }, "New role"),
            roleSelect("st-role", row.role_code),
          ),
          reasonField(),
          error,
        ),
        onConfirm: async (form) => {
          if (String(form.get("reason") ?? "").trim().length < 3) {
            return showError(
              error,
              "Please give a reason (at least 3 characters).",
            );
          }
          try {
            await assign(row.member_id, form, key);
            toast(`${row.display_name}: role changed.`, { tone: "success" });
            await refresh();
          } catch (e) {
            return showError(
              error,
              messageOf(e, "That did not work. Please try again."),
            );
          }
        },
      });
    }

    function addModal() {
      const key = api.newKey();
      const error = errorLine();
      let chosen = null;
      const results = h("div", {
        class: "staff-results",
        role: "radiogroup",
        "aria-label": "Search results",
      });
      const term = h("input", {
        class: "input",
        id: "st-term",
        type: "search",
        placeholder: "Name or member ID",
        autocomplete: "off",
      });
      const summary = h(
        "p",
        { class: "muted", role: "status" },
        "Search for an active member.",
      );
      async function search() {
        chosen = null;
        const text = term.value.trim();
        if (text.length < 2) {
          summary.textContent = "Type at least 2 letters or numbers.";
          results.replaceChildren();
          return;
        }
        summary.textContent = "Searching…";
        try {
          const rows = await api.rpc("staff_directory", {
            p_term: text,
            p_only_staff: false,
          });
          summary.textContent = rows.length
            ? `${rows.length} found. Choose one.`
            : "Nobody active matches. A member must be active (approved) before getting a role.";
          results.replaceChildren(
            ...rows.map((r) =>
              h(
                "label",
                { class: "staff-result" },
                h("input", {
                  type: "radio",
                  name: "member",
                  value: r.member_id,
                  disabled: r.is_self,
                  onChange: () => (chosen = r),
                }),
                h(
                  "span",
                  {},
                  r.display_name,
                  h(
                    "span",
                    { class: "sub" },
                    `${r.member_no} · ${r.role_name}${
                      r.is_self ? " (you)" : ""
                    }`,
                  ),
                ),
              )
            ),
          );
        } catch (e) {
          summary.textContent = messageOf(e, "The search did not work.");
        }
      }
      term.addEventListener("keydown", (e) => {
        if (e.key === "Enter") {
          e.preventDefault();
          search();
        }
      });
      return openModal({
        title: "Give someone a role",
        eyebrow: "Staff",
        icon: "user",
        confirmLabel: "Assign role",
        body: h(
          "div",
          { class: "stack" },
          h(
            "div",
            { class: "field" },
            h("label", { for: "st-term" }, "Find a member"),
            h(
              "div",
              { class: "staff-search" },
              term,
              button({ label: "Search", icon: "search", onClick: search }),
            ),
          ),
          summary,
          results,
          h(
            "div",
            { class: "field" },
            h("label", { for: "st-role" }, "Role"),
            roleSelect("st-role", "front_desk"),
          ),
          reasonField(),
          error,
        ),
        onConfirm: async (form) => {
          if (!chosen) {
            return showError(error, "Search for a member and choose one.");
          }
          if (String(form.get("reason") ?? "").trim().length < 3) {
            return showError(
              error,
              "Please give a reason (at least 3 characters).",
            );
          }
          try {
            await assign(chosen.member_id, form, key);
            toast(`${chosen.display_name}: role assigned.`, {
              tone: "success",
            });
            await refresh();
          } catch (e) {
            return showError(
              error,
              messageOf(e, "That did not work. Please try again."),
            );
          }
        },
      });
    }

    function staffView() {
      return dataTable({
        schema: {
          columns: [
            {
              key: "name",
              label: "Person",
              render: (r) =>
                h(
                  "span",
                  {},
                  r.display_name,
                  h(
                    "span",
                    { class: "sub" },
                    `${r.member_no}${r.is_self ? " · you" : ""}`,
                  ),
                ),
            },
            {
              key: "role",
              label: "Role",
              render: (r) => badge(r.role_name, TONE[r.role_code] ?? "neutral"),
            },
            {
              key: "status",
              label: "Membership",
              render: (r) => r.status.replace("_", " "),
            },
            {
              key: "actions",
              label: "Action",
              align: "center",
              render: (r) =>
                iconButton({
                  label: r.is_self
                    ? "You cannot change your own role"
                    : `Change the role of ${r.display_name}`,
                  icon: "edit",
                  disabled: r.is_self,
                  onClick: () => changeModal(r),
                }),
            },
          ],
        },
        rows: state.staff,
        state: state.status,
        ariaLabel: "Staff",
        onRetry: refresh,
        emptyTitle: "No staff yet",
        emptyText: "Give an active member a role to add them here.",
      });
    }

    function rolesView() {
      return h(
        "div",
        { class: "stack" },
        h(
          "p",
          { class: "muted" },
          "What each role may do. This list is for reference: the database checks these permissions on every action.",
        ),
        ...state.roles.map((r) =>
          h(
            "div",
            { class: "card role-card" },
            h(
              "div",
              { class: "ladder-head" },
              h(
                "div",
                {},
                h("h2", { class: "settings-title" }, r.name),
                h("span", { class: "muted" }, r.description ?? ""),
              ),
              badge(
                `${r.permissions.length} permission${
                  r.permissions.length === 1 ? "" : "s"
                }`,
                "neutral",
              ),
            ),
            r.permissions.length
              ? h(
                "ul",
                { class: "role-perms" },
                ...r.permissions.map((p) =>
                  h("li", {}, p.description ?? p.code)
                ),
              )
              : h(
                "p",
                { class: "muted" },
                "No permissions: sign-in and the account pages only.",
              ),
          )
        ),
      );
    }

    function draw() {
      tabsHost.replaceChildren(tabs({
        activeId: state.tab,
        tabs: [{ id: "staff", label: "Staff" }, {
          id: "roles",
          label: "Roles",
        }],
        onChange: (id) => {
          state.tab = id;
          draw();
        },
      }));
      if (state.status === "error") {
        body.replaceChildren(
          h(
            "div",
            { class: "card home-error", role: "alert" },
            h("p", {}, state.error),
            button({ label: "Try again", icon: "refresh", onClick: refresh }),
          ),
        );
        return;
      }
      body.replaceChildren(
        state.tab === "staff"
          ? h(
            "div",
            { class: "stack" },
            h(
              "div",
              { class: "actions courts-actions" },
              button({
                label: "Give someone a role",
                icon: "plus",
                variant: "primary",
                disabled: state.status !== "ready",
                onClick: addModal,
              }),
            ),
            staffView(),
          )
          : rolesView(),
      );
    }

    page.append(
      pageHeader({
        icon: "user",
        eyebrow: "Admin",
        title: "Staff and roles",
        description:
          "Who works for the club and what each role may do. Only an admin can change roles, and nobody can change their own.",
      }),
      tabsHost,
      body,
    );
    refresh();
    return page;
  }

  return { staffPage };
}
