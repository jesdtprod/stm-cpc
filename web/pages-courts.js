// Courts page (PLAN 4.4): the courts, their opening hours, their rates and their blackout times.
//   * Hours and rates are dated: a change is a new row that starts on a date, and an old row is ended on a date.
//     Past bookings keep the price they were booked at, so nothing here rewrites history.
//   * Every time is an Asia/Manila time.
//   * The database decides what is allowed (overlapping hours, a court with upcoming bookings, bad ranges);
//     this page shows its answer in plain words. Creates are idempotent and edits check the row's version.
import {
  adminHero,
  attachPagePattern,
  badge,
  button,
  dataTable,
  dateControl,
  DEFAULT_PAGE_SIZE,
  h,
  icon,
  iconButton,
  inputWithIcon,
  openModal,
  selectControl,
  switchToggle,
  tableFilter,
  timeControl,
  toast,
} from "./ui.js";
import { businessDate, formatDateTime } from "./lib/dates.js";
import { formatMoney } from "./lib/money.js";

const CODE_RE = /^[a-z0-9][a-z0-9_-]{0,31}$/;
const codeFrom = (name) =>
  name.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "").slice(0, 32).replace(/-+$/g, "");
const DAYS = [
  { n: 1, label: "Monday" },
  { n: 2, label: "Tuesday" },
  { n: 3, label: "Wednesday" },
  { n: 4, label: "Thursday" },
  { n: 5, label: "Friday" },
  { n: 6, label: "Saturday" },
  { n: 0, label: "Sunday" },
];
const DAY_NAME = Object.fromEntries(DAYS.map((d) => [d.n, d.label]));
const STATUS = {
  available: ["Available", "success"],
  maintenance: ["Maintenance", "warning"],
  closed: ["Closed", "neutral"],
};
const TABS = [
  { id: "courts", label: "Courts" },
  { id: "hours", label: "Opening Hours" },
  { id: "rates", label: "Rates" },
  { id: "blackouts", label: "Blackouts" },
];

const hhmm = (t) => String(t ?? "").slice(0, 5);
/** A closing time for display: the end of the day is stored as 23:59 and shown as midnight. */
const closeLabel = (t) => hhmm(t) === "23:59" ? "00:00 (midnight)" : hhmm(t);

/** A PostgREST tstzrange such as ["2030-02-01 01:00:00+00","2030-02-01 04:00:00+00") -> [Date, Date]. */
function parseRange(text) {
  const m = /"([^"]+)","([^"]+)"/.exec(String(text));
  if (!m) return [null, null];
  const toDate = (s) => {
    let v = s.replace(" ", "T");
    if (/[+-]\d\d$/.test(v)) v += ":00";
    return new Date(v);
  };
  return [toDate(m[1]), toDate(m[2])];
}

/** The database's own messages are written for people; known codes get a plain sentence. */
function messageOf(e, fallback) {
  if (e?.code === "23P01") {
    return "These hours overlap hours that already exist for that court and day. End the old hours first.";
  }
  if (e?.code === "23505" || e?.kind === "duplicate") {
    return "That code is already used by another court. Choose a different code.";
  }
  const own = ["22023", "42501", "23503", "23514", "CP422", "CP409"].includes(
    e?.code,
  ) && e.cause?.message;
  return own || e?.message || fallback;
}

export function createCourtsPages({ api, getOrgId }) {
  function courtsPage() {
    const page = h("div", {
      class: "page admin-dashboard admin-members-page admin-courts-page",
    });
    attachPagePattern(page);
    const tabsHost = h("div", { class: "member-status-filter" });
    const body = h("div", { class: "courts-body" });
    const state = {
      tab: "courts",
      status: "loading",
      courts: [],
      hours: [],
      rates: [],
      blackouts: [],
    };

    async function refresh() {
      state.status = state.courts.length ? "refreshing" : "loading";
      draw();
      try {
        const [courts, hours, rates, blackouts] = await Promise.all([
          api.read((c) =>
            c.from("courts").select(
              "id,code,name,status,surface,indoor,notes,sort_order,version",
            ).is("deleted_at", null).order("sort_order").order("name")
          ),
          api.read((c) =>
            c.from("court_hours").select(
              "id,court_id,weekday,opens_at,closes_at,valid_from,valid_to,version",
            ).is("deleted_at", null).order("valid_from", { ascending: false })
          ),
          api.read((c) =>
            c.from("court_rates").select(
              "id,court_id,weekday,from_time,to_time,rate_per_hour,valid_from,valid_to,version",
            ).is("deleted_at", null).order("valid_from", { ascending: false })
          ),
          api.read((c) =>
            c.from("court_blackouts").select(
              "id,court_id,during,reason,version",
            )
              .is("deleted_at", null).order("created_at", { ascending: false })
          ),
        ]);
        Object.assign(state, {
          courts: courts ?? [],
          hours: hours ?? [],
          rates: rates ?? [],
          blackouts: blackouts ?? [],
          status: "ready",
        });
      } catch {
        state.status = "error";
      }
      draw();
    }

    const courtName = (id) =>
      id ? (state.courts.find((c) => c.id === id)?.name ?? "—") : "All Courts";

    const courtCell = (id) => {
      const court = id ? state.courts.find((c) => c.id === id) : null;
      return h(
        "div",
        { class: "member-cell" },
        h("span", {
          class: "member-avatar is-icon",
          "aria-hidden": "true",
        }, icon("grid")),
        h(
          "div",
          { class: "member-meta" },
          h("span", { class: "member-name" }, courtName(id)),
          court
            ? h("span", { class: "sub member-subtext" }, court.code)
            : null,
        ),
      );
    };

    // ------------------------------------------------------------- form kit
    const errorLine = () =>
      h("p", { class: "field-error form-error", role: "alert", hidden: true });
    const showError = (el, message) => {
      el.textContent = message;
      el.hidden = false;
      return false;
    };
    const field = (id, label, input, hint) =>
      h(
        "div",
        { class: "field" },
        label ? h("label", { for: id }, label) : null,
        input,
        hint
          ? h("span", { class: "field-hint", id: `${id}-hint` }, hint)
          : null,
      );
    const input = (id, name, props = {}) => {
      if (props.type === "date") return dateControl({ id, name, ...props });
      if (props.type === "time") return timeControl({ id, name, ...props });
      return h("input", { class: "input", id, name, ...props });
    };
    const select = (id, name, options, value) =>
      selectControl(
        { class: "input select-input", id, name },
        ...options.map((o) =>
          h(
            "option",
            {
              value: o.value,
              selected: String(o.value) === String(value ?? ""),
            },
            o.label,
          )
        ),
      );
    const courtOptions = (allLabel = "All Courts") =>
      [{ value: "", label: allLabel }].concat(
        state.courts.map((c) => ({ value: c.id, label: c.name })),
      );

    const reasonField = (label, required) => {
      const count = h("output", {
        class: "decision-reason-count",
        id: "cr-reason-count",
        for: "cr-reason",
      }, "0 / 500");
      return h(
        "div",
        { class: "field" },
        h(
          "div",
          { class: "decision-field-heading" },
          h(
            "label",
            { for: "cr-reason" },
            label,
            required ? h("span", { class: "decision-required" }, " *") : null,
          ),
          count,
        ),
        h("textarea", {
          class: "input textarea",
          id: "cr-reason",
          name: "reason",
          rows: 4,
          maxlength: 500,
          placeholder: "Provide context or explanation for this decision...",
          required,
          "aria-describedby": "cr-reason-help cr-reason-count",
          onInput: (event) => {
            count.textContent = `${event.target.value.length} / 500`;
          },
        }),
        h(
          "p",
          { class: "muted decision-reason-help", id: "cr-reason-help" },
          required
            ? "At least 3 characters. Maximum 500 characters."
            : "Optional. Maximum 500 characters.",
        ),
      );
    };

    const deleteSubject = (table, row, name) => {
      if (table === "courts") {
        return {
          icon: "grid",
          name: row.name,
          badge: badge(...(STATUS[row.status] ?? [row.status, "neutral"])),
          subtext: row.code,
          metaLabel: "Type",
          metaValue: [row.indoor ? "Indoor" : "Outdoor", row.surface]
            .filter(Boolean).join(", "),
          impactTitle: "Court will be hidden",
        };
      }
      if (table === "court_hours") {
        return {
          icon: "clock",
          name: courtName(row.court_id),
          badge: badge(DAY_NAME[row.weekday], "info"),
          subtext: `${hhmm(row.opens_at)} to ${closeLabel(row.closes_at)}`,
          metaLabel: "Applies",
          metaValue: row.valid_to
            ? `${row.valid_from} to ${row.valid_to}`
            : `From ${row.valid_from}`,
          impactTitle: "Hours will be removed",
        };
      }
      if (table === "court_rates") {
        return {
          icon: "currency",
          name: courtName(row.court_id),
          badge: badge(
            row.weekday == null ? "Every Day" : DAY_NAME[row.weekday],
            "info",
          ),
          subtext: row.valid_to
            ? `${row.valid_from} to ${row.valid_to}`
            : `From ${row.valid_from}`,
          metaLabel: "Per Hour",
          metaValue: formatMoney(row.rate_per_hour),
          impactTitle: "Rate will be removed",
        };
      }
      return {
        icon: "alert",
        name: courtName(row.court_id),
        badge: null,
        subtext: row.reason ?? name,
        metaLabel: "From and to",
        metaValue: row.range?.[0]
          ? `${formatDateTime(row.range[0])} to ${formatDateTime(row.range[1])}`
          : null,
        impactTitle: "Blackout will be removed",
      };
    };

    function deleteModal(table, row, { title, name, note }) {
      const key = api.newKey();
      const error = errorLine();
      const subject = deleteSubject(table, row, name);
      return openModal({
        title,
        eyebrow: "Courts Management",
        icon: "trash",
        tone: "danger",
        destructive: true,
        confirmLabel: "Delete",
        cancelLabel: "Cancel",
        body: h(
          "div",
          { class: "member-decision" },
          h(
            "div",
            { class: "member-decision-subject" },
            h(
              "span",
              { class: "member-avatar is-icon", "aria-hidden": "true" },
              icon(subject.icon, { solid: true }),
            ),
            h(
              "div",
              { class: "member-meta" },
              h(
                "div",
                { class: "member-decision-name" },
                h("strong", { class: "member-name" }, subject.name),
                subject.badge,
              ),
              h("span", { class: "sub member-subtext" }, subject.subtext),
            ),
            subject.metaValue
              ? h(
                "div",
                { class: "member-decision-role" },
                h("span", { class: "muted" }, subject.metaLabel),
                h("span", {}, subject.metaValue),
              )
              : null,
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
                  subject.impactTitle,
                ),
                h("p", { class: "decision-impact-text" }, note),
              ),
            ),
            reasonField("Reason", true),
          ),
          error,
        ),
        onConfirm: async (form) => {
          const reason = String(form.get("reason") ?? "").trim();
          if (reason.length < 3) {
            return showError(
              error,
              "Please give a reason (at least 3 characters).",
            );
          }
          try {
            await api.rpc("soft_delete", {
              p_table: table,
              p_id: row.id,
              p_reason: reason,
              p_key: key,
            });
            toast("Deleted.", { tone: "success" });
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

    /** Ends dated hours or a rate on a chosen day (the last day it applies). */
    function endModal(table, row, label) {
      const error = errorLine();
      return openModal({
        title: "End on a date",
        eyebrow: label,
        icon: "calendar",
        confirmLabel: "End It",
        body: h(
          "div",
          { class: "stack" },
          field(
            "end-date",
            "Last Day It Applies *",
            input("end-date", "valid_to", {
              type: "date",
              required: true,
              min: row.valid_from,
              value: row.valid_to ?? businessDate(),
            }),
            "Bookings already made keep their price.",
          ),
          error,
        ),
        onConfirm: async (form) => {
          const to = String(form.get("valid_to") ?? "");
          if (!to || to < row.valid_from) {
            return showError(error, "Choose a day on or after the start date.");
          }
          try {
            const done = await api.read((c) =>
              c.from(table).update({ valid_to: to }).eq("id", row.id).eq(
                "version",
                row.version,
              ).select("id")
            );
            if (!done?.length) {
              return showError(
                error,
                "Someone else changed this. Close this window and open it again.",
              );
            }
            toast("Saved.", { tone: "success" });
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

    // ---------------------------------------------------------------- courts
    function courtModal(row) {
      const editing = Boolean(row);
      const key = row?.id ?? api.newKey();
      const error = errorLine();
      const nameInput = input("ct-name", "name", {
        required: true,
        maxlength: 60,
        value: row?.name ?? "",
        placeholder: "e.g. Court 1",
      });
      const codeInput = input("ct-code", "code", {
        required: true,
        maxlength: 32,
        value: row?.code ?? "",
        readonly: editing,
        placeholder: "e.g. court-1",
      });
      let touched = editing;
      codeInput.addEventListener("input", () => (touched = true));
      if (!editing) {
        nameInput.addEventListener("input", () => {
          if (!touched) codeInput.value = codeFrom(nameInput.value);
        });
      }
      const indoor = switchToggle({
        id: "ct-indoor",
        name: "indoor",
        label: h(
          "span",
          { class: "form-setting-label" },
          icon("home"),
          "Indoor Court",
        ),
        checked: row?.indoor ?? false,
      });
      const courtField = (id, label, control, iconName, hint) =>
        field(id, label, inputWithIcon(control, iconName), hint);
      const nextOrder =
        (Math.max(0, ...state.courts.map((c) => c.sort_order)) || 0) + 10;
      return openModal({
        title: editing ? "Edit Court" : "New Court",
        eyebrow: editing ? row.name : "Courts",
        icon: "grid",
        description: "Set court details and booking availability.",
        confirmLabel: editing ? "Save Changes" : "Add Court",
        body: h(
          "div",
          { class: "form-grid" },
          courtField(
            "ct-name",
            "Court Name *",
            nameInput,
            "grid",
            "Shown on schedules and brackets.",
          ),
          courtField(
            "ct-code",
            "Code *",
            codeInput,
            "idCard",
            editing
              ? "The code cannot be changed."
              : "Generated from the name; you can edit it.",
          ),
          courtField(
            "ct-status",
            "Status",
            select("ct-status", "status", [
              { value: "available", label: "Available" },
              { value: "maintenance", label: "Maintenance (cannot be booked)" },
              { value: "closed", label: "Closed (cannot be booked)" },
            ], row?.status ?? "available"),
            "checkCircle",
            "Controls member booking availability.",
          ),
          courtField(
            "ct-surface",
            "Surface",
            input("ct-surface", "surface", {
              maxlength: 60,
              value: row?.surface ?? "",
              placeholder: "e.g. Concrete or acrylic",
            }),
            "layers",
            "Optional playing surface material.",
          ),
          courtField(
            "ct-order",
            "Display Order *",
            input("ct-order", "sort_order", {
              type: "number",
              min: 0,
              step: 1,
              required: true,
              value: row?.sort_order ?? nextOrder,
            }),
            "layers",
            "Lower numbers come first.",
          ),
          field(
            "ct-indoor",
            "Environment",
            h("div", { class: "form-setting" }, indoor),
            "Covered or indoor playing area.",
          ),
          h(
            "div",
            { class: "form-grid-wide" },
            courtField(
              "ct-notes",
              "Notes",
              h("textarea", {
                class: "input textarea",
                id: "ct-notes",
                name: "notes",
                rows: 3,
                maxlength: 300,
                placeholder: "Access, equipment or maintenance details...",
              }, row?.notes ?? ""),
              "file",
              "Optional. Up to 300 characters.",
            ),
          ),
          h("div", { class: "form-grid-wide" }, error),
        ),
        onConfirm: async (form) => {
          const name = String(form.get("name") ?? "").trim();
          const code = String(form.get("code") ?? "").trim();
          const order = Number(form.get("sort_order"));
          if (!name) return showError(error, "Enter a name.");
          if (!CODE_RE.test(code)) {
            return showError(
              error,
              "The code uses lowercase letters, numbers, hyphen or underscore (up to 32).",
            );
          }
          if (!Number.isInteger(order) || order < 0) {
            return showError(error, "The order is a whole number, 0 or more.");
          }
          const fields = {
            name,
            status: String(form.get("status")),
            surface: String(form.get("surface") ?? "").trim() || null,
            indoor: form.get("indoor") === "on",
            notes: String(form.get("notes") ?? "").trim() || null,
            sort_order: order,
          };
          try {
            if (editing) {
              const done = await api.read((c) =>
                c.from("courts").update(fields).eq("id", row.id).eq(
                  "version",
                  row.version,
                ).select("id")
              );
              if (!done?.length) {
                return showError(
                  error,
                  "Someone else changed this court. Close this window and open it again.",
                );
              }
            } else {
              await api.create("courts", key, {
                org_id: getOrgId(),
                code,
                ...fields,
              });
            }
            toast(editing ? "Court saved." : "Court added.", {
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

    function courtsView() {
      return dataTable({
        searchState: state,
        filter: tabsHost,
        pageSize: DEFAULT_PAGE_SIZE,
        schema: {
          columns: [
            {
              key: "name",
              label: "Court",
              render: (r) =>
                h(
                  "div",
                  { class: "member-cell" },
                  h("span", {
                    class: "member-avatar is-icon",
                    "aria-hidden": "true",
                  }, icon("grid")),
                  h(
                    "div",
                    { class: "member-meta" },
                    h("span", { class: "member-name" }, r.name),
                    h("span", { class: "sub member-subtext" }, r.code),
                  ),
                ),
            },
            {
              key: "type",
              label: "Type",
              render: (r) =>
                [r.indoor ? "Indoor" : "Outdoor", r.surface].filter(Boolean)
                  .join(", "),
            },
            {
              key: "status",
              label: "Status",
              render: (r) =>
                badge(...(STATUS[r.status] ?? [r.status, "neutral"])),
            },
            {
              key: "actions",
              label: "Action",
              align: "center",
              actionCount: 2,
              render: (r) =>
                h(
                  "span",
                  { class: "row-actions" },
                  iconButton({
                    label: `Edit ${r.name}`,
                    icon: "edit",
                    size: "sm",
                    variant: "edit",
                    onClick: () => courtModal(r),
                  }),
                  iconButton({
                    label: `Delete ${r.name}`,
                    icon: "trash",
                    size: "sm",
                    variant: "danger",
                    onClick: () =>
                      deleteModal("courts", r, {
                        title: "Delete This Court",
                        name: r.name,
                        note:
                          "A court with upcoming bookings cannot be deleted: cancel or move them first, or set the court to Closed instead.",
                      }),
                  }),
                ),
            },
          ],
        },
        rows: state.courts,
        state: state.status,
        ariaLabel: "Courts",
        onRetry: refresh,
        emptyTitle: "No courts yet",
        emptyText: "Add the club's courts so members can book them.",
      });
    }

    // ----------------------------------------------------------------- hours
    function hoursModal(row = null) {
      const editing = Boolean(row);
      const error = errorLine();
      const days = DAYS.map((d) =>
        h(
          "div",
          { class: "check" },
          h("input", {
            type: editing ? "radio" : "checkbox",
            id: `hr-day-${d.n}`,
            name: editing ? "day" : `day${d.n}`,
            value: String(d.n),
            checked: editing ? row.weekday === d.n : d.n >= 1 && d.n <= 5,
          }),
          h("label", { for: `hr-day-${d.n}` }, d.label),
        )
      );
      return openModal({
        title: editing ? "Edit Opening Hours" : "New Opening Hours",
        eyebrow: "Opening Hours",
        icon: "clock",
        description: editing
          ? "Change the court, day, times or dates for these hours."
          : "Set the days and hours a court is open for bookings.",
        confirmLabel: editing ? "Save Hours" : "Add Hours",
        body: h(
          "div",
          { class: "form-grid" },
          h(
            "div",
            { class: "form-grid-wide" },
            field(
              "hr-court",
              "Court",
              select("hr-court", "court", courtOptions(), row?.court_id ?? ""),
              'Specific court hours replace "All Courts" hours for that day.',
            ),
          ),
          h(
            "div",
            { class: "form-grid-wide" },
            h(
              "fieldset",
              { class: "settings-methods" },
              h("legend", {}, "Days"),
              h("div", { class: "days-grid-2col" }, ...days),
            ),
          ),
          field(
            "hr-open",
            "Opens *",
            input("hr-open", "opens", {
              type: "time",
              required: true,
              value: row ? hhmm(row.opens_at) : "08:00",
            }),
            "Opening time (Asia/Manila).",
          ),
          field(
            "hr-close",
            "Closes *",
            input("hr-close", "closes", {
              type: "time",
              required: true,
              value: row
                ? (hhmm(row.closes_at) === "23:59"
                  ? "00:00"
                  : hhmm(row.closes_at))
                : "21:00",
            }),
            "Closing time (Asia/Manila). Choose 12:00 am for midnight.",
          ),
          field(
            "hr-from",
            "Starts on *",
            input("hr-from", "valid_from", {
              type: "date",
              required: true,
              value: row?.valid_from ?? businessDate(),
            }),
            "First day these hours apply.",
          ),
          field(
            "hr-to",
            "Ends On",
            input("hr-to", "valid_to", {
              type: "date",
              value: row?.valid_to ?? "",
            }),
            "Leave empty for no end date.",
          ),
          h("div", { class: "form-grid-wide" }, error),
        ),
        onConfirm: async (form) => {
          const chosen = editing
            ? DAYS.filter((d) => String(d.n) === String(form.get("day")))
            : DAYS.filter((d) => form.get(`day${d.n}`) === "on");
          const opens = String(form.get("opens"));
          // 12:00 am as the closing time means the end of the day, which the database holds as 23:59
          const closes = String(form.get("closes")) === "00:00"
            ? "23:59"
            : String(form.get("closes"));
          const from = String(form.get("valid_from") ?? "");
          const to = String(form.get("valid_to") ?? "") || null;
          if (!chosen.length) {
            return showError(error, "Choose at least one day.");
          }
          if (!opens || !closes || closes <= opens) {
            return showError(error, "Closing time must be after opening time.");
          }
          if (!from || (to && to < from)) {
            return showError(
              error,
              "The end date cannot be before the start date.",
            );
          }
          const done = [];
          try {
            if (editing) {
              const saved = await api.read((c) =>
                c.from("court_hours").update({
                  court_id: form.get("court") || null,
                  weekday: chosen[0].n,
                  opens_at: opens,
                  closes_at: closes,
                  valid_from: from,
                  valid_to: to,
                }).eq("id", row.id).eq("version", row.version).select("id")
              );
              if (!saved?.length) {
                return showError(
                  error,
                  "Someone else changed these hours. Close this window and open it again.",
                );
              }
              toast("Hours saved.", { tone: "success" });
              await refresh();
              return;
            }
            for (const d of chosen) {
              await api.create("court_hours", api.newKey(), {
                org_id: getOrgId(),
                court_id: form.get("court") || null,
                weekday: d.n,
                opens_at: opens,
                closes_at: closes,
                valid_from: from,
                valid_to: to,
              });
              done.push(d.label);
            }
            toast(
              `Hours added for ${done.length} day${
                done.length === 1 ? "" : "s"
              }.`,
              { tone: "success" },
            );
            await refresh();
          } catch (e) {
            if (done.length) await refresh();
            return showError(
              error,
              `${messageOf(e, "That did not work.")}${
                done.length ? ` Already added: ${done.join(", ")}.` : ""
              }`,
            );
          }
        },
      });
    }

    function hoursView() {
      const rows = [...state.hours].sort((a, b) =>
        courtName(a.court_id).localeCompare(courtName(b.court_id)) ||
        (((a.weekday + 6) % 7) - ((b.weekday + 6) % 7)) ||
        b.valid_from.localeCompare(a.valid_from)
      );
      return h(
        "div",
        { class: "stack" },
        dataTable({
          searchState: state,
          filter: tabsHost,
          pageSize: DEFAULT_PAGE_SIZE,
          schema: {
            columns: [
              {
                key: "court",
                label: "Court",
                render: (r) => courtCell(r.court_id),
              },
              { key: "day", label: "Day", render: (r) => DAY_NAME[r.weekday] },
              {
                key: "time",
                label: "Open",
                render: (r) =>
                  `${hhmm(r.opens_at)} to ${closeLabel(r.closes_at)}`,
              },
              {
                key: "valid",
                label: "Applies",
                render: (r) =>
                  r.valid_to
                    ? `${r.valid_from} to ${r.valid_to}`
                    : `From ${r.valid_from}`,
              },
              {
                key: "actions",
                label: "Action",
                align: "center",
                actionCount: 3,
                render: (r) =>
                  h(
                    "span",
                    { class: "row-actions" },
                    iconButton({
                      label: `Edit ${DAY_NAME[r.weekday]} hours for ${
                        courtName(r.court_id)
                      }`,
                      icon: "edit",
                      size: "sm",
                      variant: "edit",
                      onClick: () => hoursModal(r),
                    }),
                    iconButton({
                      label: `End ${DAY_NAME[r.weekday]} hours for ${
                        courtName(r.court_id)
                      }`,
                      icon: "calendar",
                      size: "sm",
                      variant: "warning",
                      onClick: () =>
                        endModal(
                          "court_hours",
                          r,
                          `${courtName(r.court_id)}, ${DAY_NAME[r.weekday]}`,
                        ),
                    }),
                    iconButton({
                      label: `Delete ${DAY_NAME[r.weekday]} hours for ${
                        courtName(r.court_id)
                      }`,
                      icon: "trash",
                      size: "sm",
                      variant: "danger",
                      onClick: () =>
                        deleteModal("court_hours", r, {
                          title: "Delete These Hours",
                          name: `${courtName(r.court_id)}, ${
                            DAY_NAME[r.weekday]
                          }`,
                          note:
                            "Members will not be able to book that day unless other hours apply.",
                        }),
                    }),
                  ),
              },
            ],
          },
          rows,
          state: state.status,
          ariaLabel: "Opening Hours",
          onRetry: refresh,
          emptyTitle: "No opening hours yet",
          emptyText:
            "Add the hours courts are open so members can pick a time.",
        }),
      );
    }

    // ----------------------------------------------------------------- rates
    function rateModal() {
      const error = errorLine();
      return openModal({
        title: "New Rate",
        eyebrow: "Rates",
        icon: "currency",
        description: "Set the hourly booking rate for a court, day or time.",
        confirmLabel: "Add Rate",
        body: h(
          "div",
          { class: "form-grid" },
          field(
            "rt-court",
            "Court",
            select("rt-court", "court", courtOptions(), ""),
            "Choose a court or apply to all courts.",
          ),
          field(
            "rt-day",
            "Day",
            select(
              "rt-day",
              "weekday",
              [{ value: "", label: "Every Day" }].concat(
                DAYS.map((d) => ({ value: d.n, label: d.label })),
              ),
              "",
            ),
            "Specific day rates override every-day rates.",
          ),
          h(
            "div",
            { class: "form-grid-wide" },
            field(
              "rt-rate",
              "Rate per hour (PHP) *",
              input("rt-rate", "rate", {
                type: "number",
                min: 0,
                max: 100000,
                step: "0.01",
                required: true,
                placeholder: "e.g. 250.00",
              }),
              "Past bookings keep the price they were booked at.",
            ),
          ),
          field(
            "rt-from-t",
            "From Time",
            input("rt-from-t", "from_time", { type: "time", value: "00:00" }),
            "Start of rate window.",
          ),
          field(
            "rt-to-t",
            "To Time",
            input("rt-to-t", "to_time", { type: "time", value: "23:59" }),
            "Leave 00:00 to 23:59 for the whole day.",
          ),
          field(
            "rt-from",
            "Starts on *",
            input("rt-from", "valid_from", {
              type: "date",
              required: true,
              value: businessDate(),
            }),
            "First day this rate applies.",
          ),
          field(
            "rt-to",
            "Ends On",
            input("rt-to", "valid_to", { type: "date" }),
            "Leave empty for no end date.",
          ),
          h("div", { class: "form-grid-wide" }, error),
        ),
        onConfirm: async (form) => {
          const rate = Number(form.get("rate"));
          const from = String(form.get("valid_from") ?? "");
          const to = String(form.get("valid_to") ?? "") || null;
          const ft = String(form.get("from_time") || "00:00");
          const tt = String(form.get("to_time") || "23:59");
          if (
            !Number.isFinite(rate) || rate < 0 ||
            Math.round(rate * 100) !== rate * 100
          ) {
            return showError(
              error,
              "Enter a rate of 0 or more, with at most two decimals.",
            );
          }
          if (tt <= ft) {
            return showError(
              error,
              "The end time must be after the start time.",
            );
          }
          if (!from || (to && to < from)) {
            return showError(
              error,
              "The end date cannot be before the start date.",
            );
          }
          try {
            await api.create("court_rates", api.newKey(), {
              org_id: getOrgId(),
              court_id: form.get("court") || null,
              weekday: form.get("weekday") === ""
                ? null
                : Number(form.get("weekday")),
              from_time: ft,
              to_time: tt === "23:59" ? "23:59:59" : tt,
              rate_per_hour: rate,
              valid_from: from,
              valid_to: to,
            });
            toast("Rate added.", { tone: "success" });
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

    function ratesView() {
      const describe = (r) =>
        `${courtName(r.court_id)}${
          r.weekday == null ? "" : `, ${DAY_NAME[r.weekday]}`
        }`;
      return h(
        "div",
        { class: "stack" },
        dataTable({
          searchState: state,
          filter: tabsHost,
          pageSize: DEFAULT_PAGE_SIZE,
          schema: {
            columns: [
              {
                key: "court",
                label: "Court",
                render: (r) => courtCell(r.court_id),
              },
              {
                key: "when",
                label: "When",
                render: (r) => {
                  const whole = hhmm(r.from_time) === "00:00" &&
                    hhmm(r.to_time) >= "23:59";
                  return `${
                    r.weekday == null ? "Every Day" : DAY_NAME[r.weekday]
                  }${
                    whole ? "" : `, ${hhmm(r.from_time)} to ${hhmm(r.to_time)}`
                  }`;
                },
              },
              {
                key: "rate",
                label: "Per Hour",
                align: "right",
                render: (r) => formatMoney(r.rate_per_hour),
              },
              {
                key: "valid",
                label: "Applies",
                render: (r) =>
                  r.valid_to
                    ? `${r.valid_from} to ${r.valid_to}`
                    : `From ${r.valid_from}`,
              },
              {
                key: "actions",
                label: "Action",
                align: "center",
                actionCount: 2,
                render: (r) =>
                  h(
                    "span",
                    { class: "row-actions" },
                    iconButton({
                      label: `End rate: ${describe(r)}`,
                      icon: "calendar",
                      size: "sm",
                      variant: "warning",
                      onClick: () => endModal("court_rates", r, describe(r)),
                    }),
                    iconButton({
                      label: `Delete rate: ${describe(r)}`,
                      icon: "trash",
                      size: "sm",
                      variant: "danger",
                      onClick: () =>
                        deleteModal("court_rates", r, {
                          title: "Delete This Rate",
                          name: describe(r),
                          note:
                            "Prefer ending a rate on a date. Deleting removes it from the rate list.",
                        }),
                    }),
                  ),
              },
            ],
          },
          rows: state.rates,
          state: state.status,
          ariaLabel: "Rates",
          onRetry: refresh,
          emptyTitle: "No rates yet",
          emptyText: "Without a rate, court bookings are free.",
        }),
      );
    }

    // ------------------------------------------------------------- blackouts
    function blackoutModal() {
      const error = errorLine();
      const today = businessDate();
      return openModal({
        title: "New Blackout",
        eyebrow: "Blackouts",
        icon: "alert",
        description: "Block a court or all courts during maintenance.",
        confirmLabel: "Add Blackout",
        body: h(
          "div",
          { class: "form-grid" },
          h(
            "div",
            { class: "form-grid-wide" },
            field(
              "bo-court",
              "Court",
              select("bo-court", "court", courtOptions(), ""),
              "Choose a single court or block all courts.",
            ),
          ),
          field(
            "bo-sd",
            "From Date *",
            input("bo-sd", "start_date", {
              type: "date",
              required: true,
              value: today,
            }),
            "Start date of the closure.",
          ),
          field(
            "bo-st",
            "From Time *",
            input("bo-st", "start_time", {
              type: "time",
              required: true,
              value: "08:00",
            }),
            "Start time (Asia/Manila).",
          ),
          field(
            "bo-ed",
            "To Date *",
            input("bo-ed", "end_date", {
              type: "date",
              required: true,
              value: today,
            }),
            "End date of the closure.",
          ),
          field(
            "bo-et",
            "To Time *",
            input("bo-et", "end_time", {
              type: "time",
              required: true,
              value: "12:00",
            }),
            "Bookings resume from this time.",
          ),
          h(
            "div",
            { class: "form-grid-wide" },
            field(
              "bo-reason",
              "Reason *",
              input("bo-reason", "reason", {
                required: true,
                maxlength: 200,
                placeholder: "For example: resurfacing",
              }),
              "Shown on the court schedule.",
            ),
          ),
          h("div", { class: "form-grid-wide" }, error),
        ),
        onConfirm: async (form) => {
          const start = `${form.get("start_date")}T${
            form.get("start_time")
          }:00+08:00`;
          const end = `${form.get("end_date")}T${
            form.get("end_time")
          }:00+08:00`;
          const reason = String(form.get("reason") ?? "").trim();
          if (!reason) return showError(error, "Give a reason.");
          if (
            Number.isNaN(Date.parse(start)) || Number.isNaN(Date.parse(end)) ||
            Date.parse(end) <= Date.parse(start)
          ) {
            return showError(error, "The end must be after the start.");
          }
          try {
            await api.create("court_blackouts", api.newKey(), {
              org_id: getOrgId(),
              court_id: form.get("court") || null,
              during: `[${start},${end})`,
              reason,
            });
            toast("Blackout added.", { tone: "success" });
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

    function blackoutsView() {
      const rows = state.blackouts.map((b) => ({
        ...b,
        range: parseRange(b.during),
      }))
        .sort((a, b) =>
          (b.range[0]?.getTime() ?? 0) - (a.range[0]?.getTime() ?? 0)
        );
      const now = Date.now();
      return dataTable({
        searchState: state,
        filter: tabsHost,
        pageSize: DEFAULT_PAGE_SIZE,
        schema: {
          columns: [
            {
              key: "court",
              label: "Court",
              render: (r) => courtCell(r.court_id),
            },
            {
              key: "when",
              label: "From and to",
              render: (r) =>
                r.range[0]
                  ? `${formatDateTime(r.range[0])} to ${
                    formatDateTime(r.range[1])
                  }`
                  : "—",
            },
            { key: "reason", label: "Reason", render: (r) => r.reason },
            {
              key: "state",
              label: "State",
              render: (r) =>
                !r.range[1] || r.range[1].getTime() <= now
                  ? badge("Past", "neutral")
                  : (r.range[0].getTime() <= now
                    ? badge("Now", "warning")
                    : badge("Upcoming", "info")),
            },
            {
              key: "actions",
              label: "Action",
              align: "center",
              actionCount: 1,
              render: (r) =>
                iconButton({
                  label: `Delete blackout: ${r.reason}`,
                  icon: "trash",
                  size: "sm",
                  variant: "danger",
                  onClick: () =>
                    deleteModal("court_blackouts", r, {
                      title: "Delete This Blackout",
                      name: `${courtName(r.court_id)}: ${r.reason}`,
                      note: "The court can be booked again for that time.",
                    }),
                }),
            },
          ],
        },
        rows,
        state: state.status,
        ariaLabel: "Blackouts",
        onRetry: refresh,
        emptyTitle: "No Blackouts",
        emptyText:
          "Add a blackout when a court cannot be booked, for example for maintenance.",
      });
    }

    // ---------------------------------------------------------------- layout
    const ADD = {
      courts: ["New Court", () => courtModal(null)],
      hours: ["New Hours", hoursModal],
      rates: ["New Rate", rateModal],
      blackouts: ["New Blackout", blackoutModal],
    };
    const addBtnLabel = h("span", { class: "btn-label" }, "New Court");
    const addBtn = button({
      label: "New Court",
      icon: "plus",
      variant: "primary",
      onClick: () => ADD[state.tab][1](),
    });
    addBtn.querySelector(".btn-label")?.replaceWith(addBtnLabel);

    function draw() {
      tabsHost.replaceChildren(tableFilter({
        activeId: state.tab,
        label: "View Court Records",
        tabs: TABS.map((item) => ({
          ...item,
          badge: state.status === "loading" ? "—" : state[item.id].length,
        })),
        onChange: (id) => {
          state.tab = id;
          draw();
        },
      }));
      const [label] = ADD[state.tab];
      const disabled = state.tab !== "courts" && state.status === "ready" &&
        state.courts.length === 0;
      addBtnLabel.textContent = label;
      addBtn.disabled = disabled;
      const view = {
        courts: courtsView,
        hours: hoursView,
        rates: ratesView,
        blackouts: blackoutsView,
      }[state.tab];
      const content = view();
      const tableNode = content.classList?.contains("data-grid")
        ? h(
          "div",
          { class: "member-directory-card is-auto-grid" },
          h("div", { class: "table-host" }, content),
        )
        : (() => {
          const tbl = content.querySelector(".data-grid");
          if (tbl) {
            const card = h(
              "div",
              { class: "member-directory-card is-auto-grid" },
              h("div", { class: "table-host" }),
            );
            tbl.replaceWith(card);
            card.firstElementChild.append(tbl);
          }
          return content;
        })();
      body.replaceChildren(...[
        disabled ? h("p", { class: "muted" }, "Add a court first.") : null,
        tableNode,
      ].filter(Boolean));
    }

    page.append(
      adminHero({
        title: "Courts",
        chip: "Courts Management",
        description:
          "Courts, opening hours, rates and blackout times. All times are Asia/Manila.",
        actions: [addBtn],
      }),
      body,
    );
    refresh();
    return page;
  }

  return { courtsPage };
}
