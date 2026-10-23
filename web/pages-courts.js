// Courts page (PLAN 4.4): the courts, their opening hours, their rates and their blackout times.
//   * Hours and rates are dated: a change is a new row that starts on a date, and an old row is ended on a date.
//     Past bookings keep the price they were booked at, so nothing here rewrites history.
//   * Every time is an Asia/Manila time.
//   * The database decides what is allowed (overlapping hours, a court with upcoming bookings, bad ranges);
//     this page shows its answer in plain words. Creates are idempotent and edits check the row's version.
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
  { id: "hours", label: "Opening hours" },
  { id: "rates", label: "Rates" },
  { id: "blackouts", label: "Blackouts" },
];

const hhmm = (t) => String(t ?? "").slice(0, 5);

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
    const page = h("div", { class: "page" });
    const tabsHost = h("div", {});
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
      id ? (state.courts.find((c) => c.id === id)?.name ?? "—") : "All courts";

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
    const input = (id, name, props = {}) =>
      h("input", { class: "input", id, name, ...props });
    const select = (id, name, options, value) =>
      h(
        "select",
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
    const courtOptions = (allLabel = "All courts") =>
      [{ value: "", label: allLabel }].concat(
        state.courts.map((c) => ({ value: c.id, label: c.name })),
      );

    function deleteModal(table, row, { title, name, note }) {
      const key = api.newKey();
      const error = errorLine();
      return openModal({
        title,
        eyebrow: name,
        icon: "alert",
        destructive: true,
        confirmLabel: "Delete",
        body: h(
          "div",
          { class: "stack" },
          h("p", {}, note),
          field(
            "cr-reason",
            "Reason *",
            h("textarea", {
              class: "input textarea",
              id: "cr-reason",
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
        confirmLabel: "End it",
        body: h(
          "div",
          { class: "stack" },
          field(
            "end-date",
            "Last day it applies *",
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
      });
      const codeInput = input("ct-code", "code", {
        required: true,
        maxlength: 32,
        value: row?.code ?? "",
        readonly: editing,
      });
      let touched = editing;
      codeInput.addEventListener("input", () => (touched = true));
      if (!editing) {
        nameInput.addEventListener("input", () => {
          if (!touched) codeInput.value = codeFrom(nameInput.value);
        });
      }
      const indoor = h("input", {
        type: "checkbox",
        id: "ct-indoor",
        name: "indoor",
        checked: row?.indoor ?? false,
      });
      const nextOrder =
        (Math.max(0, ...state.courts.map((c) => c.sort_order)) || 0) + 10;
      return openModal({
        title: editing ? "Edit court" : "New court",
        eyebrow: editing ? row.name : "Courts",
        icon: "grid",
        confirmLabel: editing ? "Save changes" : "Add court",
        body: h(
          "div",
          { class: "stack" },
          field("ct-name", "Name *", nameInput),
          field(
            "ct-code",
            "Code *",
            codeInput,
            editing
              ? "The code cannot be changed."
              : "Made from the name. Lowercase letters, numbers, hyphen.",
          ),
          field(
            "ct-status",
            "Status",
            select("ct-status", "status", [
              { value: "available", label: "Available" },
              { value: "maintenance", label: "Maintenance (cannot be booked)" },
              { value: "closed", label: "Closed (cannot be booked)" },
            ], row?.status ?? "available"),
          ),
          field(
            "ct-surface",
            "Surface",
            input("ct-surface", "surface", {
              maxlength: 60,
              value: row?.surface ?? "",
            }),
          ),
          h(
            "div",
            { class: "check" },
            indoor,
            h("label", { for: "ct-indoor" }, "Indoor court"),
          ),
          field(
            "ct-notes",
            "Notes",
            h("textarea", {
              class: "input textarea",
              id: "ct-notes",
              name: "notes",
              rows: 2,
              maxlength: 300,
            }, row?.notes ?? ""),
          ),
          field(
            "ct-order",
            "Order",
            input("ct-order", "sort_order", {
              type: "number",
              min: 0,
              step: 1,
              required: true,
              value: row?.sort_order ?? nextOrder,
            }),
            "Lower numbers come first.",
          ),
          error,
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
        schema: {
          columns: [
            {
              key: "order",
              label: "Order",
              align: "right",
              render: (r) => String(r.sort_order),
            },
            {
              key: "name",
              label: "Court",
              render: (r) =>
                h("span", {}, r.name, h("span", { class: "sub" }, r.code)),
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
              render: (r) =>
                h(
                  "span",
                  { class: "row-actions" },
                  iconButton({
                    label: `Edit ${r.name}`,
                    icon: "edit",
                    onClick: () => courtModal(r),
                  }),
                  iconButton({
                    label: `Delete ${r.name}`,
                    icon: "trash",
                    variant: "danger",
                    onClick: () =>
                      deleteModal("courts", r, {
                        title: "Delete this court",
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
    function hoursModal() {
      const error = errorLine();
      const days = DAYS.map((d) =>
        h(
          "div",
          { class: "check" },
          h("input", {
            type: "checkbox",
            id: `hr-day-${d.n}`,
            name: `day${d.n}`,
            checked: d.n >= 1 && d.n <= 5,
          }),
          h("label", { for: `hr-day-${d.n}` }, d.label),
        )
      );
      return openModal({
        title: "New opening hours",
        eyebrow: "Opening hours",
        icon: "clock",
        confirmLabel: "Add hours",
        body: h(
          "div",
          { class: "stack" },
          field(
            "hr-court",
            "Court",
            select("hr-court", "court", courtOptions(), ""),
          ),
          h(
            "fieldset",
            { class: "settings-methods" },
            h("legend", {}, "Days"),
            ...days,
          ),
          field(
            "hr-open",
            "Opens *",
            input("hr-open", "opens", {
              type: "time",
              required: true,
              value: "08:00",
            }),
          ),
          field(
            "hr-close",
            "Closes *",
            input("hr-close", "closes", {
              type: "time",
              required: true,
              value: "21:00",
            }),
          ),
          field(
            "hr-from",
            "Starts on *",
            input("hr-from", "valid_from", {
              type: "date",
              required: true,
              value: businessDate(),
            }),
            "Hours are dated, so a change never rewrites the past.",
          ),
          field(
            "hr-to",
            "Ends on",
            input("hr-to", "valid_to", { type: "date" }),
            "Leave empty for no end date.",
          ),
          error,
        ),
        onConfirm: async (form) => {
          const chosen = DAYS.filter((d) => form.get(`day${d.n}`) === "on");
          const opens = String(form.get("opens"));
          const closes = String(form.get("closes"));
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
        h(
          "p",
          { class: "muted" },
          'Hours for a specific court replace the "All courts" hours for that court and day.',
        ),
        dataTable({
          schema: {
            columns: [
              {
                key: "court",
                label: "Court",
                render: (r) => courtName(r.court_id),
              },
              { key: "day", label: "Day", render: (r) => DAY_NAME[r.weekday] },
              {
                key: "time",
                label: "Open",
                render: (r) => `${hhmm(r.opens_at)} to ${hhmm(r.closes_at)}`,
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
                render: (r) =>
                  h(
                    "span",
                    { class: "row-actions" },
                    iconButton({
                      label: `End ${DAY_NAME[r.weekday]} hours for ${
                        courtName(r.court_id)
                      }`,
                      icon: "calendar",
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
                      variant: "danger",
                      onClick: () =>
                        deleteModal("court_hours", r, {
                          title: "Delete these hours",
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
          ariaLabel: "Opening hours",
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
        title: "New rate",
        eyebrow: "Rates",
        icon: "currency",
        confirmLabel: "Add rate",
        body: h(
          "div",
          { class: "stack" },
          field(
            "rt-court",
            "Court",
            select("rt-court", "court", courtOptions(), ""),
          ),
          field(
            "rt-rate",
            "Rate per hour (PHP) *",
            input("rt-rate", "rate", {
              type: "number",
              min: 0,
              max: 100000,
              step: "0.01",
              required: true,
            }),
          ),
          field(
            "rt-day",
            "Day",
            select(
              "rt-day",
              "weekday",
              [{ value: "", label: "Every day" }].concat(
                DAYS.map((d) => ({ value: d.n, label: d.label })),
              ),
              "",
            ),
          ),
          field(
            "rt-from-t",
            "From time",
            input("rt-from-t", "from_time", { type: "time", value: "00:00" }),
          ),
          field(
            "rt-to-t",
            "To time",
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
            "Bookings already made keep their price. The most specific rate wins: a court beats all courts, a day beats every day.",
          ),
          field(
            "rt-to",
            "Ends on",
            input("rt-to", "valid_to", { type: "date" }),
            "Leave empty for no end date.",
          ),
          error,
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
        h(
          "p",
          { class: "muted" },
          "To change a price, add a new rate that starts on a date, and end the old one. Past bookings keep the price they were booked at.",
        ),
        dataTable({
          schema: {
            columns: [
              {
                key: "court",
                label: "Court",
                render: (r) => courtName(r.court_id),
              },
              {
                key: "when",
                label: "When",
                render: (r) => {
                  const whole = hhmm(r.from_time) === "00:00" &&
                    hhmm(r.to_time) >= "23:59";
                  return `${
                    r.weekday == null ? "Every day" : DAY_NAME[r.weekday]
                  }${
                    whole ? "" : `, ${hhmm(r.from_time)} to ${hhmm(r.to_time)}`
                  }`;
                },
              },
              {
                key: "rate",
                label: "Per hour",
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
                render: (r) =>
                  h(
                    "span",
                    { class: "row-actions" },
                    iconButton({
                      label: `End rate: ${describe(r)}`,
                      icon: "calendar",
                      onClick: () => endModal("court_rates", r, describe(r)),
                    }),
                    iconButton({
                      label: `Delete rate: ${describe(r)}`,
                      icon: "trash",
                      variant: "danger",
                      onClick: () =>
                        deleteModal("court_rates", r, {
                          title: "Delete this rate",
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
        title: "New blackout",
        eyebrow: "Blackouts",
        icon: "alert",
        confirmLabel: "Add blackout",
        body: h(
          "div",
          { class: "stack" },
          field(
            "bo-court",
            "Court",
            select("bo-court", "court", courtOptions(), ""),
          ),
          field(
            "bo-sd",
            "From date *",
            input("bo-sd", "start_date", {
              type: "date",
              required: true,
              value: today,
            }),
          ),
          field(
            "bo-st",
            "From time *",
            input("bo-st", "start_time", {
              type: "time",
              required: true,
              value: "08:00",
            }),
          ),
          field(
            "bo-ed",
            "To date *",
            input("bo-ed", "end_date", {
              type: "date",
              required: true,
              value: today,
            }),
          ),
          field(
            "bo-et",
            "To time *",
            input("bo-et", "end_time", {
              type: "time",
              required: true,
              value: "12:00",
            }),
            "The court can be booked again from this time.",
          ),
          field(
            "bo-reason",
            "Reason *",
            input("bo-reason", "reason", {
              required: true,
              maxlength: 200,
              placeholder: "For example: resurfacing",
            }),
          ),
          error,
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
        schema: {
          columns: [
            {
              key: "court",
              label: "Court",
              render: (r) => courtName(r.court_id),
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
              render: (r) =>
                iconButton({
                  label: `Delete blackout: ${r.reason}`,
                  icon: "trash",
                  variant: "danger",
                  onClick: () =>
                    deleteModal("court_blackouts", r, {
                      title: "Delete this blackout",
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
        emptyTitle: "No blackouts",
        emptyText:
          "Add a blackout when a court cannot be booked, for example for maintenance or an event.",
      });
    }

    // ---------------------------------------------------------------- layout
    const ADD = {
      courts: ["New court", () => courtModal(null)],
      hours: ["New hours", hoursModal],
      rates: ["New rate", rateModal],
      blackouts: ["New blackout", blackoutModal],
    };

    function draw() {
      tabsHost.replaceChildren(tabs({
        activeId: state.tab,
        tabs: TABS,
        onChange: (id) => {
          state.tab = id;
          draw();
        },
      }));
      const [label, open] = ADD[state.tab];
      const disabled = state.tab !== "courts" && state.status === "ready" &&
        state.courts.length === 0;
      const view = {
        courts: courtsView,
        hours: hoursView,
        rates: ratesView,
        blackouts: blackoutsView,
      }[state.tab];
      body.replaceChildren(
        h(
          "div",
          { class: "actions courts-actions" },
          button({
            label,
            icon: "plus",
            variant: "primary",
            disabled,
            onClick: open,
          }),
          disabled ? h("span", { class: "muted" }, "Add a court first.") : null,
        ),
        view(),
      );
    }

    page.append(
      pageHeader({
        icon: "grid",
        eyebrow: "Admin",
        title: "Courts",
        description:
          "Courts, opening hours, rates and blackout times. All times are Asia/Manila.",
      }),
      tabsHost,
      body,
    );
    refresh();
    return page;
  }

  return { courtsPage };
}
