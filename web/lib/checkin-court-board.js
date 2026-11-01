import { badge, button, h, icon } from "../ui.js";
import { timeLabel } from "./slot-grid.js";
import { formatDateTime } from "./dates.js";

/** A read-only board; the database decides occupancy and reservation timing. */
export function createCheckinCourtBoard({ api }) {
  const cards = h("div", {
    class: "checkin-court-grid",
    "aria-live": "polite",
    "aria-busy": "true",
  });
  let busy = false;
  let refreshQueued = false;
  let disposed = false;
  let timer;
  let observer;
  const refreshButton = button({
    label: "Refresh",
    icon: "refresh",
    size: "sm",
    onClick: () => refresh(),
  });
  refreshButton.disabled = true;
  refreshButton.setAttribute("data-pending", "true");
  refreshButton.setAttribute("aria-busy", "true");
  const description = h(
    "p",
    { class: "sub" },
    "One ongoing booking and the next three arrivals per court.",
  );
  const root = h(
    "section",
    { class: "checkin-court-board", "aria-label": "Live court overview" },
    h(
      "div",
      { class: "checkin-card-head" },
      h(
        "div",
        { class: "checkin-head-lead" },
        h("span", { class: "badge-icon", "aria-hidden": "true" }, icon("grid")),
        h(
          "div",
          {},
          h("div", { class: "eyebrow" }, "Court operations"),
          h("h2", {}, "Court Overview"),
        ),
      ),
      refreshButton,
    ),
    description,
    cards,
  );

  const timeRange = (b) =>
    `${timeLabel(new Date(b.starts_at))} - ${timeLabel(new Date(b.ends_at))}`;
  function queueRow(number, label, booking, ongoing = false, loading = false) {
    return h(
      "div",
      {
        class: `checkin-queue-row${ongoing ? " is-ongoing" : ""}${
          !booking ? " is-empty" : ""
        }${loading ? " is-skeleton" : ""}`,
        "aria-hidden": loading ? "true" : null,
      },
      h(
        "span",
        { class: "checkin-queue-number", "aria-hidden": "true" },
        String(number).padStart(2, "0"),
      ),
      h(
        "div",
        { class: "checkin-queue-content" },
        h("span", { class: "checkin-court-label sub" }, label),
        h(
          "strong",
          { title: booking?.booked_by || "" },
          loading
            ? h("span", { class: "sk checkin-sk-name" })
            : booking?.booked_by ||
              (ongoing ? "Waiting for check-in" : "No reservation queued"),
        ),
        loading
          ? h(
            "span",
            { class: "sub" },
            h("span", { class: "sk checkin-sk-time" }),
          )
          : booking
          ? h("span", { class: "sub" }, icon("clock"), timeRange(booking))
          : null,
      ),
    );
  }
  function courtCard(c, number, loading = false) {
    const current = c?.current_booking;
    const courtNumber = c?.name?.match(/(\d+)$/)?.[1] ?? number;
    const ongoing = current?.status === "checked_in" ? current : null;
    // Older servers still get a bounded queue while the queue migration rolls out.
    const incoming = Array.isArray(c?.incoming_bookings)
      ? c.incoming_bookings.slice(0, 3)
      : [current?.status === "confirmed" ? current : null, c?.next_booking]
        .filter(Boolean).slice(0, 3);
    const closed = c && (c.court_status !== "available" || c.blocked_until);
    const label = !c
      ? "Not configured"
      : closed
      ? "Unavailable"
      : ongoing
      ? "On court"
      : incoming.length
      ? "Awaiting arrival"
      : "No check-in";
    return h(
      "article",
      {
        class: `checkin-court-card${ongoing ? " is-occupied" : ""}${
          loading ? " is-skeleton" : ""
        }`,
        "aria-busy": loading ? "true" : null,
        "aria-label": loading ? `Loading court ${number}` : null,
      },
      h(
        "div",
        { class: "checkin-court-heading" },
        h(
          "div",
          { class: "checkin-court-identity" },
          h(
            "span",
            { class: "checkin-court-number", "aria-hidden": "true" },
            String(courtNumber).padStart(2, "0"),
          ),
          h(
            "h3",
            {},
            loading
              ? h("span", {
                class: "sk checkin-sk-court-title",
                "aria-hidden": "true",
              })
              : c?.name ?? `Court ${number}`,
          ),
        ),
        loading
          ? h("span", { class: "sk checkin-sk-status", "aria-hidden": "true" })
          : badge(
            label,
            ongoing ? "success" : incoming.length ? "warning" : "neutral",
          ),
      ),
      !c && !loading
        ? h("p", { class: "sub" }, "This court has not been configured.")
        : null,
      closed
        ? h(
          "p",
          { class: "sub" },
          c.blocked_until
            ? `Court blocked until ${formatDateTime(c.blocked_until)}.`
            : `Court is ${c.court_status}.`,
        )
        : null,
      c || loading
        ? h(
          "div",
          { class: "checkin-court-queue" },
          queueRow(1, "Ongoing", ongoing, true, loading),
          queueRow(2, "Incoming", incoming[0], false, loading),
          queueRow(3, "Incoming", incoming[1], false, loading),
          queueRow(4, "Incoming", incoming[2], false, loading),
        )
        : null,
    );
  }
  function dispose() {
    disposed = true;
    clearInterval(timer);
    observer?.disconnect();
  }
  async function refresh() {
    if (disposed) return;
    if (busy) {
      refreshQueued = true;
      return;
    }
    busy = true;
    cards.setAttribute("aria-busy", "true");
    refreshButton.disabled = true;
    refreshButton.setAttribute("data-pending", "true");
    refreshButton.setAttribute("aria-busy", "true");
    try {
      const data = await api.rpc("checkin_court_board");
      if (disposed) return;
      if (!data || !Array.isArray(data.courts) || !data.as_of) {
        throw new Error("Invalid court board response");
      }
      cards.setAttribute("data-court-count", String(data.courts.length));
      cards.className = `checkin-court-grid${
        data.courts.length > 4 ? " has-many" : ""
      }`;
      description.textContent = `${
        data.court_area === "backgate"
          ? "Back Gate courts"
          : "Tennis Courts 1-4"
      } | One ongoing booking and the next three arrivals per court.`;
      cards.replaceChildren(
        ...data.courts.map((court, index) => courtCard(court, index + 1)),
      );
      if (!data.courts.length) {
        cards.append(
          h(
            "p",
            { class: "sub checkin-board-empty" },
            "No courts are assigned to this scanner.",
          ),
        );
      }
    } catch {
      if (disposed) return;
      // Never leave stale occupancy looking current after a failed refresh.
      cards.replaceChildren(
        h(
          "div",
          { class: "checkin-board-error", role: "alert" },
          icon("alertCircle"),
          h("strong", {}, "Court status unavailable"),
          h(
            "p",
            { class: "sub" },
            "The court board could not be loaded. Use Refresh to try again.",
          ),
        ),
      );
    } finally {
      busy = false;
      if (!disposed) cards.setAttribute("aria-busy", "false");
      refreshButton.disabled = false;
      refreshButton.removeAttribute("data-pending");
      refreshButton.removeAttribute("aria-busy");
      if (refreshQueued && !disposed) {
        refreshQueued = false;
        refresh();
      }
    }
  }
  cards.replaceChildren(
    ...[1, 2, 3, 4].map((number) => courtCard(null, number, true)),
  );
  requestAnimationFrame(() => {
    if (!root.isConnected) return;
    refresh();
    timer = setInterval(() => {
      if (root.isConnected) refresh();
      else dispose();
    }, 30000);
    observer = new MutationObserver(() => {
      if (!root.isConnected) dispose();
    });
    observer.observe(document.body, { childList: true, subtree: true });
  });
  return { element: root, refresh };
}
