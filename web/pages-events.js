// Events page (PLAN 6.1): the club's events and the divisions inside each one.
//   * An event has dates, a place, a fee and a registration window. It starts as a draft, then registration opens and
//     closes. Drawing and playing move it on later (stage 7); it can be cancelled with a reason.
//   * A division is a skill category plus singles or doubles, optional gender, age group and rank band. It copies the
//     chosen format and scoring rule when it is created, so later edits to a template never change a running event.
//   * Creates are idempotent (the new row's ID is made when the form opens). Everything is written by database
//     functions that check the caller; this page shows their answers in plain words. Times are Asia/Manila.
import {
  adminHero,
  attachPagePattern,
  badge,
  button,
  dataTable,
  dateControl,
  dateTimeControl,
  h,
  icon,
  iconButton,
  inputWithIcon,
  openModal,
  selectControl,
  toast,
} from "./ui.js";
import { formatDate, formatDateTime } from "./lib/dates.js";
import { formatMoney } from "./lib/money.js";

const EVENT_STATUS = {
  draft: ["Draft", "neutral"],
  registration_open: ["Registration Open", "success"],
  registration_closed: ["Registration Closed", "warning"],
  drawn: ["Drawn", "info"],
  in_progress: ["In Progress", "info"],
  completed: ["Completed", "neutral"],
  cancelled: ["Cancelled", "danger"],
};
const DIVISION_STATUS = {
  open: ["Open", "success"],
  drawn: ["Drawn", "info"],
  in_progress: ["In Progress", "info"],
  finalized: ["Finalized", "neutral"],
  cancelled: ["Cancelled", "danger"],
};
const STAGE_LABEL = {
  round_robin: "Round Robin",
  single_elimination: "Single Elimination",
  pool_play: "Pool Play",
  best_of_n_playoff: "Best-of Playoff",
  split_single_elimination: "Split Single Elimination",
};
const REG_STATUS = {
  requested: ["Waiting for Approval", "warning"],
  confirmed: ["Confirmed", "success"],
  waitlisted: ["Waitlisted", "info"],
  withdrawn: ["Withdrawn", "neutral"],
  rejected: ["Rejected", "danger"],
};
const REG_SELECT =
  "id,status,status_reason,fee_snapshot,meta,division:divisions(name,status),member:members(member_no,person:persons(display_name))";
const GENDER_LABEL = { male: "Men", female: "Women", mixed: "Mixed" };
const MANILA_OFFSET_MS = 8 * 3600 * 1000;

const EVENT_SELECT =
  "id,doc_no,name,starts_on,ends_on,location,status,status_reason,fee,registration_opens_at,registration_closes_at," +
  "cancel_reason,divisions(id,status)";
const DIVISION_SELECT =
  "id,name,category_id,format,gender,age_group,min_rank_id,max_rank_id,max_entries,status,cancel_reason," +
  "format_snapshot,scoring_snapshot,category:categories(name),stages:division_stages(id,stage_no,stage_type,status,config)";

/** "2026-11-05T09:00" typed in the form (Manila time) -> an instant; "" -> null. */
const toInstant = (v) => (v ? `${v}:00+08:00` : null);
/** An instant -> the "YYYY-MM-DDTHH:mm" the form shows (Manila time). */
const toLocalInput = (instant) =>
  instant
    ? new Date(new Date(instant).getTime() + MANILA_OFFSET_MS).toISOString()
      .slice(0, 16)
    : "";

/** The database's own messages are written for people; known codes get a plain sentence. */
function messageOf(e, fallback) {
  if (e?.code === "23505" || e?.kind === "duplicate") {
    return "This event already has a live division with that name. Choose a different name.";
  }
  const own = ["22023", "42501", "23503", "CP422", "CP409"].includes(e?.code) &&
    e.cause?.message;
  return own || e?.message || fallback;
}

export function createEventsPages({ api }) {
  function eventsPage() {
    const page = h("div", {
      class: "page admin-dashboard admin-members-page admin-events-page",
    });
    attachPagePattern(page);
    const body = h("div", { class: "events-body" });
    const state = {
      status: "loading",
      events: [],
      categories: [],
      templates: [],
      rules: [],
      open: null, // the event whose divisions are shown
      divisions: [],
      regs: [],
      pays: {},
      partners: {},
      divStatus: "ready",
    };

    async function refresh() {
      state.status = state.events.length ? "refreshing" : "loading";
      draw();
      try {
        const [events, categories, templates, rules] = await Promise.all([
          api.read((c) =>
            c.from("events").select(EVENT_SELECT).order("starts_on", {
              ascending: false,
            })
          ),
          api.read((c) =>
            c.from("categories").select(
              "id,name,sort_order,ladders:rank_ladders(id,deleted_at,ranks(id,name,sort_order,deleted_at))",
            ).is("deleted_at", null).order("sort_order")
          ),
          api.read((c) =>
            c.from("format_templates").select("id,name,description,stages")
              .is("deleted_at", null).eq("is_active", true).order("name")
          ),
          api.read((c) =>
            c.from("scoring_rules").select("id,name").is("deleted_at", null)
              .eq("is_active", true).order("name")
          ),
        ]);
        Object.assign(state, {
          events: events ?? [],
          categories: categories ?? [],
          templates: templates ?? [],
          rules: rules ?? [],
          status: "ready",
        });
        if (state.open) {
          state.open = state.events.find((e) => e.id === state.open.id) ??
            null;
        }
      } catch {
        state.status = "error";
      }
      if (state.open) await loadDivisions();
      draw();
    }

    async function loadDivisions() {
      state.divStatus = state.divisions.length ? "refreshing" : "loading";
      try {
        state.divisions = await api.read((c) =>
          c.from("divisions").select(DIVISION_SELECT).eq(
            "event_id",
            state.open.id,
          ).order("created_at")
        ) ?? [];
        state.divStatus = "ready";
      } catch {
        state.divStatus = "error";
      }
      await loadRegistrations();
    }

    async function loadRegistrations() {
      try {
        const regs = await api.read((c) =>
          c.from("registrations").select(REG_SELECT).eq(
            "event_id",
            state.open.id,
          ).order("created_at")
        ) ?? [];
        const ids = regs.map((r) =>
          r.id
        );
        const partnerIds = [
          ...new Set(
            regs.map((r) => r.meta?.partner_member_id).filter(Boolean),
          ),
        ];
        const [totals, partners] = await Promise.all([
          ids.length
            ? api.read((c) =>
              c.from("source_payment_totals").select(
                "source_id,verified_total,pending_total",
              ).eq("source_type", "event_registration").in("source_id", ids)
            )
            : [],
          partnerIds.length
            ? api.read((c) =>
              c.from("members").select(
                "id,member_no,person:persons(display_name)",
              )
                .in("id", partnerIds)
            )
            : [],
        ]);
        state.regs = regs;
        state.pays = Object.fromEntries(
          (totals ?? []).map((t) => [t.source_id, t]),
        );
        state.partners = Object.fromEntries(
          (partners ?? []).map((m) => [m.id, m]),
        );
      } catch {
        state.regs = [];
      }
    }

    // ------------------------------------------------------------- form kit
    const errorLine = () =>
      h("p", { class: "field-error form-error", role: "alert", hidden: true });
    const showError = (el, message) => {
      el.textContent = message;
      el.hidden = false;
      return false;
    };
    const field = (id, label, control, hint, iconName) =>
      h(
        "div",
        { class: "field" },
        label ? h("label", { for: id }, label) : null,
        iconName ? inputWithIcon(control, iconName) : control,
        hint
          ? h("span", { class: "field-hint", id: `${id}-hint` }, hint)
          : null,
      );
    const input = (id, name, props = {}) =>
      props.type === "date"
        ? dateControl({ id, name, ...props })
        : props.type === "datetime-local"
        ? dateTimeControl({ id, name, ...props })
        : h("input", { class: "input", id, name, ...props });
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

    /** Asks for a reason, then runs the action. */
    function reasonModal({ title, eyebrow, note, confirmLabel, run, done }) {
      const error = errorLine();
      const count = h("output", {
        class: "decision-reason-count",
        id: "ev-reason-count",
        for: "ev-reason",
      }, "0 / 500");
      return openModal({
        title,
        eyebrow,
        icon: "alert",
        confirmLabel,
        destructive: true,
        body: h(
          "div",
          { class: "member-decision" },
          eyebrow
            ? h(
              "div",
              { class: "member-decision-subject" },
              h(
                "span",
                { class: "member-avatar is-icon", "aria-hidden": "true" },
                icon("trophy"),
              ),
              h(
                "div",
                { class: "member-meta" },
                h(
                  "div",
                  { class: "member-decision-name" },
                  h("strong", { class: "member-name" }, eyebrow),
                ),
                h("span", { class: "sub member-subtext" }, title),
              ),
            )
            : null,
          h(
            "div",
            { class: "stack" },
            note
              ? h(
                "div",
                { class: "modal-callout is-danger" },
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
                    "Action Impact",
                  ),
                  h("p", { class: "decision-impact-text" }, note),
                ),
              )
              : null,
            h(
              "div",
              { class: "field" },
              h(
                "div",
                { class: "decision-field-heading" },
                h(
                  "label",
                  { for: "ev-reason" },
                  "Reason",
                  h("span", { class: "decision-required" }, " *"),
                ),
                count,
              ),
              h("textarea", {
                class: "input textarea",
                id: "ev-reason",
                name: "reason",
                rows: 4,
                minlength: 3,
                maxlength: 500,
                required: true,
                placeholder:
                  "Provide context or explanation for this decision...",
                "aria-describedby": "ev-reason-help ev-reason-count",
                onInput: (event) => {
                  count.textContent = `${event.target.value.length} / 500`;
                },
              }),
              h("p", {
                class: "muted decision-reason-help",
                id: "ev-reason-help",
              }, "Kept in the history. 3 to 500 characters."),
            ),
          ),
          error,
        ),
        onConfirm: async (form) => {
          const reason = String(form.get("reason") ?? "").trim();
          if (reason.length < 3) {
            return showError(error, "Enter a reason of at least 3 characters.");
          }
          try {
            await run(reason);
            toast(done, { tone: "success" });
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

    // ---------------------------------------------------------------- events
    function eventModal(row) {
      const editing = Boolean(row);
      const key = row?.id ?? api.newKey();
      const error = errorLine();
      return openModal({
        title: editing ? "Edit Event" : "New Event",
        eyebrow: editing ? row.doc_no : "Events",
        icon: "trophy",
        description:
          "Set the tournament dates, location, entry fee and registration window.",
        size: "lg",
        confirmLabel: editing ? "Save Changes" : "Create Event",
        body: h(
          "div",
          { class: "form-grid" },
          editing
            ? h(
              "div",
              { class: "member-decision-subject form-grid-wide" },
              h(
                "span",
                { class: "member-avatar is-icon", "aria-hidden": "true" },
                icon("trophy"),
              ),
              h(
                "div",
                { class: "member-meta" },
                h(
                  "div",
                  { class: "member-decision-name" },
                  h("strong", { class: "member-name" }, row.name),
                  badge(
                    ...(EVENT_STATUS[row.status] ?? [row.status, "neutral"]),
                  ),
                ),
                h("span", { class: "sub member-subtext" }, row.doc_no),
              ),
            )
            : null,
          h(
            "div",
            { class: "form-grid-wide" },
            field(
              "ev-name",
              "Name *",
              input("ev-name", "name", {
                required: true,
                maxlength: 120,
                value: row?.name ?? "",
                placeholder: "e.g. Capitol Open Pickleball Championship",
              }),
              "Official tournament or club event title.",
              "trophy",
            ),
          ),
          h(
            "div",
            { class: "profile-subsection-divider form-grid-wide" },
            h(
              "span",
              { class: "profile-subsection-label" },
              "Schedule & Venue",
            ),
          ),
          field(
            "ev-start",
            "First Day *",
            input("ev-start", "starts_on", {
              type: "date",
              required: true,
              value: row?.starts_on ?? "",
            }),
            "Opening day of the event (Asia/Manila).",
          ),
          field(
            "ev-end",
            "Last Day *",
            input("ev-end", "ends_on", {
              type: "date",
              required: true,
              value: row?.ends_on ?? "",
            }),
            "Final day of the event (Asia/Manila).",
          ),
          field(
            "ev-loc",
            "Location",
            input("ev-loc", "location", {
              maxlength: 120,
              value: row?.location ?? "",
              placeholder: "e.g. Capitol Pickleball Club Courts 1–4",
            }),
            "Venue or court complex shown to members.",
            "home",
          ),
          field(
            "ev-fee",
            "Registration fee (PHP)",
            input("ev-fee", "fee", {
              type: "number",
              min: 0,
              step: "0.01",
              value: row ? String(row.fee) : "0",
              placeholder: "0.00",
            }),
            "Zero means free. Members see this fee when they register.",
            "currency",
          ),
          h(
            "div",
            { class: "profile-subsection-divider form-grid-wide" },
            h(
              "span",
              { class: "profile-subsection-label" },
              "Registration Window",
            ),
          ),
          field(
            "ev-opens",
            "Registration Opens",
            input("ev-opens", "opens_at", {
              type: "datetime-local",
              value: toLocalInput(row?.registration_opens_at),
            }),
            "Optional. Manila time.",
          ),
          field(
            "ev-closes",
            "Registration Closes",
            input("ev-closes", "closes_at", {
              type: "datetime-local",
              value: toLocalInput(row?.registration_closes_at),
            }),
            "Optional. Manila time.",
          ),
          h("div", { class: "form-grid-wide" }, error),
        ),
        onConfirm: async (form) => {
          const name = String(form.get("name") ?? "").trim();
          const starts = String(form.get("starts_on") ?? "");
          const ends = String(form.get("ends_on") ?? "");
          const fee = Number(form.get("fee") || 0);
          const opens = String(form.get("opens_at") ?? "");
          const closes = String(form.get("closes_at") ?? "");
          if (!name) return showError(error, "Enter the event name.");
          if (!starts || !ends) {
            return showError(error, "Choose the first and last day.");
          }
          if (ends < starts) {
            return showError(
              error,
              "The last day cannot be before the first day.",
            );
          }
          if (!Number.isFinite(fee) || fee < 0) {
            return showError(error, "The fee is zero or more.");
          }
          if (opens && closes && closes <= opens) {
            return showError(
              error,
              "Registration must close after it opens.",
            );
          }
          const args = {
            p_name: name,
            p_starts_on: starts,
            p_ends_on: ends,
            p_location: String(form.get("location") ?? "").trim() || null,
            p_fee: fee,
            p_opens_at: toInstant(opens),
            p_closes_at: toInstant(closes),
          };
          try {
            await api.rpc(
              editing ? "update_event" : "create_event",
              { p_id: key, ...args },
            );
            toast(editing ? "Event saved." : "Event created.", {
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

    async function setStatus(ev, to, done) {
      try {
        await api.rpc("set_event_status", {
          p_id: ev.id,
          p_to: to,
          p_reason: null,
        });
        toast(done, { tone: "success" });
        await refresh();
      } catch (e) {
        toast(messageOf(e, "That did not work. Please try again."), {
          tone: "danger",
        });
      }
    }

    function cancelEvent(ev) {
      return reasonModal({
        title: "Cancel This Event",
        eyebrow: ev.name,
        note:
          "Its divisions that have not finished are cancelled too. This cannot be undone.",
        confirmLabel: "Cancel Event",
        run: (reason) =>
          api.rpc("set_event_status", {
            p_id: ev.id,
            p_to: "cancelled",
            p_reason: reason,
          }),
        done: "Event cancelled.",
      });
    }

    const liveDivisions = (ev) =>
      (ev.divisions ?? []).filter((d) => d.status !== "cancelled").length;
    const beforeDraw = (ev) =>
      ["draft", "registration_open", "registration_closed"].includes(ev.status);

    function eventsView() {
      return dataTable({
        searchState: state,
        schema: {
          columns: [
            {
              key: "name",
              label: "Event",
              render: (r) =>
                h("span", {}, r.name, h("span", { class: "sub" }, r.doc_no)),
            },
            {
              key: "dates",
              label: "Dates",
              render: (r) =>
                r.starts_on === r.ends_on
                  ? formatDate(`${r.starts_on}T00:00:00+08:00`)
                  : `${formatDate(`${r.starts_on}T00:00:00+08:00`)} – ${
                    formatDate(`${r.ends_on}T00:00:00+08:00`)
                  }`,
            },
            {
              key: "fee",
              label: "Fee",
              align: "right",
              render: (r) => Number(r.fee) ? formatMoney(r.fee) : "Free",
            },
            {
              key: "divisions",
              label: "Divisions",
              align: "right",
              render: (r) => String(liveDivisions(r)),
            },
            {
              key: "status",
              label: "Status",
              render: (r) =>
                badge(...(EVENT_STATUS[r.status] ?? [r.status, "neutral"])),
            },
            {
              key: "actions",
              label: "Action",
              align: "center",
              actionCount: 4,
              render: (r) =>
                h(
                  "span",
                  { class: "row-actions" },
                  iconButton({
                    label: `Divisions of ${r.name}`,
                    icon: "layers",
                    size: "sm",
                    variant: "info",
                    onClick: () => openEvent(r),
                  }),
                  beforeDraw(r)
                    ? iconButton({
                      label: `Edit ${r.name}`,
                      icon: "edit",
                      size: "sm",
                      variant: "edit",
                      onClick: () => eventModal(r),
                    })
                    : null,
                  r.status === "draft" || r.status === "registration_closed"
                    ? iconButton({
                      label: `Open registration for ${r.name}`,
                      icon: "check",
                      size: "sm",
                      variant: "success",
                      onClick: () =>
                        setStatus(r, "registration_open", "Registration open."),
                    })
                    : null,
                  r.status === "registration_open"
                    ? iconButton({
                      label: `Close registration for ${r.name}`,
                      icon: "lock",
                      size: "sm",
                      variant: "warning",
                      onClick: () =>
                        setStatus(
                          r,
                          "registration_closed",
                          "Registration closed.",
                        ),
                    })
                    : null,
                  r.status === "in_progress"
                    ? iconButton({
                      label: `Mark ${r.name} completed`,
                      icon: "medal",
                      size: "sm",
                      variant: "success",
                      onClick: () =>
                        setStatus(r, "completed", "Event completed."),
                    })
                    : null,
                  !["completed", "cancelled"].includes(r.status)
                    ? iconButton({
                      label: `Cancel ${r.name}`,
                      icon: "x",
                      size: "sm",
                      variant: "danger",
                      onClick: () => cancelEvent(r),
                    })
                    : null,
                ),
            },
          ],
        },
        rows: state.events,
        state: state.status,
        ariaLabel: "Events",
        onRetry: refresh,
        emptyTitle: "No events yet",
        emptyText:
          "Create an event, add its divisions, then open registration.",
      });
    }

    // ------------------------------------------------------------- divisions
    async function openEvent(ev) {
      state.open = ev;
      state.divisions = [];
      state.divStatus = "loading";
      draw();
      await loadDivisions();
      draw();
    }

    function ranksOf(categoryId) {
      const cat = state.categories.find((c) => c.id === categoryId);
      const ladder = (cat?.ladders ?? []).find((l) => !l.deleted_at);
      return (ladder?.ranks ?? []).filter((r) => !r.deleted_at).sort((a, b) =>
        a.sort_order - b.sort_order
      );
    }
    const rankOptions = (categoryId, anyLabel) =>
      [{ value: "", label: anyLabel }].concat(
        ranksOf(categoryId).map((r) => ({ value: r.id, label: r.name })),
      );

    function divisionModal(row) {
      const ev = state.open;
      const editing = Boolean(row);
      const key = row?.id ?? api.newKey();
      const error = errorLine();
      const category = select(
        "dv-cat",
        "category_id",
        state.categories.map((c) => ({ value: c.id, label: c.name })),
        row?.category_id ?? state.categories[0]?.id,
      );
      const minRank = select(
        "dv-min",
        "min_rank_id",
        rankOptions(row?.category_id ?? state.categories[0]?.id, "No Minimum"),
        row?.min_rank_id,
      );
      const maxRank = select(
        "dv-max",
        "max_rank_id",
        rankOptions(row?.category_id ?? state.categories[0]?.id, "No Maximum"),
        row?.max_rank_id,
      );
      if (!editing) {
        category.addEventListener("change", () => {
          minRank.replaceChildren(
            ...rankOptions(category.value, "No Minimum").map((o) =>
              h("option", { value: o.value }, o.label)
            ),
          );
          maxRank.replaceChildren(
            ...rankOptions(category.value, "No Maximum").map((o) =>
              h("option", { value: o.value }, o.label)
            ),
          );
        });
      }
      return openModal({
        title: editing ? "Edit Division" : "New Division",
        eyebrow: ev.name,
        icon: "layers",
        description:
          "Configure the skill category, play format, eligibility and bracket template.",
        size: "lg",
        confirmLabel: editing ? "Save Changes" : "Add Division",
        body: h(
          "div",
          { class: "form-grid" },
          editing
            ? h(
              "div",
              { class: "member-decision-subject form-grid-wide" },
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
                    ...(DIVISION_STATUS[row.status] ?? [row.status, "neutral"]),
                  ),
                ),
                h(
                  "span",
                  { class: "sub member-subtext" },
                  `${ev.name} · ${describeDivision(row)}`,
                ),
              ),
            )
            : null,
          h(
            "div",
            { class: "form-grid-wide" },
            field(
              "dv-name",
              "Division Name *",
              input("dv-name", "name", {
                required: true,
                maxlength: 120,
                value: row?.name ?? "",
                placeholder: "e.g. Novice Men's Doubles",
              }),
              "Name shown on tournament brackets and schedules.",
              "trophy",
            ),
          ),
          h(
            "div",
            { class: "profile-subsection-divider form-grid-wide" },
            h(
              "span",
              { class: "profile-subsection-label" },
              "Format & Category",
            ),
          ),
          editing ? null : field(
            "dv-cat",
            "Category (skill level) *",
            category,
            "Skill level required for this division.",
            "layers",
          ),
          editing ? null : field(
            "dv-format",
            "Singles or Doubles *",
            select("dv-format", "format", [
              { value: "singles", label: "Singles" },
              { value: "doubles", label: "Doubles" },
            ], "singles"),
            "Match team size.",
            "user",
          ),
          field(
            "dv-gender",
            "Gender",
            select("dv-gender", "gender", [
              { value: "", label: "Any" },
              { value: "male", label: "Men" },
              { value: "female", label: "Women" },
              { value: "mixed", label: "Mixed" },
            ], row?.gender ?? ""),
            "Participant gender requirement.",
            "user",
          ),
          field(
            "dv-age",
            "Age Group",
            input("dv-age", "age_group", {
              maxlength: 40,
              placeholder: "e.g. 35+",
              value: row?.age_group ?? "",
            }),
            "Optional age eligibility label.",
            "idCard",
          ),
          h(
            "div",
            { class: "profile-subsection-divider form-grid-wide" },
            h(
              "span",
              { class: "profile-subsection-label" },
              "Rank Limits & Entries",
            ),
          ),
          field(
            "dv-min",
            "Lowest Rank Allowed",
            minRank,
            "Minimum player rank required.",
            "medal",
          ),
          field(
            "dv-max",
            "Highest Rank Allowed",
            maxRank,
            "Maximum player rank allowed.",
            "medal",
          ),
          h(
            "div",
            { class: editing ? "form-grid-wide" : "" },
            field(
              "dv-limit",
              "Most Entries",
              input("dv-limit", "max_entries", {
                type: "number",
                min: 2,
                max: 512,
                step: 1,
                value: row?.max_entries ?? "",
                placeholder: "No Limit",
              }),
              "Leave empty for no limit (2 to 512).",
              "layers",
            ),
          ),
          editing ? null : field(
            "dv-format-tpl",
            "Format Template *",
            select(
              "dv-format-tpl",
              "template_id",
              state.templates.map((t) => ({ value: t.id, label: t.name })),
              state.templates[0]?.id,
            ),
            "Copied to the division at creation.",
            "settings",
          ),
          editing ? null : field(
            "dv-rule",
            "Scoring Rule",
            select("dv-rule", "scoring_rule_id", [
              { value: "", label: "Club Default" },
              ...state.rules.map((r) => ({ value: r.id, label: r.name })),
            ], ""),
            "Match point and win-by configuration.",
            "medal",
          ),
          editing
            ? h(
              "div",
              { class: "modal-callout form-grid-wide" },
              h(
                "span",
                { class: "modal-callout-icon", "aria-hidden": "true" },
                icon("info"),
              ),
              h(
                "div",
                { class: "modal-callout-text" },
                h(
                  "strong",
                  { class: "decision-impact-title" },
                  "Format & Rules Locked",
                ),
                h(
                  "p",
                  { class: "decision-impact-text" },
                  "Category, singles/doubles, format and scoring rules are fixed once a division is created.",
                ),
              ),
            )
            : null,
          h("div", { class: "form-grid-wide" }, error),
        ),
        onConfirm: async (form) => {
          const name = String(form.get("name") ?? "").trim();
          const limitText = String(form.get("max_entries") ?? "").trim();
          const limit = limitText === "" ? null : Number(limitText);
          if (!name) return showError(error, "Enter the division name.");
          if (
            limit !== null && (!Number.isInteger(limit) || limit < 2 ||
              limit > 512)
          ) {
            return showError(
              error,
              "The entry limit is a whole number from 2 to 512.",
            );
          }
          const common = {
            p_name: name,
            p_gender: String(form.get("gender") ?? "") || null,
            p_age_group: String(form.get("age_group") ?? "").trim() || null,
            p_min_rank_id: String(form.get("min_rank_id") ?? "") || null,
            p_max_rank_id: String(form.get("max_rank_id") ?? "") || null,
            p_max_entries: limit,
          };
          try {
            if (editing) {
              await api.rpc("update_division", { p_id: key, ...common });
            } else {
              if (!form.get("category_id")) {
                return showError(error, "Choose a category.");
              }
              if (!form.get("template_id")) {
                return showError(error, "Choose a format.");
              }
              await api.rpc("create_division", {
                p_id: key,
                p_event_id: ev.id,
                p_category_id: String(form.get("category_id")),
                p_format: String(form.get("format")),
                p_template_id: String(form.get("template_id")),
                p_scoring_rule_id: String(form.get("scoring_rule_id") ?? "") ||
                  null,
                ...common,
              });
            }
            toast(editing ? "Division saved." : "Division added.", {
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

    // ----------------------------------------------------------------- draw
    const stageOne = (d) => (d.stages ?? []).find((s) => s.stage_no === 1);

    async function runDraw(d) {
      try {
        await api.rpc("run_draw", { p_stage_id: stageOne(d).id });
        toast("Draw made.", { tone: "success" });
        await refresh();
        const fresh = state.divisions.find((x) => x.id === d.id);
        if (fresh) await drawModal(fresh);
      } catch (e) {
        toast(messageOf(e, "The draw did not work. Please try again."), {
          tone: "danger",
        });
      }
    }

    /** Shows the drawn order. A redo needs a reason and is kept in the history. */
    async function drawModal(d) {
      let entries = [];
      try {
        entries = await api.read((c) =>
          c.from("entries").select(
            "id,seed,members:entry_members(member:members(person:persons(display_name)))",
          ).eq("division_id", d.id).eq("status", "active").order("seed")
        ) ?? [];
      } catch {
        entries = [];
      }
      const names = (e) =>
        (e.members ?? []).map((m) => m.member?.person?.display_name).filter(
          Boolean,
        ).join(" & ") || "—";
      const canRedo = stageOne(d)?.status === "drawn";
      return openModal({
        title: "Draw",
        eyebrow: `${state.open.name} · ${d.name}`,
        icon: "layers",
        confirmLabel: canRedo ? "Redo the Draw" : "Close",
        destructive: canRedo,
        body: h(
          "div",
          { class: "stack" },
          h(
            "p",
            { class: "muted" },
            "Made by the server from a random seed that is stored, so the draw can be checked later.",
          ),
          h(
            "ol",
            { class: "draw-list" },
            ...entries.map((e) => h("li", {}, names(e))),
          ),
          canRedo
            ? h(
              "p",
              { class: "muted" },
              "Redoing the draw replaces this order. The old draw is kept in the history.",
            )
            : null,
        ),
        onConfirm: () => {
          if (!canRedo) return;
          setTimeout(() => redoDraw(d), 0);
        },
      });
    }

    function redoDraw(d) {
      const key = api.newKey();
      return reasonModal({
        title: "Redo the Draw",
        eyebrow: d.name,
        note:
          "A new random draw replaces this one. Matches already scheduled from it are cancelled.",
        confirmLabel: "Redo the Draw",
        run: (reason) =>
          api.rpc("redo_draw", {
            p_stage_id: stageOne(d).id,
            p_reason: reason,
            p_key: key,
          }),
        done: "Draw redone.",
      });
    }

    // ---------------------------------------------------------- format settings
    const poolStage = (d) =>
      (d.stages ?? []).find((s) => s.stage_type === "pool_play");

    /** Pool play: how many brackets, how many advance, how entries are placed. Fixed once the draw is made. */
    function formatSettingsModal(d) {
      const stage = poolStage(d);
      const cfg = stage.config ?? {};
      const error = errorLine();
      return openModal({
        title: "Format Settings",
        eyebrow: `${state.open.name} · ${d.name}`,
        icon: "settings",
        description:
          "Configure bracket grouping and advancement rules for pool play.",
        size: "lg",
        confirmLabel: "Save Settings",
        body: h(
          "div",
          { class: "form-grid" },
          h(
            "div",
            { class: "modal-callout form-grid-wide" },
            h(
              "span",
              { class: "modal-callout-icon", "aria-hidden": "true" },
              icon("info"),
            ),
            h(
              "div",
              { class: "modal-callout-text" },
              h(
                "strong",
                { class: "decision-impact-title" },
                "Pool Play Configuration",
              ),
              h(
                "p",
                { class: "decision-impact-text" },
                "Entries are split into round-robin brackets. Settings are locked once the tournament draw is executed.",
              ),
            ),
          ),
          field(
            "fs-size",
            "Players per Bracket *",
            input("fs-size", "target_group_size", {
              type: "number",
              min: 3,
              max: 12,
              step: 1,
              required: true,
              value: cfg.target_group_size ?? 5,
            }),
            "Target size (e.g. 20 players at 5 each make 4 brackets).",
            "user",
          ),
          field(
            "fs-count",
            "Number of Brackets",
            input("fs-count", "group_count", {
              type: "number",
              min: 1,
              max: 26,
              step: 1,
              value: cfg.group_count ?? "",
              placeholder: "Calculated automatically",
            }),
            "Optional override (1 to 26 brackets).",
            "layers",
          ),
          field(
            "fs-adv",
            "Advance from Each Bracket *",
            input("fs-adv", "advance_per_group", {
              type: "number",
              min: 1,
              max: 4,
              step: 1,
              required: true,
              value: cfg.advance_per_group ?? 2,
            }),
            "Number of top finishers advancing to playoff.",
            "trophy",
          ),
          field(
            "fs-assign",
            "Placing players in brackets",
            select("fs-assign", "group_assignment", [
              { value: "random", label: "Random Draw" },
              {
                value: "snake_by_rank",
                label: "By rank (strongest spread evenly)",
              },
            ], cfg.group_assignment ?? "random"),
            "Grouping strategy.",
            "shuffle",
          ),
          h("div", { class: "form-grid-wide" }, error),
        ),
        onConfirm: async (form) => {
          const countText = String(form.get("group_count") ?? "").trim();
          const config = {
            target_group_size: Number(form.get("target_group_size")),
            group_count: countText === "" ? null : Number(countText),
            advance_per_group: Number(form.get("advance_per_group")),
            group_assignment: String(form.get("group_assignment")),
          };
          try {
            await api.rpc("set_stage_config", {
              p_stage_id: stage.id,
              p_config: config,
            });
            toast("Settings saved.", { tone: "success" });
            await refresh();
          } catch (e) {
            return showError(
              error,
              messageOf(e, "That did not work. Try again."),
            );
          }
        },
      });
    }

    function cancelDivision(d) {
      return reasonModal({
        title: "Cancel This Division",
        eyebrow: d.name,
        note:
          "Members already registered will need to be told. This cannot be undone.",
        confirmLabel: "Cancel Division",
        run: (reason) =>
          api.rpc("cancel_division", { p_id: d.id, p_reason: reason }),
        done: "Division cancelled.",
      });
    }

    const describeDivision = (d) =>
      [
        d.format === "doubles" ? "Doubles" : "Singles",
        GENDER_LABEL[d.gender],
        d.age_group,
      ].filter(Boolean).join(" · ");
    const stageNames = (d) =>
      (d.format_snapshot ?? []).map((s) =>
        STAGE_LABEL[s.stage_type] ?? s.stage_type
      ).join(" → ");

    function divisionsView() {
      return dataTable({
        searchState: state,
        schema: {
          columns: [
            {
              key: "name",
              label: "Division",
              render: (r) =>
                h(
                  "span",
                  {},
                  r.name,
                  h("span", { class: "sub" }, describeDivision(r)),
                ),
            },
            {
              key: "category",
              label: "Category",
              render: (r) => r.category?.name ?? "—",
            },
            {
              key: "format",
              label: "Format",
              render: (r) =>
                h(
                  "span",
                  {},
                  stageNames(r),
                  h(
                    "span",
                    { class: "sub" },
                    r.scoring_snapshot?.name ?? "",
                  ),
                ),
            },
            {
              key: "limit",
              label: "Most Entries",
              align: "right",
              render: (r) => r.max_entries ? String(r.max_entries) : "No Limit",
            },
            {
              key: "status",
              label: "Status",
              render: (r) =>
                badge(...(DIVISION_STATUS[r.status] ?? [r.status, "neutral"])),
            },
            {
              key: "actions",
              label: "Action",
              align: "center",
              actionCount: 4,
              render: (r) =>
                h(
                  "span",
                  { class: "row-actions" },
                  r.status === "open" &&
                    state.open.status === "registration_closed"
                    ? iconButton({
                      label: `Run the draw for ${r.name}`,
                      icon: "shuffle",
                      size: "sm",
                      variant: "success",
                      onClick: () => runDraw(r),
                    })
                    : null,
                  ["drawn", "in_progress", "finalized"].includes(r.status)
                    ? iconButton({
                      label: `Open the bracket for ${r.name}`,
                      icon: "trophy",
                      size: "sm",
                      variant: "info",
                      onClick: () => {
                        location.hash = `#/bracket?division=${r.id}`;
                      },
                    })
                    : null,
                  ["drawn", "in_progress", "finalized"].includes(r.status)
                    ? iconButton({
                      label: `View the draw for ${r.name}`,
                      icon: "eye",
                      size: "sm",
                      variant: "info",
                      onClick: () => drawModal(r),
                    })
                    : null,
                  r.status === "open" && poolStage(r)
                    ? iconButton({
                      label: `Format settings for ${r.name}`,
                      icon: "settings",
                      size: "sm",
                      variant: "edit",
                      onClick: () => formatSettingsModal(r),
                    })
                    : null,
                  r.status === "open"
                    ? iconButton({
                      label: `Edit ${r.name}`,
                      icon: "edit",
                      size: "sm",
                      variant: "edit",
                      onClick: () => divisionModal(r),
                    })
                    : null,
                  ["open", "drawn", "in_progress"].includes(r.status)
                    ? iconButton({
                      label: `Cancel ${r.name}`,
                      icon: "x",
                      size: "sm",
                      variant: "danger",
                      onClick: () => cancelDivision(r),
                    })
                    : null,
                ),
            },
          ],
        },
        rows: state.divisions,
        state: state.divStatus,
        ariaLabel: "Divisions",
        onRetry: async () => {
          await loadDivisions();
          draw();
        },
        emptyTitle: "No divisions yet",
        emptyText:
          "Add a division for each category and format you want to run. Registration cannot open without one.",
      });
    }

    async function decide(r, action) {
      try {
        await api.rpc("decide_registration", {
          p_registration_id: r.id,
          p_action: action,
          p_reason: null,
        });
        toast("Registration approved.", { tone: "success" });
        await loadRegistrations();
        draw();
      } catch (e) {
        toast(messageOf(e, "That did not work. Please try again."), {
          tone: "danger",
        });
      }
    }

    function rejectRegistration(r) {
      return reasonModal({
        title: "Reject This Registration",
        eyebrow: r.member?.person?.display_name ?? "",
        confirmLabel: "Reject",
        run: (reason) =>
          api.rpc("decide_registration", {
            p_registration_id: r.id,
            p_action: "reject",
            p_reason: reason,
          }),
        done: "Registration rejected.",
      });
    }

    function withdrawRegistration(r) {
      return reasonModal({
        title: "Withdraw This Registration",
        eyebrow: r.member?.person?.display_name ?? "",
        note: r.status === "confirmed" && Number(r.fee_snapshot) > 0
          ? "The fee charge is reversed on the member's account. Void any payment separately if money is handed back."
          : null,
        confirmLabel: "Withdraw",
        run: (reason) =>
          api.rpc("withdraw_registration", {
            p_registration_id: r.id,
            p_reason: reason,
          }),
        done: "Registration withdrawn.",
      });
    }

    /** 1 for the oldest waiting registration of its division, 2 for the next, ... */
    function waitlistPlace(r) {
      let n = 0;
      for (const x of state.regs) {
        if (
          x.division?.name === r.division?.name && x.status === "waitlisted"
        ) {
          n++;
          if (x.id === r.id) return n;
        }
      }
      return 0;
    }

    function registrationsView() {
      return dataTable({
        searchState: state,
        schema: {
          columns: [
            {
              key: "member",
              label: "Member",
              render: (r) => {
                const partner = state.partners[r.meta?.partner_member_id];
                return h(
                  "span",
                  {},
                  r.member?.person?.display_name ?? "—",
                  h(
                    "span",
                    { class: "sub" },
                    [
                      r.member?.member_no,
                      partner
                        ? `with ${
                          partner.person?.display_name ?? partner.member_no
                        }`
                        : null,
                      r.meta?.override_reason
                        ? `Exception: ${r.meta.override_reason}`
                        : null,
                    ].filter(Boolean).join(" · "),
                  ),
                );
              },
            },
            {
              key: "division",
              label: "Division",
              render: (r) => r.division?.name ?? "—",
            },
            {
              key: "paid",
              label: "Paid",
              align: "right",
              render: (r) =>
                Number(r.fee_snapshot)
                  ? `${formatMoney(state.pays[r.id]?.verified_total ?? 0)} of ${
                    formatMoney(r.fee_snapshot)
                  }`
                  : "Free",
            },
            {
              key: "status",
              label: "Status",
              render: (r) =>
                h(
                  "span",
                  {},
                  badge(...(REG_STATUS[r.status] ?? [r.status, "neutral"])),
                  r.status === "waitlisted"
                    ? h(
                      "span",
                      { class: "sub" },
                      `Place ${waitlistPlace(r)} on the waitlist`,
                    )
                    : r.status_reason
                    ? h("span", { class: "sub" }, r.status_reason)
                    : null,
                ),
            },
            {
              key: "actions",
              label: "Action",
              align: "center",
              actionCount: 1,
              render: (r) =>
                ["confirmed", "waitlisted"].includes(r.status) &&
                  r.division?.status === "open"
                  ? iconButton({
                    label: `Withdraw ${
                      r.member?.person?.display_name ?? "registration"
                    }`,
                    icon: "x",
                    size: "sm",
                    variant: "danger",
                    onClick: () => withdrawRegistration(r),
                  })
                  : r.status === "requested"
                  ? h(
                    "span",
                    { class: "row-actions" },
                    iconButton({
                      label: `Approve ${
                        r.member?.person?.display_name ?? "registration"
                      }`,
                      icon: "check",
                      size: "sm",
                      variant: "success",
                      onClick: () => decide(r, "approve"),
                    }),
                    iconButton({
                      label: `Reject ${
                        r.member?.person?.display_name ?? "registration"
                      }`,
                      icon: "x",
                      size: "sm",
                      variant: "danger",
                      onClick: () => rejectRegistration(r),
                    }),
                  )
                  : null,
            },
          ],
        },
        rows: state.regs,
        state: state.divStatus,
        ariaLabel: "Registrations",
        onRetry: async () => {
          await loadRegistrations();
          draw();
        },
        emptyTitle: "No registrations yet",
        emptyText: "Members' registrations for this event appear here.",
      });
    }

    const wrapTable = (table) =>
      h(
        "div",
        { class: "member-directory-card is-auto-grid" },
        h("div", { class: "table-host" }, table),
      );

    function detailView() {
      const ev = state.open;
      const [statusLabel, statusTone] = EVENT_STATUS[ev.status] ??
        [ev.status, "neutral"];
      const canAdd = !["completed", "cancelled"].includes(ev.status);
      return h(
        "div",
        { class: "stack" },
        h(
          "div",
          { class: "actions events-actions" },
          button({
            label: "All Events",
            icon: "chevl",
            variant: "secondary",
            onClick: () => {
              state.open = null;
              draw();
            },
          }),
          canAdd
            ? button({
              label: "New Division",
              icon: "plus",
              variant: "primary",
              onClick: () => divisionModal(null),
            })
            : null,
        ),
        h(
          "div",
          { class: "member-panel events-summary" },
          h("h2", {}, ev.name),
          badge(statusLabel, statusTone),
          h(
            "p",
            { class: "muted" },
            [
              ev.doc_no,
              ev.location,
              Number(ev.fee) ? formatMoney(ev.fee) : "Free",
              ev.registration_opens_at
                ? `Registration opens ${
                  formatDateTime(ev.registration_opens_at)
                }`
                : null,
              ev.registration_closes_at
                ? `closes ${formatDateTime(ev.registration_closes_at)}`
                : null,
            ].filter(Boolean).join(" · "),
          ),
          ev.status === "cancelled" && ev.cancel_reason
            ? h("p", { class: "muted" }, `Cancelled: ${ev.cancel_reason}`)
            : null,
        ),
        wrapTable(divisionsView()),
        h("h3", {}, "Registrations"),
        wrapTable(registrationsView()),
      );
    }

    // ---------------------------------------------------------------- layout
    const newEventBtn = button({
      label: "New Event",
      icon: "plus",
      variant: "primary",
      onClick: () => eventModal(null),
    });

    function draw() {
      newEventBtn.hidden = Boolean(state.open);
      if (state.open) {
        body.replaceChildren(detailView());
        return;
      }
      body.replaceChildren(
        wrapTable(eventsView()),
      );
    }

    page.append(
      adminHero({
        title: "Events",
        chip: "Events Management",
        description:
          "Create events, add their divisions, and open or close registration. All times are Asia/Manila.",
        actions: [newEventBtn],
      }),
      body,
    );
    refresh();
    return page;
  }

  return { eventsPage };
}
