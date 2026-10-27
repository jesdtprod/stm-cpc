// Staff page (PLAN 4.6): who holds which role, and the roles themselves.
// Every change goes through assign_role (admin only; you cannot change your own role; the last admin cannot be
// demoted; a reason is required; idempotent; audited). The role list is a read-only reference: what each role may
// do is set up with the club and checked by the database on every call.
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
  inputWithIcon,
  openModal,
  searchControl,
  selectControl,
  tableFilter,
  toast,
} from "./ui.js";
import { avatarImage } from "./lib/avatar.js";

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
    const page = h("div", {
      class: "page admin-dashboard admin-members-page admin-staff-page",
    });
    attachPagePattern(page);
    const tabsHost = h("div", {});
    const summary = h("div", {
      class: "home-grid",
      "aria-label": "Staff summary",
    });
    const body = h("div", { class: "staff-body" });
    const state = { tab: "staff", status: "loading", staff: [], roles: [] };
    const addBtn = button({
      label: "Give Someone a Role",
      icon: "plus",
      variant: "primary",
      disabled: true,
      onClick: () => addModal(),
    });

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
      selectControl(
        { class: "input select-input", id, name: "role" },
        ...roleOptions().map((r) =>
          h("option", { value: r.code, selected: r.code === value }, r.name)
        ),
      );
    const reasonField = () => {
      const count = h("output", {
        class: "decision-reason-count",
        id: "st-reason-count",
        for: "st-reason",
      }, "0 / 500");
      return h(
        "div",
        { class: "field" },
        h(
          "div",
          { class: "decision-field-heading" },
          h(
            "label",
            { for: "st-reason" },
            "Reason",
            h("span", { class: "decision-required" }, " *"),
          ),
          count,
        ),
        inputWithIcon(
          h("textarea", {
            class: "input textarea",
            id: "st-reason",
            name: "reason",
            rows: 4,
            minlength: 3,
            maxlength: 500,
            required: true,
            placeholder:
              "Provide context or explanation for this role assignment...",
            "aria-describedby": "st-reason-help st-reason-count",
            onInput: (event) => {
              count.textContent = `${event.target.value.length} / 500`;
            },
          }),
          "file",
        ),
        h(
          "p",
          {
            class: "muted decision-reason-help",
            id: "st-reason-help",
          },
          "Kept in the audit log with the old and new role. At least 3 characters.",
        ),
      );
    };

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
        title: "Change Role",
        eyebrow: `${row.display_name} · ${row.member_no}`,
        icon: "user",
        description:
          "Update staff permissions and assigned capabilities for this member.",
        confirmLabel: "Change Role",
        body: h(
          "div",
          { class: "member-decision" },
          h(
            "div",
            { class: "member-decision-subject" },
            h(
              "span",
              { class: "member-avatar is-icon", "aria-hidden": "true" },
              icon("user"),
            ),
            h(
              "div",
              { class: "member-meta" },
              h(
                "div",
                { class: "member-decision-name" },
                h("strong", { class: "member-name" }, row.display_name),
                badge(row.role_name, TONE[row.role_code] ?? "neutral"),
              ),
              h(
                "span",
                { class: "sub member-subtext" },
                `Member ID: ${row.member_no}`,
              ),
            ),
          ),
          h(
            "div",
            { class: "stack" },
            h(
              "div",
              { class: "modal-callout is-warning" },
              h(
                "span",
                { class: "modal-callout-icon", "aria-hidden": "true" },
                icon("alert"),
              ),
              h(
                "div",
                { class: "modal-callout-text" },
                h(
                  "strong",
                  { class: "decision-impact-title" },
                  "Permissions will update immediately",
                ),
                h(
                  "p",
                  { class: "decision-impact-text" },
                  "Changing this member's role adjusts their access to administration tools and approval queues.",
                ),
              ),
            ),
            h(
              "div",
              { class: "field" },
              h("label", { for: "st-role" }, "New Role"),
              inputWithIcon(roleSelect("st-role", row.role_code), "user"),
            ),
            reasonField(),
          ),
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
      const previewHost = h("div", { class: "staff-selected-preview" });
      const results = h("div", {
        class: "staff-results",
        role: "radiogroup",
        "aria-label": "Search Results",
      });
      const term = searchControl({
        class: "input",
        id: "st-term",
        type: "search",
        placeholder: "Name or member ID",
        autocomplete: "off",
      });
      const summary = h(
        "p",
        {
          class: "field-hint staff-search-summary",
          role: "status",
          "aria-live": "polite",
        },
        "Search by name or member ID. Active members only.",
      );

      function updatePreview(member) {
        chosen = member;
        if (!member) {
          previewHost.replaceChildren();
          results.hidden = false;
          summary.hidden = false;
          return;
        }
        results.hidden = true;
        summary.hidden = true;
        previewHost.replaceChildren(
          h(
            "div",
            { class: "staff-selected-card" },
            h(
              "div",
              { class: "staff-selected-identity" },
              h(
                "span",
                {
                  class: "member-avatar is-icon staff-selected-avatar",
                  "aria-hidden": "true",
                },
                icon("userCheck"),
              ),
              h(
                "div",
                { class: "member-meta" },
                h(
                  "div",
                  { class: "staff-selected-header-row" },
                  h("strong", { class: "member-name" }, member.display_name),
                  badge(member.role_name, TONE[member.role_code] ?? "neutral"),
                ),
                h(
                  "span",
                  { class: "sub member-subtext" },
                  `Member ID: ${member.member_no}`,
                ),
              ),
            ),
            button({
              label: "Change",
              icon: "refreshCw",
              variant: "ghost",
              class: "staff-change-btn",
              onClick: (e) => {
                e.preventDefault();
                updatePreview(null);
                const checkedRadio = results.querySelector(
                  "input[type='radio']:checked",
                );
                if (checkedRadio) checkedRadio.checked = false;
              },
            }),
          ),
        );
      }

      async function search() {
        updatePreview(null);
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
            ? `${rows.length} found. Choose one below.`
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
                  onChange: () => updatePreview(r),
                }),
                h("span", {
                  class: "member-avatar is-icon",
                  "aria-hidden": "true",
                }, icon("user")),
                h(
                  "span",
                  { class: "member-meta" },
                  h("span", { class: "member-name" }, r.display_name),
                  h(
                    "span",
                    { class: "sub member-subtext" },
                    `${r.member_no}${r.is_self ? " (you)" : ""}`,
                  ),
                ),
                badge(r.role_name, TONE[r.role_code] ?? "neutral"),
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
        title: "Give Someone a Role",
        eyebrow: "Staff",
        icon: "user",
        description:
          "Select a member, choose their role and record the reason.",
        confirmLabel: "Assign Role",
        body: h(
          "div",
          { class: "form-grid" },
          h(
            "section",
            {
              class: "form-section form-grid-wide",
              "aria-label": "Member Selection",
            },
            h(
              "div",
              { class: "decision-field-heading" },
              h(
                "label",
                { for: "st-term", class: "form-setting-label" },
                icon("user"),
                "Find a Member",
              ),
              badge("Active Members", "success"),
            ),
            h(
              "div",
              { class: "staff-search" },
              term,
              button({ label: "Search", icon: "search", onClick: search }),
            ),
            summary,
            results,
            previewHost,
          ),
          h(
            "div",
            { class: "field form-grid-wide" },
            h("label", { for: "st-role" }, "Role"),
            inputWithIcon(roleSelect("st-role", "front_desk"), "keyRound"),
            h(
              "span",
              { class: "field-hint" },
              "Controls the tools and permissions this member can access.",
            ),
          ),
          h("div", { class: "form-grid-wide" }, reasonField()),
          h("div", { class: "form-grid-wide" }, error),
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
        searchState: state,
        filter: tabsHost,
        searchPlaceholder: "Search staff by name, member ID, or role…",
        schema: {
          columns: [
            {
              key: "name",
              label: "Member",
              skeleton: "stack",
              render: (r) =>
                h(
                  "div",
                  { class: "member-cell" },
                  h(
                    "span",
                    { class: "member-avatar", "aria-hidden": "true" },
                    avatarImage(null, r.display_name),
                  ),
                  h(
                    "div",
                    { class: "member-meta" },
                    h("span", { class: "member-name" }, r.display_name),
                    h(
                      "span",
                      { class: "sub member-subtext" },
                      `${r.member_no}${r.is_self ? " · you" : ""}`,
                    ),
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
              label: "Status",
              skeleton: "badge-stack",
              render: (r) =>
                badge(
                  r.status.replaceAll("_", " "),
                  r.status === "active" ? "success" : "warning",
                ),
            },
            {
              key: "actions",
              label: "Action",
              align: "center",
              actionCount: 1,
              render: (r) =>
                iconButton({
                  label: r.is_self
                    ? "You cannot change your own role"
                    : `Change the role of ${r.display_name}`,
                  icon: "edit",
                  size: "sm",
                  variant: "edit",
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
        { class: "staff-role-catalog" },
        tabsHost,
        h(
          "p",
          { class: "muted" },
          "What each role may do. This list is for reference: the database checks these permissions on every action.",
        ),
        ...state.roles.map((r) =>
          h(
            "div",
            { class: "member-panel role-card" },
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
      const loading = state.status === "loading";
      const unavailable = state.status === "error";
      summary.replaceChildren(
        ...[
          {
            label: "Staff Members",
            value: state.staff.length,
            hint: "Members assigned a staff role",
            iconName: "user",
            tone: "emerald",
          },
          {
            label: "Administrators",
            value: state.staff.filter((r) => r.role_code === "admin").length,
            hint: "Manage club access and role assignments",
            iconName: "lock",
            tone: "amber",
          },
          {
            label: "Club Roles",
            value: state.roles.length,
            hint: "Defined roles and their permissions",
            iconName: "file",
            tone: "teal",
          },
        ].map((item) =>
          adminStatCard({
            ...item,
            value: unavailable ? "—" : item.value,
            loading,
          })
        ),
      );
      tabsHost.replaceChildren(tableFilter({
        label: "Staff and role views",
        activeId: state.tab,
        tabs: [{ id: "staff", label: "Staff", badge: state.staff.length }, {
          id: "roles",
          label: "Roles",
          badge: state.roles.length,
        }],
        onChange: (id) => {
          state.tab = id;
          draw();
        },
      }));
      addBtn.disabled = state.status !== "ready";
      if (state.status === "error") {
        body.replaceChildren(
          tabsHost,
          h(
            "div",
            { class: "card home-error", role: "alert" },
            h("p", {}, state.error),
            button({ label: "Try Again", icon: "refresh", onClick: refresh }),
          ),
        );
        return;
      }
      body.replaceChildren(
        state.tab === "staff"
          ? h(
            "div",
            { class: "member-directory-card is-auto-grid" },
            h("div", { class: "table-host" }, staffView()),
          )
          : rolesView(),
      );
    }

    page.append(
      adminHero({
        title: "Staff and Roles",
        chip: "Staff Management",
        description:
          "Who works for the club and what each role may do. Only an admin can change roles, and nobody can change their own.",
        actions: [
          button({
            label: "Refresh List",
            icon: "refresh",
            variant: "secondary",
            onClick: refresh,
          }),
          addBtn,
        ],
      }),
      summary,
      body,
    );
    refresh();
    return page;
  }

  return { staffPage };
}
