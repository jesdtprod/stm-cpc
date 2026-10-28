// Notifications page (PLAN 9.3): the member's messages, and switching alerts on for this device.
//   * Messages appear here as they arrive (the page refreshes itself from the live feed) and open the page they are about.
//   * "Alerts on This Device" registers the device for push messages, so approvals, booking decisions, payments, draws,
//     results, rank changes and match times arrive even when the app is in the background or closed.
import { badge, button, emptyState, h, icon, memberHero, toast } from "./ui.js";
import { formatDateTime } from "./lib/dates.js";
import {
  disablePush,
  enablePush,
  PUSH_MESSAGES,
  pushState,
} from "./lib/push.js";

function notificationMeta(n) {
  const text = `${n.kind || ""} ${n.title || ""}`.toLowerCase();
  if (text.includes("rank")) {
    return { iconName: "medal", tone: "accent" };
  }
  if (text.includes("confirmed") || text.includes("approved") || text.includes("approval")) {
    return { iconName: "calendarCheck", tone: "success" };
  }
  if (text.includes("declined") || text.includes("cancelled") || text.includes("rejected")) {
    return { iconName: "alertCircle", tone: "danger" };
  }
  if (text.includes("payment") || text.includes("fee") || text.includes("paid")) {
    return { iconName: "currency", tone: "info" };
  }
  if (text.includes("draw") || text.includes("tournament") || text.includes("match") || text.includes("bracket")) {
    return { iconName: "trophy", tone: "accent" };
  }
  return { iconName: "inbox", tone: "neutral" };
}

export function createNotificationPages({ api, feed }) {
  function notificationsPage() {
    const page = h("div", { class: "page notifications-page" });
    const deviceHost = h("section", { class: "card notice-device-card" });
    const listHost = h("section", { class: "stack", "aria-live": "polite" });
    const state = { items: [], status: "loading", device: null, tab: "all" };

    async function load() {
      try {
        state.items = await api.rpc("my_notifications", { p_limit: 100 }) ?? [];
        state.status = "ready";
      } catch {
        state.status = "error";
      }
      drawList();
    }

    async function loadDevice() {
      try {
        state.device = await pushState(api);
      } catch {
        state.device = {
          supported: false,
          permission: "unsupported",
          registered: false,
        };
      }
      drawDevice();
    }

    async function open(n) {
      if (!n.is_read) {
        try {
          await api.rpc("mark_notifications_read", { p_ids: [n.id] });
          n.is_read = true;
          feed?.refreshCount?.();
        } catch {
          // reading still works
        }
      }
      if (n.url) location.hash = n.url;
      else drawList();
    }

    async function markAll() {
      try {
        await api.rpc("mark_notifications_read", {});
        state.items.forEach((n) => (n.is_read = true));
        feed?.refreshCount?.();
        toast("All messages marked as read.", { tone: "success" });
        drawList();
      } catch {
        toast("That did not work. Try again.", { tone: "error" });
      }
    }

    function drawDevice() {
      const d = state.device;
      let statusBadge = badge("Checking", "neutral");
      let descText = "Checking this device...";
      let actionBtn = null;

      if (!d) {
        statusBadge = badge("Checking", "neutral");
        descText = "Checking alert capability on this device...";
      } else if (!d.supported) {
        statusBadge = badge("Unavailable", "neutral");
        descText = `${PUSH_MESSAGES[d.reason ?? "unsupported"]} Messages still appear in this app while open.`;
      } else if (d.permission === "denied") {
        statusBadge = badge("Blocked", "warning");
        descText = "Alerts are blocked in site settings. Enable notification permissions in your browser to get updates.";
      } else if (d.registered) {
        statusBadge = badge("Active", "success");
        descText = "This device receives instant push alerts for court bookings, rank changes, and tournament draws.";
        actionBtn = button({
          label: "Turn Off Alerts",
          icon: "x",
          variant: "secondary",
          size: "sm",
          onClick: async () => {
            try {
              await disablePush(api);
              toast("Alerts are off on this device.", { tone: "success" });
            } catch {
              toast("That did not work. Try again.", { tone: "error" });
            }
            loadDevice();
          },
        });
      } else {
        statusBadge = badge("Disabled", "neutral");
        descText = "Get instant push alerts for court bookings, approvals, payments, rank changes, and tournament match draws.";
        actionBtn = button({
          label: "Enable Device Alerts",
          icon: "check",
          variant: "primary",
          size: "sm",
          onClick: async (event) => {
            event.currentTarget.disabled = true;
            const r = await enablePush(api);
            if (r.ok) {
              toast("Alerts are on for this device.", { tone: "success" });
            } else {
              toast(PUSH_MESSAGES[r.reason] ?? PUSH_MESSAGES.registration, {
                tone: r.reason === "denied" ? "warning" : "error",
              });
            }
            loadDevice();
          },
        });
      }

      deviceHost.replaceChildren(
        h(
          "div",
          { class: "notice-device-row" },
          h(
            "div",
            { class: "notice-device-meta" },
            h(
              "div",
              { class: "notice-device-icon", "aria-hidden": "true" },
              icon("phone"),
            ),
            h(
              "div",
              { class: "notice-device-copy" },
              h(
                "div",
                { class: "notice-device-head" },
                h("h3", { class: "notice-device-title" }, "Alerts on This Device"),
                statusBadge,
              ),
              h("p", { class: "notice-device-desc muted" }, descText),
            ),
          ),
          actionBtn
            ? h("div", { class: "notice-device-action" }, actionBtn)
            : null,
        ),
      );
    }

    function drawList() {
      if (state.status === "loading") {
        listHost.replaceChildren(
          h("p", { class: "muted" }, "Loading your messages..."),
        );
        return;
      }
      if (state.status === "error") {
        listHost.replaceChildren(
          h(
            "p",
            { class: "field-error", role: "alert" },
            "Your messages could not be loaded.",
          ),
          button({ label: "Try Again", onClick: load }),
        );
        return;
      }
      if (!state.items.length) {
        listHost.replaceChildren(
          emptyState({
            icon: "inbox",
            title: "No messages yet",
            description:
              "Approvals, booking decisions, results and rank changes will appear here.",
          }),
        );
        return;
      }

      const total = state.items.length;
      const unread = state.items.filter((n) => !n.is_read).length;
      const filtered = state.tab === "unread"
        ? state.items.filter((n) => !n.is_read)
        : state.items;

      const toolbar = h(
        "div",
        { class: "notice-toolbar" },
        h(
          "div",
          { class: "notice-tabs", role: "tablist", "aria-label": "Filter notifications" },
          h(
            "button",
            {
              type: "button",
              class: `notice-tab-btn${state.tab === "all" ? " is-active" : ""}`,
              role: "tab",
              "aria-selected": state.tab === "all" ? "true" : "false",
              onClick: () => {
                state.tab = "all";
                drawList();
              },
            },
            "All",
            h("span", { class: "notice-tab-count" }, String(total)),
          ),
          h(
            "button",
            {
              type: "button",
              class: `notice-tab-btn${state.tab === "unread" ? " is-active" : ""}`,
              role: "tab",
              "aria-selected": state.tab === "unread" ? "true" : "false",
              onClick: () => {
                state.tab = "unread";
                drawList();
              },
            },
            "Unread",
            unread > 0 ? h("span", { class: "notice-tab-count is-unread" }, String(unread)) : null,
          ),
        ),
        unread > 0
          ? button({
            label: "Mark All as Read",
            icon: "check",
            size: "sm",
            variant: "ghost",
            onClick: markAll,
          })
          : null,
      );

      let contentNode;
      if (!filtered.length && state.tab === "unread") {
        contentNode = emptyState({
          icon: "checkCircle",
          title: "All caught up",
          description: "You have no unread notifications right now.",
        });
      } else {
        contentNode = h(
          "ul",
          { class: "notice-list" },
          ...filtered.map((n) => {
            const meta = notificationMeta(n);
            return h(
              "li",
              {},
              h(
                "button",
                {
                  type: "button",
                  class: `notice-card${n.is_read ? " is-read" : " is-unread"}`,
                  onClick: () => open(n),
                },
                h(
                  "div",
                  { class: `notice-avatar is-${meta.tone}`, "aria-hidden": "true" },
                  icon(meta.iconName),
                  !n.is_read ? h("span", { class: "notice-unread-dot" }) : null,
                ),
                h(
                  "div",
                  { class: "notice-content" },
                  h(
                    "div",
                    { class: "notice-header" },
                    h("strong", { class: "notice-title" }, n.title),
                    h("span", { class: "notice-time" }, formatDateTime(n.created_at)),
                  ),
                  n.body ? h("p", { class: "notice-body sub" }, n.body) : null,
                ),
                n.url
                  ? h(
                    "span",
                    { class: "notice-arrow", "aria-hidden": "true" },
                    icon("chevronRight"),
                  )
                  : null,
              ),
            );
          }),
        );
      }

      listHost.replaceChildren(toolbar, contentNode);
    }

    const onLive = () => {
      if (page.isConnected) load();
    };
    addEventListener("cpc:notification", onLive);

    page.append(
      memberHero({
        iconName: "inbox",
        eyebrow: "Account",
        title: "Notifications",
        chip: "Messages and Alerts",
        titleBadge: true,
        description: "Your messages from the club, as they happen.",
      }),
      deviceHost,
      listHost,
    );
    drawDevice();
    drawList();
    load();
    loadDevice();
    return page;
  }

  return { notificationsPage };
}
