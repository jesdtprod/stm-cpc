// Admin booking pages (PLAN 5.1 to 5.4): the booking queue and calendar, and the payment queue.
// Each action calls one server function (decide_booking, cancel_booking, decide_payment, void_payment) that checks the
// permission, takes an idempotency key (made when the window opens, reused if the click is repeated), changes the state
// and writes the audit row. The buttons shown follow the caller's permissions, but the database decides.
import {
  adminHero,
  attachPagePattern,
  badge,
  button,
  dataTable,
  dateField,
  h,
  icon,
  iconButton,
  openModal,
  pagination,
  searchControl,
  tabs,
  toast,
} from "./ui.js";
import { can } from "./lib/permissions.js";
import { avatarImage, signedAvatarUrls } from "./lib/avatar.js";
import { businessDate, formatDateTime } from "./lib/dates.js";
import { formatMoney } from "./lib/money.js";
import {
  buildSlots,
  manilaDate,
  parseRange,
  timeLabel,
} from "./lib/slot-grid.js";
import { bookingMessage } from "./pages-booking.js";

const PAGE_SIZE = 25;

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
  "requester:members!bookings_requested_by_member_id_fkey(member_no,persons(display_name,avatar_path,mobile,email))";

const who = (m) => m?.persons?.display_name ?? "Member";
const sub = (text) => h("span", { class: "sub" }, text);
const cleanTerm = (t) => t.replace(/[%_,()*]/g, " ").trim().slice(0, 60);
const dayLabel = (day) =>
  new Intl.DateTimeFormat("en-PH", {
    timeZone: "Asia/Manila",
    weekday: "long",
    month: "long",
    day: "numeric",
    year: "numeric",
  }).format(new Date(`${day}T12:00:00+08:00`));

export function createBookingAdminPages({ api, client }) {
  // ---------------------------------------------------------------- shared
  const errorLine = () =>
    h("p", { class: "field-error form-error", role: "alert", hidden: true });
  const showError = (el, message) => {
    el.textContent = message;
    el.hidden = false;
    return false;
  };

  const reasonField = (label, required) => {
    const count = h("output", {
      class: "decision-reason-count",
      id: "act-reason-count",
      for: "act-reason",
    }, "0 / 500");
    return h(
      "div",
      { class: "field" },
      h(
        "div",
        { class: "decision-field-heading" },
        h(
          "label",
          { for: "act-reason" },
          label,
          required ? h("span", { class: "decision-required" }, " *") : null,
        ),
        count,
      ),
      h("textarea", {
        class: "input textarea",
        id: "act-reason",
        name: "reason",
        rows: 4,
        maxlength: 500,
        placeholder: "Provide context or explanation for this decision...",
        required,
        "aria-describedby": "act-reason-help act-reason-count",
        onInput: (event) => {
          count.textContent = `${event.target.value.length} / 500`;
        },
      }),
      h(
        "p",
        { class: "muted decision-reason-help", id: "act-reason-help" },
        required
          ? "At least 3 characters. Maximum 500 characters."
          : "Optional. Maximum 500 characters.",
      ),
    );
  };

  /** A window with an optional reason; the call gets (reason, key). Stays open and shows the message on failure. */
  function actionModal(
    {
      title,
      eyebrow,
      icon: iconName = "check",
      tone,
      verb,
      destructive = false,
      subject = null,
      impactTitle = null,
      note,
      reasonLabel,
      reasonRequired = false,
      run,
      done,
    },
  ) {
    const key = api.newKey();
    const error = errorLine();
    const effectiveTone = tone || (destructive ? "danger" : "info");
    const effectiveIcon = iconName || (destructive ? "alert" : "check");
    return openModal({
      title,
      eyebrow,
      icon: effectiveIcon,
      tone: effectiveTone,
      destructive,
      confirmLabel: verb,
      cancelLabel: "Cancel",
      body: h(
        "div",
        { class: "member-decision" },
        subject
          ? h(
            "div",
            { class: "member-decision-subject" },
            h(
              "span",
              { class: "member-avatar", "aria-hidden": "true" },
              subject.avatar
                ? h("img", { src: subject.avatar, alt: "" })
                : (subject.initials || icon("user", { solid: true })),
            ),
            h(
              "div",
              { class: "member-meta" },
              h(
                "div",
                { class: "member-decision-name" },
                h("strong", { class: "member-name" }, subject.name),
                subject.statusLabel
                  ? badge(subject.statusLabel, subject.statusTone ?? "neutral")
                  : null,
              ),
              h("span", { class: "sub member-subtext" }, subject.subtext),
            ),
            subject.metaValue
              ? h(
                "div",
                { class: "member-decision-role" },
                h("span", { class: "muted" }, subject.metaLabel || "Court"),
                h("span", {}, subject.metaValue),
              )
              : null,
          )
          : null,
        h(
          "div",
          { class: "stack" },
          note
            ? h(
              "div",
              { class: `modal-callout is-${effectiveTone}` },
              h(
                "span",
                { class: "modal-callout-icon", "aria-hidden": "true" },
                icon(effectiveIcon),
              ),
              h(
                "div",
                { class: "modal-callout-text" },
                impactTitle
                  ? h(
                    "strong",
                    { class: "decision-impact-title" },
                    impactTitle,
                  )
                  : null,
                h("p", { class: "decision-impact-text" }, note),
              ),
            )
            : null,
          reasonLabel ? reasonField(reasonLabel, reasonRequired) : null,
        ),
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
    const page = h("div", {
      class: "page admin-dashboard admin-members-page admin-bookings-page",
    });
    const kpis = h("div", { class: "home-grid kpis" });
    const tabsHost = h("div", {});
    const tableHost = h("div", { class: "table-host" });
    const pagerHost = h("div", {});
    const directoryCard = h(
      "div",
      { class: "member-directory-card" },
      tableHost,
      pagerHost,
    );
    const state = {
      tab: "approve",
      term: "",
      page: 1,
      status: "loading",
      loaded: false,
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
    let timer = null;

    const search = searchControl({
      class: "input",
      id: "bookings-search",
      type: "search",
      placeholder: "Search by member, member ID, court, or booking no…",
      "aria-label": "Search bookings",
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

    const toolbar = h(
      "div",
      { class: "toolbar admin-members-toolbar" },
      searchBox,
    );

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
        const allRows = [...state.active, ...state.history];
        const [pays, urls] = await Promise.all([
          totalsFor(allRows.map((b) => b.id)),
          signedAvatarUrls(
            client,
            allRows.map((r) => r.requester?.persons?.avatar_path),
          ),
        ]);
        state.pays = pays;
        for (const r of allRows) {
          r._avatar = urls.get(r.requester?.persons?.avatar_path) ?? null;
        }
        state.loaded = true;
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

    const subjectOf = (r) => {
      const name = who(r.requester);
      const [statusLabel, statusTone] = STATUS[r.status] ?? [
        r.status,
        "neutral",
      ];
      return {
        name,
        initials: initialsOf(name),
        avatar: r._avatar ?? null,
        statusLabel,
        statusTone,
        subtext: `${r.requester?.member_no ?? "—"} · ${r.doc_no}`,
        metaLabel: "Court",
        metaValue: r.court_name_snapshot,
      };
    };

    function actionsFor(r) {
      const x = range(r);
      const approve = can("bookings.approve");
      const front = can("bookings.checkin");
      const cancelAny = can("bookings.cancel_any");
      const label = `${r.doc_no}, ${who(r.requester)}`;
      const b = [
        iconButton({
          label: `View details for ${label}`,
          icon: "info",
          size: "sm",
          variant: "info",
          onClick: () => detailsModal(r),
        }),
      ];
      if (r.status === "pending_approval" && approve) {
        const blocked = payRequired() && Number(r.price_snapshot) > 0 &&
          paid(r) < Number(r.price_snapshot);
        b.push(
          iconButton({
            label: blocked
              ? `Approve ${label} (payment not verified yet)`
              : `Approve ${label}`,
            icon: "check",
            size: "sm",
            variant: "success",
            disabled: blocked,
            onClick: () =>
              actionModal({
                title: "Approve this booking",
                eyebrow: "Booking management",
                icon: "check",
                tone: "success",
                verb: "Approve",
                subject: subjectOf(r),
                impactTitle: "Reservation will be confirmed",
                note: `${r.court_name_snapshot} · ${formatDateTime(x?.start)}.`,
                reasonLabel: "Note (optional)",
                run: decide(r, "approve"),
                done: refresh,
              }),
          }),
          iconButton({
            label: `Reject ${label}`,
            icon: "x",
            size: "sm",
            variant: "danger",
            onClick: () =>
              actionModal({
                title: "Reject this request",
                eyebrow: "Booking management",
                icon: "x",
                tone: "danger",
                verb: "Reject",
                destructive: true,
                subject: subjectOf(r),
                impactTitle: "Request will be declined",
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
              size: "sm",
              variant: "success",
              onClick: () =>
                actionModal({
                  title: "Check in",
                  eyebrow: "Booking management",
                  icon: "check",
                  tone: "success",
                  verb: "Check in",
                  subject: subjectOf(r),
                  impactTitle: "Member arrival confirmed",
                  note: `${r.court_name_snapshot} · ${
                    formatDateTime(x?.start)
                  }.`,
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
            size: "sm",
            variant: "warning",
            onClick: () =>
              actionModal({
                title: "Mark as a no-show",
                eyebrow: "Booking management",
                icon: "alert",
                tone: "warning",
                verb: "Mark no-show",
                destructive: true,
                subject: subjectOf(r),
                impactTitle: "Session will be marked as no-show",
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
          size: "sm",
          variant: "success",
          onClick: () =>
            actionModal({
              title: "Complete this booking",
              eyebrow: "Booking management",
              icon: "check",
              tone: "success",
              verb: "Complete",
              subject: subjectOf(r),
              impactTitle: "Court session will be completed",
              note: `${r.court_name_snapshot} · ${formatDateTime(x?.start)}.`,
              run: decide(r, "complete"),
              done: refresh,
            }),
        }));
      }
      if (["pending_approval", "confirmed"].includes(r.status) && cancelAny) {
        b.push(iconButton({
          label: `Cancel ${label}`,
          icon: "trash",
          size: "sm",
          variant: "danger",
          onClick: () =>
            actionModal({
              title: "Cancel this booking",
              eyebrow: "Booking management",
              icon: "trash",
              tone: "danger",
              verb: "Cancel booking",
              destructive: true,
              subject: subjectOf(r),
              impactTitle: "Booking will be cancelled",
              note:
                "The member is told and no late fee is charged. A confirmed booking's charge is reversed.",
              reasonLabel: "Reason",
              reasonRequired: true,
              run: call("cancel_booking", { p_booking_id: r.id }),
              done: refresh,
            }),
        }));
      }
      return h("div", { class: "row-actions" }, ...b);
    }

    const columns = [
      {
        key: "who",
        label: "Member",
        skeleton: "member",
        render: (r) => {
          const name = who(r.requester);
          return h(
            "div",
            { class: "member-cell" },
            h(
              "span",
              { class: "member-avatar", "aria-hidden": "true" },
              avatarImage(r._avatar, name),
            ),
            h(
              "div",
              { class: "member-meta" },
              h("span", { class: "member-name" }, name),
              h(
                "span",
                { class: "sub member-subtext" },
                `${r.requester?.member_no ?? "—"} · ${r.doc_no}`,
              ),
            ),
          );
        },
      },
      {
        key: "when",
        label: "Court and time",
        skeleton: "stack",
        render: (r) => {
          const x = range(r);
          return h(
            "div",
            { class: "member-table-stack" },
            r.court_name_snapshot,
            sub(x ? `${formatDateTime(x.start)} to ${timeLabel(x.end)}` : "—"),
          );
        },
      },
      {
        key: "status",
        label: "Status",
        skeleton: "badge-stack",
        render: (r) =>
          h(
            "div",
            { class: "member-table-stack" },
            badge(...(STATUS[r.status] ?? [r.status, "neutral"])),
            sub(
              r.status === "pending_approval" && r.expires_at
                ? `Expires ${formatDateTime(r.expires_at)}`
                : (r.cancel_reason ||
                  (["rejected", "no_show", "expired"].includes(r.status)
                    ? r.status_reason
                    : null) ||
                  `Requested ${(r.created_at ?? "").slice(0, 10) || "—"}`),
            ),
          ),
      },
      {
        key: "price",
        label: "Price",
        align: "right",
        kind: "money",
        render: (r) =>
          Number(r.price_snapshot) > 0 ? formatMoney(r.price_snapshot) : "Free",
      },
      {
        key: "pay",
        label: "Payment",
        skeleton: "badge-stack",
        render: (r) => {
          if (!(Number(r.price_snapshot) > 0)) {
            return h(
              "div",
              { class: "member-table-stack" },
              badge("No charge", "neutral"),
              sub("Complimentary"),
            );
          }
          if (paid(r) >= Number(r.price_snapshot)) {
            return h(
              "div",
              { class: "member-table-stack" },
              badge("Paid", "success"),
              sub(`${formatMoney(paid(r))} verified`),
            );
          }
          return h(
            "div",
            { class: "member-table-stack" },
            waiting(r)
              ? badge("Waiting to check", "warning")
              : badge("Not paid", "neutral"),
            sub(
              waiting(r)
                ? `${formatMoney(waiting(r))} to check`
                : paid(r)
                ? `${formatMoney(paid(r))} paid`
                : `${formatMoney(r.price_snapshot)} due`,
            ),
          );
        },
      },
      {
        key: "actions",
        label: "Action",
        align: "center",
        actionCount: 4,
        render: actionsFor,
      },
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

    const matchesSearch = (r, q) => {
      if (!q) return true;
      const needle = q.toLowerCase();
      const hay = [
        who(r.requester),
        r.requester?.member_no,
        r.doc_no,
        r.court_name_snapshot,
        (STATUS[r.status] ?? [r.status])[0],
      ].filter(Boolean).join(" ").toLowerCase();
      return hay.includes(needle);
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
        const bks = bookings ?? [];
        const urls = await signedAvatarUrls(
          client,
          bks.map((r) => r.requester?.persons?.avatar_path),
        );
        for (const r of bks) {
          r._avatar = urls.get(r.requester?.persons?.avatar_path) ?? null;
        }
        Object.assign(cal, {
          courts: courts ?? [],
          hours: hours ?? [],
          bookings: bks,
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
      const isToday = cal.day === today;
      const isLoading = cal.status === "loading" || cal.status === "idle";
      const day = dateField({
        id: "cal-day",
        value: cal.day,
        ariaLabel: "Day",
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

      let freeTotal = 0;
      let bookedTotal = 0;
      let closedTotal = 0;
      const courtEntries = cal.status === "ready"
        ? cal.courts.map((court) => {
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
          for (const s of slots) {
            if (s.state === "booked") bookedTotal += 1;
            else if (s.state === "closed") closedTotal += 1;
            else freeTotal += 1;
          }
          return { court, taken, slots };
        })
        : [];

      const legendPill = (tone, label, count) =>
        h(
          "div",
          { class: `calendar-legend-pill is-${tone}` },
          h("span", { class: "calendar-legend-swatch", "aria-hidden": "true" }),
          h("span", { class: "calendar-legend-label" }, label),
          isLoading
            ? h("span", {
              class: "sk calendar-legend-sk",
              "aria-hidden": "true",
            })
            : h(
              "span",
              { class: "calendar-legend-count" },
              String(count),
            ),
        );

      const bar = h(
        "div",
        { class: "book-day booking-calendar-bar" },
        h(
          "div",
          { class: "booking-calendar-nav" },
          h(
            "div",
            {
              class: "calendar-date-stepper",
              role: "group",
              "aria-label": "Date navigation",
            },
            iconButton({
              label: "Previous day",
              icon: "chevronLeft",
              size: "sm",
              onClick: () => shift(-1),
            }),
            day,
            iconButton({
              label: "Next day",
              icon: "chevronRight",
              size: "sm",
              onClick: () => shift(1),
            }),
          ),
          h(
            "div",
            { class: "calendar-date-heading" },
            h(
              "div",
              { class: "calendar-date-eyebrow-row" },
              h(
                "span",
                {
                  class: `calendar-date-eyebrow${isToday ? " is-today" : ""}`,
                },
                isToday ? "Today's Schedule" : "Selected Schedule",
              ),
              isToday ? null : h(
                "button",
                {
                  type: "button",
                  class: "calendar-today-btn",
                  onClick: () => {
                    cal.day = today;
                    loadCalendar();
                  },
                },
                icon("calendar"),
                h("span", {}, "Jump to Today"),
              ),
            ),
            h("strong", { class: "book-day-label" }, dayLabel(cal.day)),
          ),
        ),
        h(
          "div",
          {
            class: "slot-legend calendar-legend-dock",
            role: "group",
            "aria-label": "Court availability legend",
          },
          legendPill("free", "Free", freeTotal),
          legendPill("booked", "Booked", bookedTotal),
          legendPill("closed", "Closed", closedTotal),
        ),
      );
      if (isLoading) {
        return h(
          "div",
          { class: "booking-calendar-wrap", "aria-busy": "true" },
          bar,
          h(
            "div",
            { class: "booking-calendar-list" },
            ...[1, 2].map(() =>
              h(
                "section",
                { class: "booking-calendar-court is-loading" },
                h(
                  "div",
                  { class: "ladder-head" },
                  h(
                    "div",
                    { class: "sk-meta" },
                    h("span", { class: "sk w-30" }),
                    h("span", { class: "sk w-50 sk-sub" }),
                  ),
                ),
                h(
                  "div",
                  { class: "slots slots-wide" },
                  ...Array.from(
                    { length: 8 },
                    () => h("span", { class: "sk sk-slot-pill" }),
                  ),
                ),
              )
            ),
          ),
        );
      }
      if (cal.status === "error") {
        return h(
          "div",
          { class: "booking-calendar-wrap" },
          bar,
          h(
            "div",
            { class: "tbl-state error", role: "alert" },
            h("span", { class: "badge-icon" }, icon("alert")),
            h("h2", {}, "The calendar could not be loaded"),
            h(
              "p",
              {},
              "Check your connection and try loading the courts again.",
            ),
            button({
              label: "Try again",
              icon: "refresh",
              onClick: loadCalendar,
            }),
          ),
        );
      }
      const cards = courtEntries.map(({ court, taken, slots }) => {
        return h(
          "section",
          { class: "booking-calendar-court", "aria-label": court.name },
          h(
            "div",
            { class: "ladder-head" },
            h(
              "div",
              { class: "member-table-stack" },
              h("h2", { class: "settings-title" }, court.name),
              h(
                "span",
                { class: "sub" },
                slots.length
                  ? `${
                    slots.filter((s) => s.state === "booked").length
                  } booked · ${
                    slots.filter((s) =>
                      s.state === "free" || s.state === "past"
                    ).length
                  } open`
                  : "Closed this day",
              ),
            ),
            court.status === "available"
              ? badge("Available", "success")
              : badge(court.status, "neutral"),
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
        { class: "booking-calendar-wrap" },
        bar,
        cards.length
          ? h("div", { class: "booking-calendar-list" }, ...cards)
          : h(
            "div",
            { class: "tbl-state" },
            h("span", { class: "badge-icon" }, icon("calendar")),
            h("h2", {}, "No courts yet"),
            h("p", {}, "Courts added in the Courts screen appear here."),
          ),
      );
    }

    function detailsModal(r) {
      const x = range(r);
      const p = r.requester?.persons ?? {};
      const kv = (label, value, wide = false) =>
        h(
          "dl",
          { class: `kv-item${wide ? " kv-item-wide" : ""}` },
          h("dt", { class: "kv-label" }, label),
          h("dd", { class: "kv-val" }, value || "—"),
        );

      const statusBadge = badge(...(STATUS[r.status] ?? [r.status, "neutral"]));
      const paymentBadge = !(Number(r.price_snapshot) > 0)
        ? badge("No charge", "neutral")
        : paid(r) >= Number(r.price_snapshot)
        ? badge("Paid", "success")
        : waiting(r) > 0
        ? badge("Waiting to check", "warning")
        : badge("Not paid", "neutral");
      const priceBadge = badge(
        Number(r.price_snapshot) > 0 ? formatMoney(r.price_snapshot) : "Free",
        "neutral",
      );

      return openModal({
        title: who(r.requester),
        eyebrow: `${r.doc_no} · ${r.court_name_snapshot}`,
        icon: "calendar",
        size: "lg",
        tone: "info",
        confirmLabel: "Close",
        cancelLabel: null,
        body: h(
          "div",
          { class: "member-details-modal" },
          h(
            "div",
            { class: "member-banner" },
            h(
              "div",
              { class: "member-summary-item" },
              h("span", { class: "kv-label" }, "Booking status"),
              statusBadge,
            ),
            h(
              "div",
              { class: "member-summary-item" },
              h("span", { class: "kv-label" }, "Payment status"),
              paymentBadge,
            ),
            h(
              "div",
              { class: "member-summary-item" },
              h("span", { class: "kv-label" }, "Court fee"),
              priceBadge,
            ),
          ),
          h(
            "div",
            { class: "member-profile-sections" },
            h(
              "div",
              { class: "member-section-card" },
              h(
                "h3",
                {},
                h(
                  "span",
                  { class: "section-icon", "aria-hidden": "true" },
                  icon("calendar"),
                ),
                "Reservation & Schedule",
              ),
              h(
                "div",
                { class: "member-details-grid" },
                kv("Court", r.court_name_snapshot),
                kv("Booking No.", r.doc_no),
                kv(
                  "Scheduled Time",
                  x ? `${formatDateTime(x.start)} to ${timeLabel(x.end)}` : "—",
                  true,
                ),
                kv(
                  "Requested On",
                  r.created_at ? formatDateTime(r.created_at) : "—",
                ),
                r.expires_at && r.status === "pending_approval"
                  ? kv("Decision Due", formatDateTime(r.expires_at))
                  : null,
              ),
            ),
            h(
              "div",
              { class: "member-section-card" },
              h(
                "h3",
                {},
                h(
                  "span",
                  { class: "section-icon", "aria-hidden": "true" },
                  icon("user"),
                ),
                "Member & Contact",
              ),
              h(
                "div",
                { class: "member-details-grid" },
                kv("Member Name", who(r.requester)),
                kv("Member ID", r.requester?.member_no || "—"),
                kv(
                  "Mobile",
                  p.mobile
                    ? h(
                      "a",
                      { href: `tel:${p.mobile}`, class: "details-link" },
                      p.mobile,
                    )
                    : "—",
                ),
                kv(
                  "Email",
                  p.email
                    ? h(
                      "a",
                      { href: `mailto:${p.email}`, class: "details-link" },
                      p.email,
                    )
                    : "—",
                ),
              ),
            ),
          ),
          h(
            "div",
            { class: "member-section-card" },
            h(
              "h3",
              {},
              h(
                "span",
                { class: "section-icon", "aria-hidden": "true" },
                icon("file"),
              ),
              "Payment & Audit",
            ),
            h(
              "div",
              { class: "member-details-grid" },
              kv(
                "Verified Paid",
                Number(r.price_snapshot) > 0 ? formatMoney(paid(r)) : "Free",
              ),
              kv(
                "Pending Verification",
                waiting(r) > 0 ? formatMoney(waiting(r)) : "None",
              ),
              kv(
                "Reason / Note on Record",
                r.cancel_reason || r.status_reason || "—",
                true,
              ),
            ),
          ),
        ),
        onConfirm: () => {},
      });
    }

    function bookingStatCard({
      label,
      value,
      hint,
      iconName,
      pill,
      isAttention,
      tone = "emerald",
      tabId,
    }) {
      return h(
        "button",
        {
          type: "button",
          class: `home-card member-stat-card is-link is-tone-${tone}${
            isAttention ? " is-attention" : ""
          }`,
          onClick: () => {
            state.tab = tabId;
            state.page = 1;
            draw();
          },
        },
        h(
          "div",
          { class: "member-stat-main" },
          h(
            "span",
            { class: "home-card-icon", "aria-hidden": "true" },
            icon(iconName),
          ),
          h(
            "div",
            { class: "member-stat-copy" },
            h("span", { class: "home-card-value" }, String(value ?? "—")),
            h("span", { class: "home-card-label" }, label),
          ),
          pill,
        ),
        h(
          "div",
          { class: "home-card-bottom" },
          h("div", { class: "home-card-hint" }, hint),
          h(
            "span",
            { class: "home-card-go" },
            tabId === "approve" ? "Review requests" : "View bookings",
            icon("chevronRight"),
          ),
        ),
      );
    }

    // ---------------------------------------------------------------- layout
    function draw() {
      const approveList = lists.approve();
      const todayList = lists.today();
      const upcomingList = lists.upcoming();
      const historyList = lists.history();
      const counts = {
        approve: approveList.length,
        today: todayList.length,
        upcoming: upcomingList.length,
        history: historyList.length,
      };

      const pCount = counts.approve;
      const tCount = counts.today;
      const uCount = counts.upcoming;

      kpis.replaceChildren(
        bookingStatCard({
          label: "Waiting for approval",
          value: state.loaded ? pCount : "—",
          hint: pCount > 0
            ? "Requires administrator review"
            : "Approval queue is clear",
          iconName: "clock",
          isAttention: pCount > 0,
          tone: "amber",
          tabId: "approve",
          pill: pCount > 0
            ? h(
              "span",
              { class: "card-status-pill is-attention" },
              h("span", { class: "pill-pulse-dot", "aria-hidden": "true" }),
              "Needs review",
            )
            : h(
              "span",
              { class: "card-status-pill is-clean" },
              icon("check"),
              "All clear",
            ),
        }),
        bookingStatCard({
          label: "Bookings today",
          value: state.loaded ? tCount : "—",
          hint: `${tCount} court session${
            tCount === 1 ? "" : "s"
          } scheduled today`,
          iconName: "calendar",
          isAttention: false,
          tone: "emerald",
          tabId: "today",
          pill: h(
            "span",
            { class: "card-status-pill is-clean" },
            icon("check"),
            "Today",
          ),
        }),
        bookingStatCard({
          label: "Upcoming bookings",
          value: state.loaded ? uCount : "—",
          hint: `${uCount} confirmed session${
            uCount === 1 ? "" : "s"
          } after today`,
          iconName: "check",
          isAttention: false,
          tone: "teal",
          tabId: "upcoming",
          pill: h(
            "span",
            { class: "card-status-pill is-clean" },
            icon("check"),
            "Confirmed",
          ),
        }),
      );

      tabsHost.replaceChildren(tabs({
        activeId: state.tab,
        tabs: [
          {
            id: "approve",
            label: "Waiting for approval",
            badge: counts.approve ? String(counts.approve) : undefined,
          },
          {
            id: "today",
            label: "Today",
            badge: counts.today ? String(counts.today) : undefined,
          },
          {
            id: "upcoming",
            label: "Upcoming",
            badge: counts.upcoming ? String(counts.upcoming) : undefined,
          },
          { id: "calendar", label: "Calendar" },
          {
            id: "history",
            label: "History",
            badge: counts.history ? String(counts.history) : undefined,
          },
        ],
        onChange: (id) => {
          state.tab = id;
          state.page = 1;
          if (id === "calendar" && state.calendar.status === "idle") {
            loadCalendar();
          } else draw();
        },
      }));

      if (state.tab === "calendar") {
        toolbar.hidden = true;
        tableHost.replaceChildren(calendarView());
        pagerHost.replaceChildren();
        return;
      }

      toolbar.hidden = false;
      const term = cleanTerm(state.term);
      const filtered = lists[state.tab]().filter((r) => matchesSearch(r, term));
      const total = filtered.length;
      const maxPage = Math.max(1, Math.ceil(total / PAGE_SIZE));
      if (state.page > maxPage) state.page = maxPage;
      const pageRows = filtered.slice(
        (state.page - 1) * PAGE_SIZE,
        state.page * PAGE_SIZE,
      );

      let [emptyTitle, emptyText] = EMPTY[state.tab];
      if (term) {
        emptyTitle = `No bookings match "${term}"`;
        emptyText =
          "Try a different member name, member ID, court, or booking number, or clear your search.";
      }

      const tableState = state.status === "refreshing" ? "ready" : state.status;
      tableHost.replaceChildren(dataTable({
        schema: { columns },
        rows: pageRows,
        state: tableState,
        hasFilters: Boolean(term),
        ariaLabel: "Bookings",
        onRetry: refresh,
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
        tableState === "ready"
          ? pagination({
            page: state.page,
            pageSize: PAGE_SIZE,
            total,
            onPage: (p) => {
              state.page = p;
              draw();
            },
          })
          : "",
      );
    }

    const manilaDateText = new Intl.DateTimeFormat("en-PH", {
      timeZone: "Asia/Manila",
      weekday: "short",
      month: "short",
      day: "numeric",
      year: "numeric",
    }).format(new Date());

    const hero = h(
      "section",
      {
        class: "dash-hero is-admin",
        "aria-label": "Court Bookings",
      },
      h(
        "div",
        { class: "dash-hero-copy" },
        h(
          "div",
          { class: "dash-hero-chips" },
          h(
            "span",
            { class: "dash-chip is-role" },
            icon("medal"),
            "Admin Console",
          ),
          h(
            "span",
            { class: "dash-chip is-date" },
            icon("calendar"),
            manilaDateText,
          ),
          h(
            "span",
            { class: "dash-chip is-status" },
            h("span", { class: "status-dot-pulse", "aria-hidden": "true" }),
            "Bookings Management",
          ),
        ),
        h(
          "h1",
          { class: "dash-hero-title", id: "page-title", tabindex: "-1" },
          "Court Bookings",
        ),
        h(
          "p",
          { class: "dash-hero-sub" },
          "Approve court requests, check members in, and see the day's courts. All times are Asia/Manila.",
        ),
      ),
      h(
        "div",
        { class: "dash-hero-actions" },
        button({
          label: "Refresh List",
          icon: "refresh",
          variant: "secondary",
          onClick: () => {
            if (state.tab === "calendar") loadCalendar();
            refresh();
          },
        }),
      ),
    );

    page.append(
      hero,
      kpis,
      tabsHost,
      toolbar,
      directoryCard,
    );
    refresh();
    return page;
  }

  // =============================================================== payments
  function paymentsPage() {
    const page = h("div", {
      class: "page admin-dashboard admin-members-page admin-payments-page",
    });
    attachPagePattern(page);
    const tabsHost = h("div", {});
    const body = h("div", { class: "table-host" });
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
            size: "sm",
            variant: "info",
            onClick: () => viewProof(p),
          }),
        );
      }
      if (p.status === "submitted" && can("payments.verify")) {
        b.push(
          iconButton({
            label: `Verify ${label}`,
            icon: "check",
            size: "sm",
            variant: "success",
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
            size: "sm",
            variant: "danger",
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
          size: "sm",
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
      adminHero({
        title: "Payments",
        chip: "Payments Management",
        description:
          "Check the proof members send for their bookings. A payment counts only after you verify it.",
        actions: [
          button({
            label: "Refresh List",
            icon: "refresh",
            variant: "secondary",
            onClick: refresh,
          }),
        ],
      }),
      tabsHost,
      h("div", { class: "member-directory-card" }, body),
    );
    refresh();
    return page;
  }

  return { bookingsPage, paymentsPage };
}
