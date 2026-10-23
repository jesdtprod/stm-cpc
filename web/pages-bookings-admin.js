// Admin booking pages (PLAN 5.1 to 5.4): the booking queue and calendar, and the payment queue.
// Each action calls one server function (decide_booking, cancel_booking, decide_payment, void_payment) that checks the
// permission, takes an idempotency key (made when the window opens, reused if the click is repeated), changes the state
// and writes the audit row. The buttons shown follow the caller's permissions, but the database decides.
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
import { can } from "./lib/permissions.js";
import { businessDate, formatDateTime } from "./lib/dates.js";
import { formatMoney } from "./lib/money.js";
import {
  buildSlots,
  manilaDate,
  parseRange,
  timeLabel,
} from "./lib/slot-grid.js";
import { bookingMessage } from "./pages-booking.js";

const STATUS = {
  pending_approval: ["Waiting for approval", "warning"],
  confirmed: ["Confirmed", "success"],
  checked_in: ["Checked in", "info"],
  completed: ["Completed", "neutral"],
  rejected: ["Rejected", "danger"],
  cancelled: ["Cancelled", "neutral"],
  no_show: ["No-show", "danger"],
  expired: ["Expired", "neutral"],
};
const PAY_STATUS = {
  submitted: ["Waiting to be checked", "warning"],
  verified: ["Verified", "success"],
  rejected: ["Rejected", "danger"],
  void: ["Voided", "neutral"],
};
const METHOD_LABEL = {
  cash: "Cash",
  gcash: "GCash",
  maya: "Maya",
  bank_transfer: "Bank transfer",
  other: "Other",
};
const BOOKING_SELECT =
  "id,doc_no,court_id,court_name_snapshot,during,status,status_reason,cancel_reason,price_snapshot,expires_at,created_at," +
  "requester:members!bookings_requested_by_member_id_fkey(member_no,persons(display_name))";

const who = (m) => m?.persons?.display_name ?? "Member";
const sub = (text) => h("span", { class: "sub" }, text);

export function createBookingAdminPages({ api, client }) {
  // ---------------------------------------------------------------- shared
  const errorLine = () =>
    h("p", { class: "field-error form-error", role: "alert", hidden: true });
  const showError = (el, message) => {
    el.textContent = message;
    el.hidden = false;
    return false;
  };

  /** A window with an optional reason; the call gets (reason, key). Stays open and shows the message on failure. */
  function actionModal(
    {
      title,
      eyebrow,
      icon = "check",
      verb,
      destructive = false,
      note,
      reasonLabel,
      reasonRequired = false,
      run,
      done,
    },
  ) {
    const key = api.newKey();
    const error = errorLine();
    return openModal({
      title,
      eyebrow,
      icon: destructive ? "alert" : icon,
      destructive,
      confirmLabel: verb,
      body: h(
        "div",
        { class: "stack" },
        note ? h("p", {}, note) : null,
        reasonLabel
          ? h(
            "div",
            { class: "field" },
            h(
              "label",
              { for: "act-reason" },
              reasonLabel + (reasonRequired ? " *" : ""),
            ),
            h("textarea", {
              class: "input textarea",
              id: "act-reason",
              name: "reason",
              rows: 3,
              maxlength: 500,
              required: reasonRequired,
            }),
          )
          : null,
        error,
      ),
      onConfirm: async (form) => {
        const reason = String(form.get("reason") ?? "").trim();
        if (reasonRequired && reason.length < 3) {
          return showError(
            error,
            "Please give a reason (at least 3 characters).",
          );
        }
        try {
          await run(reason || null, key);
          toast(`${verb} done.`, { tone: "success" });
          await done();
        } catch (e) {
          return showError(error, bookingMessage(e));
        }
      },
    });
  }

  async function totalsFor(ids) {
    if (!ids.length) return {};
    const rows = await api.read((c) =>
      c.from("source_payment_totals").select(
        "source_id,verified_total,pending_total",
      ).eq("source_type", "booking").in("source_id", ids)
    );
    return Object.fromEntries((rows ?? []).map((t) => [t.source_id, t]));
  }

  // =============================================================== bookings
  function bookingsPage() {
    const page = h("div", { class: "page" });
    const tabsHost = h("div", {});
    const body = h("div", { class: "booking-admin-body" });
    const state = {
      tab: "approve",
      status: "loading",
      active: [],
      history: [],
      pays: {},
      settings: {},
      calendar: {
        day: businessDate(),
        courts: [],
        hours: [],
        bookings: [],
        blackouts: [],
        slotMinutes: 60,
        status: "idle",
      },
    };

    async function refresh() {
      state.status = state.active.length ? "refreshing" : "loading";
      draw();
      try {
        const [active, history, settings] = await Promise.all([
          api.read((c) =>
            c.from("bookings").select(BOOKING_SELECT).in("status", [
              "pending_approval",
              "confirmed",
              "checked_in",
            ])
              .order("during").limit(300)
          ),
          api.read((c) =>
            c.from("bookings").select(BOOKING_SELECT).in("status", [
              "completed",
              "rejected",
              "cancelled",
              "no_show",
              "expired",
            ])
              .order("created_at", { ascending: false }).limit(100)
          ),
          api.read((c) =>
            c.from("settings").select("key,value").in("key", [
              "payments.required.court_booking",
              "booking.slot_minutes",
            ]).is("unit_id", null).is("deleted_at", null)
          ),
        ]);
        state.active = active ?? [];
        state.history = history ?? [];
        state.settings = Object.fromEntries(
          (settings ?? []).map((s) => [s.key, s.value]),
        );
        state.pays = await totalsFor(
          [...state.active, ...state.history].map((b) => b.id),
        );
        state.status = "ready";
      } catch {
        state.status = "error";
      }
      draw();
    }

    const range = (r) => parseRange(r.during);
    const paid = (r) => Number(state.pays[r.id]?.verified_total ?? 0);
    const waiting = (r) => Number(state.pays[r.id]?.pending_total ?? 0);
    const payRequired = () =>
      state.settings["payments.required.court_booking"] === true;

    const call = (name, args) => (reason, key) =>
      api.rpc(name, { ...args, p_reason: reason, p_key: key });
    const decide = (r, action) => (reason, key) =>
      api.rpc("decide_booking", {
        p_booking_id: r.id,
        p_action: action,
        p_reason: reason,
        p_key: key,
      });

    function actionsFor(r) {
      const b = [];
      const x = range(r);
      const approve = can("bookings.approve");
      const front = can("bookings.checkin");
      const cancelAny = can("bookings.cancel_any");
      const label = `${r.doc_no}, ${who(r.requester)}`;
      if (r.status === "pending_approval" && approve) {
        const blocked = payRequired() && Number(r.price_snapshot) > 0 &&
          paid(r) < Number(r.price_snapshot);
        b.push(
          iconButton({
            label: blocked
              ? `Approve ${label} (payment not verified yet)`
              : `Approve ${label}`,
            icon: "check",
            disabled: blocked,
            onClick: () =>
              actionModal({
                title: "Approve this booking",
                eyebrow: label,
                verb: "Approve",
                note: `${r.court_name_snapshot}, ${formatDateTime(x?.start)}.`,
                reasonLabel: "Note (optional)",
                run: decide(r, "approve"),
                done: refresh,
              }),
          }),
          iconButton({
            label: `Reject ${label}`,
            icon: "x",
            onClick: () =>
              actionModal({
                title: "Reject this request",
                eyebrow: label,
                verb: "Reject",
                destructive: true,
                note: "The time is released for other members.",
                reasonLabel: "Reason (shown to the member)",
                reasonRequired: true,
                run: decide(r, "reject"),
                done: refresh,
              }),
          }),
        );
      }
      if (r.status === "confirmed" && front && x) {
        const t = Date.now();
        if (t >= x.start.getTime() - 3600_000 && t < x.end.getTime()) {
          b.push(
            iconButton({
              label: `Check in ${label}`,
              icon: "check",
              onClick: () =>
                actionModal({
                  title: "Check in",
                  eyebrow: label,
                  verb: "Check in",
                  run: decide(r, "check_in"),
                  done: refresh,
                }),
            }),
          );
        }
        if (t >= x.start.getTime()) {
          b.push(iconButton({
            label: `Mark ${label} as a no-show`,
            icon: "alert",
            variant: "danger",
            onClick: () =>
              actionModal({
                title: "Mark as a no-show",
                eyebrow: label,
                verb: "Mark no-show",
                destructive: true,
                note:
                  "The no-show fee, if the club has one, is charged to the member.",
                reasonLabel: "Note (optional)",
                run: decide(r, "no_show"),
                done: refresh,
              }),
          }));
        }
      }
      if (r.status === "checked_in" && front) {
        b.push(iconButton({
          label: `Complete ${label}`,
          icon: "check",
          onClick: () =>
            actionModal({
              title: "Complete this booking",
              eyebrow: label,
              verb: "Complete",
              run: decide(r, "complete"),
              done: refresh,
            }),
        }));
      }
      if (["pending_approval", "confirmed"].includes(r.status) && cancelAny) {
        b.push(iconButton({
          label: `Cancel ${label}`,
          icon: "trash",
          variant: "danger",
          onClick: () =>
            actionModal({
              title: "Cancel this booking",
              eyebrow: label,
              verb: "Cancel booking",
              destructive: true,
              note:
                "The member is told and no late fee is charged. A confirmed booking's charge is reversed.",
              reasonLabel: "Reason",
              reasonRequired: true,
              run: call("cancel_booking", { p_booking_id: r.id }),
              done: refresh,
            }),
        }));
      }
      return h("span", { class: "row-actions" }, ...b);
    }

    const columns = [
      {
        key: "who",
        label: "Member",
        render: (r) =>
          h(
            "span",
            {},
            who(r.requester),
            sub(`${r.requester?.member_no ?? ""} · ${r.doc_no}`),
          ),
      },
      {
        key: "when",
        label: "Court and time",
        render: (r) => {
          const x = range(r);
          return h(
            "span",
            {},
            r.court_name_snapshot,
            sub(x ? `${formatDateTime(x.start)} to ${timeLabel(x.end)}` : ""),
          );
        },
      },
      {
        key: "status",
        label: "Status",
        render: (r) =>
          h(
            "span",
            {},
            badge(...(STATUS[r.status] ?? [r.status, "neutral"])),
            r.status === "pending_approval" && r.expires_at
              ? sub(`Expires ${formatDateTime(r.expires_at)}`)
              : null,
            r.cancel_reason ||
              (["rejected", "no_show", "expired"].includes(r.status)
                ? r.status_reason
                : null)
              ? sub(r.cancel_reason || r.status_reason)
              : null,
          ),
      },
      {
        key: "price",
        label: "Price",
        align: "right",
        render: (r) =>
          Number(r.price_snapshot) > 0 ? formatMoney(r.price_snapshot) : "Free",
      },
      {
        key: "pay",
        label: "Payment",
        render: (r) => {
          if (!(Number(r.price_snapshot) > 0)) return "—";
          if (paid(r) >= Number(r.price_snapshot)) {
            return badge("Paid", "success");
          }
          return h(
            "span",
            {},
            paid(r) ? `${formatMoney(paid(r))} paid` : "Not paid",
            waiting(r) ? sub(`${formatMoney(waiting(r))} to check`) : null,
          );
        },
      },
      { key: "actions", label: "Action", align: "center", render: actionsFor },
    ];

    const startOfToday = () => manilaDate(businessDate(), "00:00").getTime();
    const lists = {
      approve: () =>
        state.active.filter((r) => r.status === "pending_approval").sort((
          a,
          b,
        ) => a.created_at.localeCompare(b.created_at)),
      today: () =>
        state.active.filter((r) => {
          const x = range(r);
          return r.status !== "pending_approval" && x &&
            x.end.getTime() > startOfToday() &&
            x.start.getTime() < startOfToday() + 24 * 3600_000;
        }),
      upcoming: () =>
        state.active.filter((r) =>
          r.status === "confirmed" &&
          range(r)?.start.getTime() >= startOfToday() + 24 * 3600_000
        ),
      history: () => state.history,
    };
    const EMPTY = {
      approve: [
        "Nothing waiting",
        "Requests from members that need a decision appear here.",
      ],
      today: [
        "No bookings today",
        "Confirmed bookings for today appear here for check-in.",
      ],
      upcoming: [
        "No upcoming bookings",
        "Confirmed bookings after today appear here.",
      ],
      history: [
        "No history yet",
        "Finished, cancelled and declined bookings appear here.",
      ],
    };

    // ------------------------------------------------------------- calendar
    async function loadCalendar() {
      const cal = state.calendar;
      cal.status = "loading";
      draw();
      try {
        const from = manilaDate(cal.day, "00:00");
        const to = new Date(from.getTime() + 24 * 3600_000);
        const window = `[${from.toISOString()},${to.toISOString()})`;
        const [courts, hours, bookings, blackouts] = await Promise.all([
          api.read((c) =>
            c.from("courts").select("id,name,status,sort_order").is(
              "deleted_at",
              null,
            ).order("sort_order")
          ),
          api.read((c) =>
            c.from("court_hours").select(
              "court_id,weekday,opens_at,closes_at,valid_from,valid_to",
            ).is("deleted_at", null)
          ),
          api.read((c) =>
            c.from("bookings").select(BOOKING_SELECT).in("status", [
              "pending_approval",
              "confirmed",
              "checked_in",
              "completed",
            ]).overlaps("during", window)
          ),
          api.read((c) =>
            c.from("court_blackouts").select("court_id,during,reason").is(
              "deleted_at",
              null,
            ).overlaps("during", window)
          ),
        ]);
        Object.assign(cal, {
          courts: courts ?? [],
          hours: hours ?? [],
          bookings: bookings ?? [],
          blackouts: blackouts ?? [],
          slotMinutes: Number(state.settings["booking.slot_minutes"]) || 60,
          status: "ready",
        });
      } catch {
        cal.status = "error";
      }
      draw();
    }

    function calendarView() {
      const cal = state.calendar;
      const today = businessDate();
      const day = h("input", {
        class: "input",
        id: "cal-day",
        type: "date",
        value: cal.day,
        "aria-label": "Day",
        onChange: (e) => {
          if (e.target.value) {
            cal.day = e.target.value;
            loadCalendar();
          }
        },
      });
      const shift = (n) => {
        const d = new Date(`${cal.day}T12:00:00+08:00`);
        d.setUTCDate(d.getUTCDate() + n);
        cal.day = businessDate(d);
        loadCalendar();
      };
      const bar = h(
        "div",
        { class: "book-day" },
        iconButton({
          label: "Previous day",
          icon: "chevronLeft",
          onClick: () => shift(-1),
        }),
        day,
        iconButton({
          label: "Next day",
          icon: "chevronRight",
          onClick: () => shift(1),
        }),
        cal.day === today ? null : button({
          label: "Today",
          onClick: () => {
            cal.day = today;
            loadCalendar();
          },
        }),
      );
      if (cal.status === "loading" || cal.status === "idle") {
        return h(
          "div",
          { class: "stack" },
          bar,
          h("p", { class: "muted", "aria-busy": "true" }, "Loading…"),
        );
      }
      if (cal.status === "error") {
        return h(
          "div",
          { class: "stack" },
          bar,
          h(
            "div",
            { class: "card home-error", role: "alert" },
            h("p", {}, "The calendar could not be loaded."),
            button({
              label: "Try again",
              icon: "refresh",
              onClick: loadCalendar,
            }),
          ),
        );
      }
      const cards = cal.courts.map((court) => {
        const taken = [
          ...cal.bookings.filter((b) => b.court_id === court.id).map((b) => {
            const x = range(b);
            return x &&
              {
                start: x.start,
                end: x.end,
                kind: "booked",
                label: `${who(b.requester)} (${
                  (STATUS[b.status] ?? [b.status])[0]
                })`,
                booking: b,
              };
          }),
          ...cal.blackouts.filter((b) =>
            b.court_id == null || b.court_id === court.id
          ).map((b) => {
            const x = parseRange(b.during);
            return x &&
              { start: x.start, end: x.end, kind: "closed", label: b.reason };
          }),
        ].filter(Boolean);
        const slots = buildSlots({
          day: cal.day,
          courtId: court.id,
          hours: cal.hours,
          slotMinutes: cal.slotMinutes,
          taken,
          now: new Date(0),
          advanceDays: 100000,
        });
        return h(
          "section",
          { class: "card book-court", "aria-label": court.name },
          h(
            "div",
            { class: "ladder-head" },
            h(
              "div",
              {},
              h("h2", { class: "settings-title" }, court.name),
              court.status === "available"
                ? null
                : h("span", { class: "muted" }, court.status),
            ),
          ),
          slots.length
            ? h(
              "div",
              { class: "slots slots-wide" },
              ...slots.map((s) => {
                const text = timeLabel(s.start);
                const hit = taken.find((t) =>
                  t.start < s.end && t.end > s.start
                );
                return h(
                  "button",
                  {
                    type: "button",
                    class: `slot slot-${s.state === "past" ? "free" : s.state}`,
                    disabled: !hit,
                    "aria-label": `${text}, ${hit ? hit.label : "free"}`,
                    onClick: () => hit?.booking && detailsModal(hit.booking),
                  },
                  h("span", {}, text),
                  hit ? h("span", { class: "slot-note" }, hit.label) : null,
                );
              }),
            )
            : h("p", { class: "muted" }, "Closed this day."),
        );
      });
      return h(
        "div",
        { class: "stack" },
        bar,
        ...(cards.length
          ? cards
          : [h("div", { class: "card" }, h("p", {}, "No courts yet."))]),
      );
    }

    function detailsModal(r) {
      const x = range(r);
      return openModal({
        title: `${who(r.requester)} · ${r.doc_no}`,
        eyebrow: r.court_name_snapshot,
        icon: "calendar",
        confirmLabel: "Close",
        cancelLabel: "Close",
        body: h(
          "dl",
          { class: "details" },
          ...[
            [
              "When",
              x ? `${formatDateTime(x.start)} to ${timeLabel(x.end)}` : "—",
            ],
            ["Member", `${who(r.requester)} (${r.requester?.member_no ?? ""})`],
            ["Status", (STATUS[r.status] ?? [r.status])[0]],
            [
              "Price",
              Number(r.price_snapshot) > 0
                ? formatMoney(r.price_snapshot)
                : "Free",
            ],
          ].map(([k, v]) =>
            h("div", { class: "kv" }, h("dt", {}, k), h("dd", {}, v))
          ),
        ),
        onConfirm: () => {},
      });
    }

    // ---------------------------------------------------------------- layout
    function draw() {
      const counts = {
        approve: lists.approve().length,
        today: lists.today().length,
      };
      tabsHost.replaceChildren(tabs({
        activeId: state.tab,
        tabs: [
          {
            id: "approve",
            label: "To approve",
            badge: counts.approve || undefined,
          },
          { id: "today", label: "Today", badge: counts.today || undefined },
          { id: "upcoming", label: "Upcoming" },
          { id: "calendar", label: "Calendar" },
          { id: "history", label: "History" },
        ],
        onChange: (id) => {
          state.tab = id;
          if (id === "calendar" && state.calendar.status === "idle") {
            loadCalendar();
          } else draw();
        },
      }));
      if (state.tab === "calendar") {
        body.replaceChildren(calendarView());
        return;
      }
      const [title, text] = EMPTY[state.tab];
      body.replaceChildren(dataTable({
        schema: { columns },
        rows: lists[state.tab](),
        state: state.status === "refreshing" ? "ready" : state.status,
        ariaLabel: "Bookings",
        onRetry: refresh,
        emptyTitle: title,
        emptyText: text,
      }));
    }

    page.append(
      pageHeader({
        icon: "calendar",
        eyebrow: "Admin",
        title: "Bookings",
        description:
          "Approve court requests, check members in, and see the day's courts. All times are Asia/Manila.",
      }),
      tabsHost,
      body,
    );
    refresh();
    return page;
  }

  // =============================================================== payments
  function paymentsPage() {
    const page = h("div", { class: "page" });
    const tabsHost = h("div", {});
    const body = h("div", { class: "booking-admin-body" });
    const state = { tab: "check", status: "loading", rows: [], bookings: {} };

    async function refresh() {
      state.status = state.rows.length ? "refreshing" : "loading";
      draw();
      try {
        const rows = await api.read((c) =>
          c.from("payment_submissions").select(
            "id,doc_no,method,reference_no,amount,status,created_at,reject_reason,void_reason,source_id," +
              "payer:members!payment_submissions_payer_member_id_fkey(member_no,persons(display_name)),file:files(storage_path)",
          ).order("created_at", { ascending: false }).limit(150)
        );
        state.rows = rows ?? [];
        const ids = [...new Set(state.rows.map((p) => p.source_id))];
        const bks = ids.length
          ? await api.read((c) =>
            c.from("bookings").select(
              "id,doc_no,court_name_snapshot,price_snapshot,status",
            ).in("id", ids)
          )
          : [];
        state.bookings = Object.fromEntries((bks ?? []).map((b) => [b.id, b]));
        state.status = "ready";
      } catch {
        state.status = "error";
      }
      draw();
    }

    async function viewProof(p) {
      const path = p.file?.storage_path;
      if (!path) return;
      try {
        const { data, error } = await client.storage.from("payment-proofs")
          .createSignedUrl(path, 60);
        if (error || !data?.signedUrl) throw error ?? new Error("no link");
        const a = h("a", {
          href: data.signedUrl,
          target: "_blank",
          rel: "noopener noreferrer",
        });
        document.body.append(a);
        a.click();
        a.remove();
      } catch {
        toast("The proof could not be opened.", { tone: "error" });
      }
    }

    const pay = (p, name, extra = {}) => (reason, key) =>
      api.rpc(name, {
        p_payment_id: p.id,
        ...extra,
        p_reason: reason,
        p_key: key,
      });

    function actionsFor(p) {
      const b = [];
      const label = `${p.doc_no}, ${who(p.payer)}`;
      if (p.file?.storage_path) {
        b.push(
          iconButton({
            label: `View the proof for ${label}`,
            icon: "eye",
            onClick: () => viewProof(p),
          }),
        );
      }
      if (p.status === "submitted" && can("payments.verify")) {
        b.push(
          iconButton({
            label: `Verify ${label}`,
            icon: "check",
            onClick: () =>
              actionModal({
                title: "Verify this payment",
                eyebrow: label,
                verb: "Verify",
                note: `${formatMoney(p.amount)} by ${
                  METHOD_LABEL[p.method] ?? p.method
                } is credited to the member. Check the proof and the reference first.`,
                run: (reason, key) =>
                  api.rpc("decide_payment", {
                    p_payment_id: p.id,
                    p_action: "verify",
                    p_reason: reason,
                    p_key: key,
                  }),
                done: refresh,
              }),
          }),
          iconButton({
            label: `Reject ${label}`,
            icon: "x",
            onClick: () =>
              actionModal({
                title: "Reject this payment",
                eyebrow: label,
                verb: "Reject",
                destructive: true,
                reasonLabel: "Reason (shown to the member)",
                reasonRequired: true,
                run: (reason, key) =>
                  api.rpc("decide_payment", {
                    p_payment_id: p.id,
                    p_action: "reject",
                    p_reason: reason,
                    p_key: key,
                  }),
                done: refresh,
              }),
          }),
        );
      }
      if (p.status === "verified" && can("payments.void")) {
        b.push(iconButton({
          label: `Void ${label}`,
          icon: "trash",
          variant: "danger",
          onClick: () =>
            actionModal({
              title: "Void this payment",
              eyebrow: label,
              verb: "Void payment",
              destructive: true,
              note:
                "Use this for a refund or a mistake. The credit is reversed in the ledger. Any cash refund is handled outside the app.",
              reasonLabel: "Reason",
              reasonRequired: true,
              run: pay(p, "void_payment"),
              done: refresh,
            }),
        }));
      }
      return h("span", { class: "row-actions" }, ...b);
    }

    const columns = [
      {
        key: "who",
        label: "Member",
        render: (p) =>
          h(
            "span",
            {},
            who(p.payer),
            sub(`${p.payer?.member_no ?? ""} · ${p.doc_no}`),
          ),
      },
      {
        key: "for",
        label: "For booking",
        render: (p) => {
          const b = state.bookings[p.source_id];
          return b
            ? h(
              "span",
              {},
              b.doc_no,
              sub(
                `${b.court_name_snapshot} · ${formatMoney(b.price_snapshot)}`,
              ),
            )
            : "—";
        },
      },
      {
        key: "how",
        label: "Method",
        render: (p) =>
          h(
            "span",
            {},
            METHOD_LABEL[p.method] ?? p.method,
            p.reference_no ? sub(`Ref ${p.reference_no}`) : null,
            p.file ? sub("Proof attached") : null,
          ),
      },
      {
        key: "amount",
        label: "Amount",
        align: "right",
        render: (p) => formatMoney(p.amount),
      },
      {
        key: "status",
        label: "Status",
        render: (p) =>
          h(
            "span",
            {},
            badge(...(PAY_STATUS[p.status] ?? [p.status, "neutral"])),
            sub(formatDateTime(p.created_at)),
            p.reject_reason || p.void_reason
              ? sub(p.reject_reason || p.void_reason)
              : null,
          ),
      },
      { key: "actions", label: "Action", align: "center", render: actionsFor },
    ];
    const lists = {
      check: () => state.rows.filter((p) => p.status === "submitted").reverse(),
      verified: () => state.rows.filter((p) => p.status === "verified"),
      closed: () =>
        state.rows.filter((p) => ["rejected", "void"].includes(p.status)),
    };
    const EMPTY = {
      check: [
        "Nothing to check",
        "Payments members send for their bookings appear here.",
      ],
      verified: [
        "No verified payments",
        "Payments you verify are listed here.",
      ],
      closed: ["Nothing here", "Rejected and voided payments are listed here."],
    };

    function draw() {
      tabsHost.replaceChildren(tabs({
        activeId: state.tab,
        tabs: [
          {
            id: "check",
            label: "To check",
            badge: lists.check().length || undefined,
          },
          { id: "verified", label: "Verified" },
          { id: "closed", label: "Rejected and voided" },
        ],
        onChange: (id) => {
          state.tab = id;
          draw();
        },
      }));
      const [title, text] = EMPTY[state.tab];
      body.replaceChildren(dataTable({
        schema: { columns },
        rows: lists[state.tab](),
        state: state.status === "refreshing" ? "ready" : state.status,
        ariaLabel: "Payments",
        onRetry: refresh,
        emptyTitle: title,
        emptyText: text,
      }));
    }

    page.append(
      pageHeader({
        icon: "currency",
        eyebrow: "Admin",
        title: "Payments",
        description:
          "Check the proof members send for their bookings. A payment counts only after you verify it.",
      }),
      tabsHost,
      body,
    );
    refresh();
    return page;
  }

  return { bookingsPage, paymentsPage };
}
