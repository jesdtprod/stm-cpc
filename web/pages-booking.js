// Member booking pages (PLAN 5.1, 5.2, 5.4): book a court, and follow, pay for and cancel your bookings.
//   * The page only draws what the server allows. Every rule (opening hours, the booking window, players, the price, a
//     slot someone else just took) is checked again by request_booking, and its messages are shown as they are.
//   * The booking ID is made when the form opens and reused if the request is sent again; a changed request gets a new ID.
//   * Payment proof goes to the private bucket under the member's own folder, then submit_payment records it. Nothing is
//     paid until an admin verifies it.
import {
  attachPagePattern,
  badge,
  button,
  dataTable,
  dateField,
  h,
  icon,
  iconButton,
  memberHero,
  openModal,
  searchControl,
  selectControl,
  tableFilter,
  toast,
} from "./ui.js";
import { businessDate, formatDateTime } from "./lib/dates.js";
import { formatMoney } from "./lib/money.js";
import {
  buildSlots,
  freeRun,
  manilaDate,
  parseRange,
  timeLabel,
} from "./lib/slot-grid.js";
import { ulid } from "./lib/ulid.js";

const MAX_PROOF_BYTES = 5 * 1024 * 1024;
const PROOF_TYPES = [
  "image/jpeg",
  "image/png",
  "image/webp",
  "application/pdf",
];
const METHOD_LABEL = {
  cash: "Cash",
  gcash: "GCash",
  maya: "Maya",
  bank_transfer: "Bank Transfer",
};
const STATUS = {
  pending_approval: ["Waiting for Approval", "warning"],
  confirmed: ["Confirmed", "success"],
  checked_in: ["Checked In", "info"],
  completed: ["Completed", "neutral"],
  rejected: ["Rejected", "danger"],
  cancelled: ["Cancelled", "neutral"],
  no_show: ["No-show", "danger"],
  expired: ["Expired", "neutral"],
};

/** The database's own messages are written for people; anything else gets a plain fallback. */
export function bookingMessage(
  e,
  fallback = "That did not work. Please try again.",
) {
  if (e?.code === "23P01") {
    return "That time was just taken. Pick another slot.";
  }
  const own = ["22023", "42501", "23503", "23505", "CP422", "CP409"].includes(
    e?.code,
  ) && e.cause?.message;
  return own || e?.message || fallback;
}

const addDays = (day, n) => {
  const d = new Date(`${day}T12:00:00+08:00`);
  d.setUTCDate(d.getUTCDate() + n);
  return businessDate(d);
};
const dayLabel = (day) =>
  new Intl.DateTimeFormat("en-PH", {
    timeZone: "Asia/Manila",
    weekday: "long",
    month: "long",
    day: "numeric",
    year: "numeric",
  }).format(new Date(`${day}T12:00:00+08:00`));

export function createBookingPages({ api, client, session }) {
  const profile = () => session.getState().profile ?? {};

  async function loadSettings(keys) {
    const rows = await api.read((c) =>
      c.from("settings").select("key,value").in("key", keys).is("unit_id", null)
        .is("deleted_at", null)
    );
    return Object.fromEntries((rows ?? []).map((r) => [r.key, r.value]));
  }

  // ===================================================================== book
  function bookPage() {
    const page = h("div", { class: "page book-page" });
    attachPagePattern(page);
    const body = h("div", { class: "member-directory-card" });
    const state = {
      day: businessDate(),
      courts: [],
      hours: [],
      taken: [],
      slotMinutes: 60,
      advanceDays: 14,
      maxPlayers: 4,
      status: "loading",
    };
    // One ID per distinct request, so sending the same request again is not a second booking.
    const ids = new Map();
    const idFor = (signature) => {
      if (!ids.has(signature)) ids.set(signature, api.newKey());
      return ids.get(signature);
    };

    async function load() {
      state.status = state.courts.length ? "refreshing" : "loading";
      draw();
      try {
        const from = manilaDate(state.day, "00:00");
        const to = new Date(from.getTime() + 24 * 3600_000);
        const [settings, courts, hours, taken] = await Promise.all([
          loadSettings([
            "booking.slot_minutes",
            "booking.advance_days",
            "booking.max_participants",
          ]),
          api.read((c) =>
            c.from("courts").select(
              "id,code,name,status,indoor,surface,sort_order",
            )
              .is("deleted_at", null).eq("status", "available").order(
                "sort_order",
              )
              .order("name")
          ),
          api.read((c) =>
            c.from("court_hours").select(
              "court_id,weekday,opens_at,closes_at,valid_from,valid_to",
            )
              .is("deleted_at", null)
          ),
          api.rpc("court_availability", {
            p_from: from.toISOString(),
            p_to: to.toISOString(),
          }),
        ]);
        state.slotMinutes = Number(settings["booking.slot_minutes"]) || 60;
        state.advanceDays = Number(settings["booking.advance_days"]) || 14;
        state.maxPlayers = Number(settings["booking.max_participants"]) || 4;
        state.courts = courts ?? [];
        state.hours = hours ?? [];
        state.taken = (taken ?? []).map((t) => {
          const r = parseRange(t.during);
          return r &&
            { court_id: t.court_id, start: r.start, end: r.end, kind: t.kind };
        }).filter(Boolean);
        state.status = "ready";
      } catch (e) {
        state.status = "error";
        state.error = bookingMessage(e, "The courts could not be loaded.");
      }
      draw();
    }

    function slotsFor(court) {
      return buildSlots({
        day: state.day,
        courtId: court.id,
        hours: state.hours,
        slotMinutes: state.slotMinutes,
        taken: state.taken.filter((t) =>
          t.court_id == null || t.court_id === court.id
        ),
        advanceDays: state.advanceDays,
      });
    }

    // ------------------------------------------------------------- request
    function requestModal(court, slots, index) {
      const first = slots[index];
      const maxBookingMinutes = 120; // max 2 hours only
      const maxSlots = Math.floor(maxBookingMinutes / state.slotMinutes);
      const runLimit = Math.min(
        freeRun(slots, index, maxSlots),
        maxSlots,
      );
      const players = new Map(); // member_id -> { member_no, display_name }
      const error = h("p", {
        class: "field-error form-error",
        role: "alert",
        hidden: true,
      });

      const subjectCard = h(
        "div",
        { class: "member-decision-subject" },
        h(
          "span",
          { class: "member-avatar is-icon", "aria-hidden": "true" },
          icon("grid", { solid: true }),
        ),
        h(
          "div",
          { class: "member-meta" },
          h(
            "div",
            { class: "member-decision-name" },
            h("strong", { class: "member-name" }, court.name),
            badge("Available", "success"),
          ),
          h(
            "span",
            { class: "sub member-subtext" },
            [court.indoor ? "Indoor" : "Outdoor", court.surface].filter(Boolean)
              .join(" · "),
          ),
        ),
        h(
          "div",
          { class: "member-decision-role" },
          h("span", { class: "muted" }, "Session"),
          h("span", {}, `${dayLabel(state.day)} · ${timeLabel(first.start)}`),
        ),
      );

      const quoteIcon = h(
        "span",
        { class: "modal-callout-icon", "aria-hidden": "true" },
        icon("clock"),
      );
      const quoteTitle = h(
        "strong",
        { class: "quote-callout-title" },
        "Checking price…",
      );
      const quoteBody = h(
        "span",
        { class: "quote-callout-body" },
        "Calculating court fees and reservation rules.",
      );
      const quoteCallout = h(
        "div",
        { class: "modal-callout is-success quote-callout", role: "status" },
        quoteIcon,
        h("div", { class: "modal-callout-text" }, quoteTitle, quoteBody),
      );

      const minutesSel = selectControl(
        { class: "input select-input", id: "bk-len", name: "minutes" },
        ...Array.from({ length: runLimit }, (_, i) => {
          const m = (i + 1) * state.slotMinutes;
          const end = new Date(first.start.getTime() + m * 60_000);
          return h(
            "option",
            { value: m },
            `${
              m / 60 >= 1 && m % 60 === 0
                ? `${m / 60} hour${m === 60 ? "" : "s"}`
                : `${m} minutes`
            } (until ${timeLabel(end)})`,
          );
        }),
      );

      const durationField = h(
        "div",
        { class: "field" },
        h(
          "div",
          { class: "decision-field-heading" },
          h("label", { for: "bk-len" }, "How Long"),
          h("span", { class: "field-hint" }, "Max 2 hours per session"),
        ),
        minutesSel,
      );

      const chosen = h("ul", {
        class: "booking-roster",
        "aria-label": "Players on this booking",
      });
      const results = h("div", {
        class: "staff-results",
        role: "group",
        "aria-label": "Search Results",
      });
      const term = searchControl({
        class: "input",
        id: "bk-term",
        type: "search",
        placeholder: "Name or member ID",
        autocomplete: "off",
      });
      const playerCounter = h(
        "span",
        { class: "card-status-pill is-clean" },
        `1 of ${state.maxPlayers} players`,
      );
      const summary = h("p", { class: "muted", role: "status", hidden: true });

      const minutes = () => Number(minutesSel.value);
      const signature = () =>
        [
          court.id,
          first.start.toISOString(),
          minutes(),
          [...players.keys()].sort().join(","),
        ].join("|");

      async function refreshQuote() {
        quoteCallout.className = "modal-callout is-success quote-callout";
        quoteIcon.replaceChildren(icon("clock"));
        quoteTitle.textContent = "Checking price…";
        quoteBody.textContent = "Calculating court fees and reservation rules.";
        try {
          const q = await api.rpc("quote_booking", {
            p_court_id: court.id,
            p_starts_at: first.start.toISOString(),
            p_minutes: minutes(),
          });
          if (!q.ok) {
            quoteCallout.className = "modal-callout is-danger quote-callout";
            quoteIcon.replaceChildren(icon("alert"));
            quoteTitle.textContent = "Cannot Book Slot";
            quoteBody.textContent = q.problem ||
              "This court slot cannot be requested.";
            return;
          }
          const price = Number(q.price);
          const priceText = price > 0
            ? `Fee: ${formatMoney(price)}`
            : "Free · No Charge";
          const policyText = `${
            q.approval_required
              ? "An admin approves requests."
              : "Confirmed straight away."
          }${
            q.payment_required && price > 0
              ? " Payment must be verified first."
              : ""
          }`;
          quoteCallout.className = price > 0
            ? "modal-callout is-warning quote-callout"
            : "modal-callout is-success quote-callout";
          quoteIcon.replaceChildren(icon(price > 0 ? "currency" : "check"));
          quoteTitle.textContent = priceText;
          quoteBody.textContent = policyText;
        } catch (e) {
          quoteCallout.className = "modal-callout is-danger quote-callout";
          quoteIcon.replaceChildren(icon("alert"));
          quoteTitle.textContent = "Price Check Failed";
          quoteBody.textContent = bookingMessage(
            e,
            "The price could not be checked.",
          );
        }
      }

      function drawChosen() {
        const rosterRow = (n, body, extra = null, cls = "") =>
          h(
            "li",
            { class: `booking-roster-row${cls}` },
            h("span", { class: "booking-roster-no", "aria-hidden": "true" }, n),
            body,
            extra,
          );
        const rows = [
          rosterRow(
            "1",
            h(
              "span",
              { class: "booking-roster-name" },
              h("strong", {}, "You"),
              h("span", { class: "sub" }, "Booking organiser"),
            ),
          ),
        ];
        const added = [...players];
        for (let i = 0; i < state.maxPlayers - 1; i++) {
          const found = added[i];
          if (!found) {
            rows.push(
              rosterRow(
                String(i + 2),
                h(
                  "span",
                  { class: "booking-roster-name" },
                  h("span", { class: "muted" }, "Open spot"),
                ),
                null,
                " is-open",
              ),
            );
            continue;
          }
          const [id, p] = found;
          rows.push(
            rosterRow(
              String(i + 2),
              h(
                "span",
                { class: "booking-roster-name" },
                h("strong", {}, p.display_name),
                p.member_no ? h("span", { class: "sub" }, p.member_no) : null,
              ),
              h("button", {
                type: "button",
                class: "chip-x",
                "aria-label": `Remove ${p.display_name}`,
                onClick: () => {
                  players.delete(id);
                  drawChosen();
                },
              }, "×"),
            ),
          );
        }
        chosen.replaceChildren(...rows);
        playerCounter.textContent = `${
          players.size + 1
        } of ${state.maxPlayers} players`;
      }

      async function search() {
        const text = term.value.trim();
        if (text.length < 2) {
          summary.textContent = "Type at least 2 letters or numbers.";
          summary.hidden = false;
          return;
        }
        summary.hidden = true;
        try {
          const rows = await api.rpc("find_players", { p_term: text });
          const candidates = (rows ?? []).filter((r) =>
            !players.has(r.member_id)
          );
          results.replaceChildren(
            ...candidates.map((r) =>
              h(
                "button",
                {
                  type: "button",
                  class: "player-result",
                  onClick: () => {
                    if (players.size + 1 >= state.maxPlayers) {
                      summary.textContent =
                        `At most ${state.maxPlayers} players allowed.`;
                      summary.hidden = false;
                      return;
                    }
                    players.set(r.member_id, r);
                    results.replaceChildren();
                    term.value = "";
                    drawChosen();
                  },
                },
                h(
                  "div",
                  { class: "member-cell" },
                  h(
                    "span",
                    { class: "member-avatar is-icon", "aria-hidden": "true" },
                    icon("user"),
                  ),
                  h(
                    "div",
                    { class: "member-meta" },
                    h("span", { class: "member-name" }, r.display_name),
                    h("span", { class: "sub member-subtext" }, r.member_no),
                  ),
                ),
                h(
                  "span",
                  { class: "player-result-action" },
                  icon("plus"),
                  "Add",
                ),
              )
            ),
          );
          if (!candidates.length) {
            summary.textContent = "Nobody active matches.";
            summary.hidden = false;
          }
        } catch (e) {
          summary.textContent = bookingMessage(e, "The search did not work.");
          summary.hidden = false;
        }
      }

      term.addEventListener("keydown", (e) => {
        if (e.key === "Enter") {
          e.preventDefault();
          search();
        }
      });
      minutesSel.addEventListener("change", refreshQuote);
      drawChosen();
      refreshQuote();
      return openModal({
        title: "Request Court",
        eyebrow: court.name.toUpperCase(),
        icon: "calendar",
        tone: "success",
        confirmLabel: "Send Request",
        body: h(
          "div",
          { class: "member-decision court-booking-dialog" },
          subjectCard,
          h(
            "div",
            { class: "stack" },
            durationField,
            quoteCallout,
            h(
              "div",
              { class: "field booking-players" },
              h(
                "div",
                { class: "decision-field-heading" },
                h("span", { class: "field-label" }, "Players"),
                playerCounter,
              ),
              chosen,
              h(
                "label",
                { for: "bk-term", class: "field-hint booking-players-hint" },
                `Add up to ${
                  state.maxPlayers - 1
                } more players by name or member ID (optional).`,
              ),
              h(
                "div",
                { class: "staff-search" },
                term,
                button({ label: "Search", icon: "search", onClick: search }),
              ),
              results,
              summary,
            ),
            error,
          ),
        ),
        onConfirm: async () => {
          try {
            const r = await api.rpc("request_booking", {
              p_id: idFor(signature()),
              p_court_id: court.id,
              p_starts_at: first.start.toISOString(),
              p_minutes: minutes(),
              p_participants: [...players.keys()],
            });
            toast(
              r.status === "confirmed"
                ? `Booked: ${r.doc_no}.`
                : `Request sent: ${r.doc_no}. You will see the decision in My Bookings.`,
              { tone: "success" },
            );
            await load();
          } catch (e) {
            error.textContent = bookingMessage(e);
            error.hidden = false;
            if (e?.code === "23P01") await load();
            return false;
          }
        },
      });
    }

    // ---------------------------------------------------------------- layout
    function courtCard(court) {
      const slots = slotsFor(court);
      const bookedCount = slots.filter((s) => s.state === "booked").length;
      const openCount = slots.filter((s) => s.state === "free").length;
      const surfaceText = [
        court.indoor ? "Indoor" : "Outdoor",
        court.surface,
      ].filter(Boolean).join(", ");
      return h(
        "section",
        { class: "booking-calendar-court", "aria-label": court.name },
        h(
          "div",
          { class: "booking-calendar-court-head" },
          h(
            "div",
            { class: "member-cell booking-court-id" },
            h(
              "span",
              { class: "member-avatar is-icon", "aria-hidden": "true" },
              icon("grid", { solid: true }),
            ),
            h(
              "div",
              { class: "member-meta" },
              h(
                "div",
                { class: "booking-court-titlerow" },
                h("h2", { class: "settings-title" }, court.name),
                court.status === "available"
                  ? badge("Available", "success")
                  : (court.status === "maintenance"
                    ? badge("Maintenance", "warning")
                    : badge(court.status || "Closed", "neutral")),
              ),
              h(
                "span",
                { class: "sub" },
                slots.length
                  ? `${
                    surfaceText ? `${surfaceText} · ` : ""
                  }${openCount} free · ${bookedCount} taken`
                  : (surfaceText || "Closed this day"),
              ),
            ),
          ),
        ),
        slots.length
          ? h(
            "div",
            { class: "slots slots-wide" },
            ...slots.map((s, i) => {
              const free = s.state === "free";
              const text = timeLabel(s.start);
              return h(
                "button",
                {
                  type: "button",
                  class: `slot slot-${s.state}`,
                  disabled: !free,
                  "aria-label": `${text}, ${
                    {
                      free: "free",
                      booked: "taken",
                      closed: "closed",
                      past: "passed",
                      far: "not open for booking yet",
                    }[s.state] ?? s.state
                  }`,
                  onClick: () => requestModal(court, slots, i),
                },
                h("span", {}, text),
              );
            }),
          )
          : h(
            "div",
            { class: "booking-calendar-closed" },
            h(
              "span",
              {
                class: "booking-calendar-closed-icon",
                "aria-hidden": "true",
              },
              icon("clock"),
            ),
            h("span", { class: "muted" }, "Closed this day."),
          ),
      );
    }

    function draw() {
      const today = businessDate();
      const last = addDays(today, state.advanceDays);
      const isToday = state.day === today;
      const isLoading = state.status === "loading";

      const day = dateField({
        id: "book-date",
        min: today,
        max: last,
        value: state.day,
        ariaLabel: "Day",
        onChange: (e) => {
          if (e.target.value >= today && e.target.value <= last) {
            state.day = e.target.value;
            load();
          }
        },
      });

      const shift = (n) => {
        const next = addDays(state.day, n);
        if (next >= today && next <= last) {
          state.day = next;
          load();
        }
      };

      let freeTotal = 0;
      let bookedTotal = 0;
      let closedTotal = 0;
      if (state.status === "ready" || state.status === "refreshing") {
        for (const c of state.courts) {
          const slots = slotsFor(c);
          if (!slots.length) {
            closedTotal += 1;
          } else {
            for (const s of slots) {
              if (s.state === "booked") bookedTotal += 1;
              else if (s.state === "free") freeTotal += 1;
              else closedTotal += 1;
            }
          }
        }
      }

      const legendPill = (tone, label, count) =>
        h(
          "span",
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
            { class: "calendar-date-tools" },
            h(
              "div",
              {
                class: "calendar-date-stepper",
                role: "group",
                "aria-label": "Date Navigation",
              },
              iconButton({
                label: "Previous Day",
                icon: "chevronLeft",
                size: "sm",
                disabled: state.day <= today,
                onClick: () => shift(-1),
              }),
              day,
              iconButton({
                label: "Next Day",
                icon: "chevronRight",
                size: "sm",
                disabled: state.day >= last,
                onClick: () => shift(1),
              }),
            ),
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
                    state.day = today;
                    load();
                  },
                },
                icon("calendar"),
                h("span", {}, "Jump to Today"),
              ),
            ),
            h("strong", { class: "book-day-label" }, dayLabel(state.day)),
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
          legendPill("booked", "Taken", bookedTotal),
          legendPill("closed", "Closed", closedTotal),
        ),
      );

      if (isLoading) {
        body.replaceChildren(
          h(
            "div",
            { class: "booking-calendar-wrap", "aria-busy": "true" },
            bar,
            h(
              "div",
              { class: "booking-calendar-list" },
              ...[1, 2, 3, 4, 5, 6].map(() =>
                h(
                  "section",
                  { class: "booking-calendar-court is-loading" },
                  h(
                    "div",
                    { class: "booking-calendar-court-head" },
                    h(
                      "div",
                      { class: "sk-member-cell" },
                      h("span", { class: "sk sk-avatar round" }),
                      h(
                        "div",
                        { class: "sk-meta" },
                        h("span", { class: "sk w-50" }),
                        h("span", { class: "sk w-70 sk-sub" }),
                      ),
                    ),
                    h("span", { class: "sk sk-pill" }),
                  ),
                  h(
                    "div",
                    { class: "slots slots-wide" },
                    ...Array.from(
                      { length: 4 },
                      () => h("span", { class: "sk sk-slot-pill" }),
                    ),
                  ),
                )
              ),
            ),
          ),
        );
        return;
      }

      if (state.status === "error") {
        body.replaceChildren(
          h(
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
                state.error ||
                  "Check your connection and try loading the courts again.",
              ),
              button({
                label: "Try Again",
                icon: "refresh",
                onClick: load,
              }),
            ),
          ),
        );
        return;
      }

      body.replaceChildren(
        h(
          "div",
          { class: "booking-calendar-wrap" },
          bar,
          state.courts.length
            ? h(
              "div",
              { class: "booking-calendar-list" },
              ...state.courts.map(courtCard),
            )
            : h(
              "div",
              { class: "tbl-state" },
              h("span", { class: "badge-icon" }, icon("calendar")),
              h("h2", {}, "No courts yet"),
              h("p", {}, "No courts are open for booking yet."),
            ),
        ),
      );
    }

    page.append(
      memberHero({
        eyebrow: "Play",
        title: "Book a Court",
        chip: "Court Availability",
        iconName: "calendar",
        description:
          "Pick a day, then a free time. The club may need to approve your request.",
      }),
      body,
    );
    load();
    return page;
  }

  // ============================================================== my bookings
  function myBookingsPage() {
    const page = h("div", { class: "page" });
    const tabsHost = h("div", { class: "member-status-filter" });
    const tableHost = h("div", { class: "card" });
    const state = {
      tab: "upcoming",
      rows: [],
      pays: {},
      status: "loading",
      settings: {},
    };

    async function load() {
      state.status = state.rows.length ? "refreshing" : "loading";
      draw();
      try {
        const [rows, settings] = await Promise.all([
          api.read((c) =>
            c.from("bookings").select(
              "id,doc_no,court_name_snapshot,during,status,status_reason,cancel_reason,price_snapshot,expires_at,requested_by_member_id",
            ).order("created_at", { ascending: false }).limit(100)
          ),
          loadSettings([
            "payments.methods",
            "payments.required.court_booking",
            "payments.proof_required_non_cash",
            "payments.instructions",
            "booking.cancel_cutoff_hours",
            "booking.cancel_fee",
          ]),
        ]);
        state.rows = rows ?? [];
        state.settings = settings;
        const ids = state.rows.map((r) => r.id);
        const totals = ids.length
          ? await api.read((c) =>
            c.from("source_payment_totals").select(
              "source_id,verified_total,pending_total",
            ).eq("source_type", "booking").in("source_id", ids)
          )
          : [];
        state.pays = Object.fromEntries(
          (totals ?? []).map((t) => [t.source_id, t]),
        );
        state.status = "ready";
      } catch {
        state.status = "error";
      }
      draw();
    }

    const range = (r) => parseRange(r.during);
    const isUpcoming = (r) => {
      const x = range(r);
      return ["pending_approval", "confirmed", "checked_in"].includes(
        r.status,
      ) && x && x.end.getTime() > Date.now();
    };
    const remaining = (r) => {
      const t = state.pays[r.id];
      return Math.max(
        Number(r.price_snapshot) - Number(t?.verified_total ?? 0) -
          Number(t?.pending_total ?? 0),
        0,
      );
    };

    function cancelModal(r) {
      const key = api.newKey();
      const error = h("p", {
        class: "field-error form-error",
        role: "alert",
        hidden: true,
      });
      const x = range(r);
      const cutoff = Number(
        state.settings["booking.cancel_cutoff_hours"] ?? 24,
      );
      const fee = Number(state.settings["booking.cancel_fee"] ?? 0);
      const late = r.status === "confirmed" && x &&
        x.start.getTime() - Date.now() < cutoff * 3600_000 && fee > 0;
      return openModal({
        title: "Cancel This Booking",
        eyebrow: `${r.court_name_snapshot} · ${formatDateTime(x?.start)}`,
        icon: "alert",
        destructive: true,
        confirmLabel: "Cancel Booking",
        cancelLabel: "Keep It",
        body: h(
          "div",
          { class: "stack" },
          late
            ? h(
              "p",
              { class: "field-error" },
              `Cancelling less than ${cutoff} hours ahead costs a late fee of ${
                formatMoney(fee)
              }.`,
            )
            : h("p", {}, "The time is released for other members."),
          h(
            "div",
            { class: "field" },
            h("label", { for: "cx-reason" }, "Reason (optional)"),
            h("textarea", {
              class: "input textarea",
              id: "cx-reason",
              name: "reason",
              rows: 2,
              maxlength: 500,
            }),
          ),
          error,
        ),
        onConfirm: async (form) => {
          try {
            await api.rpc("cancel_booking", {
              p_booking_id: r.id,
              p_reason: String(form.get("reason") ?? "").trim() || null,
              p_key: key,
            });
            toast("Booking cancelled.", { tone: "success" });
            await load();
          } catch (e) {
            error.textContent = bookingMessage(e);
            error.hidden = false;
            return false;
          }
        },
      });
    }

    function payModal(r) {
      const methods = state.settings["payments.methods"] ?? ["cash"];
      const proofRequired =
        state.settings["payments.proof_required_non_cash"] !== false;
      const paymentId = api.newKey(); // reused if Send is pressed again for the same payment
      const error = h("p", {
        class: "field-error form-error",
        role: "alert",
        hidden: true,
      });
      const instructions = String(state.settings["payments.instructions"] ?? "")
        .trim();
      const proof = h("input", {
        class: "input",
        id: "pay-proof",
        name: "proof",
        type: "file",
        accept: PROOF_TYPES.join(","),
      });
      let uploaded = null; // { file, path }: one upload per file, reused on retry
      return openModal({
        title: "Pay for This Booking",
        eyebrow: `${r.court_name_snapshot} · ${r.doc_no}`,
        icon: "currency",
        confirmLabel: "Send Payment",
        body: h(
          "div",
          { class: "stack" },
          instructions ? h("p", { class: "card" }, instructions) : null,
          h(
            "p",
            { class: "muted" },
            `Still to pay: ${
              formatMoney(remaining(r))
            }. An admin checks your payment before it counts.`,
          ),
          h(
            "div",
            { class: "field" },
            h("label", { for: "pay-method" }, "Method *"),
            selectControl(
              { class: "input select-input", id: "pay-method", name: "method" },
              ...methods.map((m) =>
                h("option", { value: m }, METHOD_LABEL[m] ?? m)
              ),
            ),
          ),
          h(
            "div",
            { class: "field" },
            h("label", { for: "pay-ref" }, "Reference Number"),
            h("input", {
              class: "input",
              id: "pay-ref",
              name: "reference",
              maxlength: 64,
            }),
          ),
          h(
            "div",
            { class: "field" },
            h("label", { for: "pay-amount" }, "Amount (PHP) *"),
            h("input", {
              class: "input",
              id: "pay-amount",
              name: "amount",
              type: "number",
              min: "0.01",
              step: "0.01",
              required: true,
              value: remaining(r).toFixed(2),
            }),
          ),
          h(
            "div",
            { class: "field" },
            h(
              "label",
              { for: "pay-proof" },
              proofRequired
                ? "Proof of payment (cash needs none)"
                : "Proof of payment (optional)",
            ),
            proof,
            h("span", { class: "field-hint" }, "A photo or PDF, up to 5 MB."),
          ),
          error,
        ),
        onConfirm: async (form) => {
          const fail = (m) => {
            error.textContent = m;
            error.hidden = false;
            return false;
          };
          const method = String(form.get("method"));
          const amount = Number(form.get("amount"));
          if (!(amount > 0) || Math.round(amount * 100) !== amount * 100) {
            return fail(
              "Enter an amount above zero with at most two decimals.",
            );
          }
          const file = proof.files?.[0] ?? null;
          if (
            file &&
            (!PROOF_TYPES.includes(file.type) || file.size > MAX_PROOF_BYTES)
          ) {
            return fail(
              "The proof must be a JPG, PNG, WebP or PDF file up to 5 MB.",
            );
          }
          if (!file && method !== "cash" && proofRequired) {
            return fail("Attach the proof of payment.");
          }
          try {
            let path = null;
            if (file) {
              if (!uploaded || uploaded.file !== file) {
                const ext = {
                  "image/jpeg": "jpg",
                  "image/png": "png",
                  "image/webp": "webp",
                  "application/pdf": "pdf",
                }[file.type];
                const candidate =
                  `${profile().org_id}/${profile().profile_id}/${ulid()}.${ext}`;
                const { error: upErr } = await client.storage.from(
                  "payment-proofs",
                ).upload(candidate, file, {
                  contentType: file.type,
                  upsert: false,
                });
                if (upErr) {
                  return fail(
                    "The proof could not be uploaded. Check the file and try again.",
                  );
                }
                uploaded = { file, path: candidate };
              }
              path = uploaded.path;
            }
            await api.rpc("submit_payment", {
              p_id: paymentId,
              p_booking_id: r.id,
              p_method: method,
              p_reference_no: String(form.get("reference") ?? "").trim() ||
                null,
              p_amount: amount,
              p_proof_path: path,
            });
            toast("Payment sent. An admin will check it.", { tone: "success" });
            await load();
          } catch (e) {
            return fail(bookingMessage(e));
          }
        },
      });
    }

    function actionsFor(r) {
      const buttons = [];
      const open = ["pending_approval", "confirmed"].includes(r.status);
      if (open && Number(r.price_snapshot) > 0 && remaining(r) > 0) {
        buttons.push(
          iconButton({
            label: `Pay for ${r.doc_no}`,
            icon: "currency",
            onClick: () => payModal(r),
          }),
        );
      }
      const x = range(r);
      if (open && x && x.start.getTime() > Date.now()) {
        buttons.push(
          iconButton({
            label: `Cancel ${r.doc_no}`,
            icon: "x",
            variant: "danger",
            onClick: () => cancelModal(r),
          }),
        );
      }
      return h("span", { class: "row-actions" }, ...buttons);
    }

    const schema = {
      columns: [
        {
          key: "when",
          label: "When",
          render: (r) => {
            const x = range(r);
            return h(
              "span",
              {},
              x ? formatDateTime(x.start) : "—",
              h(
                "span",
                { class: "sub" },
                `${r.court_name_snapshot} · ${r.doc_no}`,
              ),
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
                ? h(
                  "span",
                  { class: "sub" },
                  `Decision due by ${formatDateTime(r.expires_at)}`,
                )
                : null,
              r.cancel_reason ||
                (["rejected", "expired", "no_show"].includes(r.status)
                  ? r.status_reason
                  : null)
                ? h(
                  "span",
                  { class: "sub" },
                  r.cancel_reason || r.status_reason,
                )
                : null,
            ),
        },
        {
          key: "price",
          label: "Price",
          align: "right",
          render: (r) =>
            Number(r.price_snapshot) > 0
              ? formatMoney(r.price_snapshot)
              : "Free",
        },
        {
          key: "paid",
          label: "Payment",
          render: (r) => {
            if (!(Number(r.price_snapshot) > 0)) return "—";
            const t = state.pays[r.id];
            const paid = Number(t?.verified_total ?? 0);
            const pending = Number(t?.pending_total ?? 0);
            if (paid >= Number(r.price_snapshot)) {
              return badge("Paid", "success");
            }
            return h(
              "span",
              {},
              paid ? `${formatMoney(paid)} paid` : "Not Paid",
              pending
                ? h(
                  "span",
                  { class: "sub" },
                  `${formatMoney(pending)} waiting to be checked`,
                )
                : null,
            );
          },
        },
        {
          key: "actions",
          label: "Action",
          align: "center",
          render: actionsFor,
        },
      ],
    };

    function draw() {
      const rows = state.rows.filter((r) =>
        state.tab === "upcoming" ? isUpcoming(r) : !isUpcoming(r)
      );
      tabsHost.replaceChildren(tableFilter({
        activeId: state.tab,
        tabs: [
          {
            id: "upcoming",
            label: "Upcoming",
            badge: state.rows.filter(isUpcoming).length || undefined,
          },
          { id: "past", label: "Past and Closed" },
        ],
        onChange: (id) => {
          state.tab = id;
          draw();
        },
      }));
      tableHost.replaceChildren(dataTable({
        searchState: state,
        filter: tabsHost,
        schema,
        rows,
        state: state.status,
        ariaLabel: "My Bookings",
        onRetry: load,
        emptyTitle: state.tab === "upcoming"
          ? "No upcoming bookings"
          : "Nothing here yet",
        emptyText: state.tab === "upcoming"
          ? "Book a court to see it here."
          : "Finished, cancelled and declined bookings are listed here.",
      }));
    }

    page.append(
      memberHero({
        iconName: "clock",
        eyebrow: "Play",
        title: "My Bookings",
        chip: "Reservation History",
        description: "Your court requests, their status, and payment.",
        actions: [
          button({
            label: "Book a Court",
            variant: "primary",
            icon: "plus",
            onClick: () => (location.hash = "#/book"),
          }),
        ],
      }),
      tableHost,
    );
    load();
    return page;
  }

  return { bookPage, myBookingsPage };
}
