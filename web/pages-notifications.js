// Notifications page (PLAN 9.3): the member's messages, and switching alerts on for this device.
//   * Messages appear here as they arrive (the page refreshes itself from the live feed) and open the page they are about.
//   * "Alerts on this device" registers the device for push messages, so approvals, booking decisions, payments, draws,
//     results, rank changes and match times arrive even when the app is in the background or closed.
import { badge, button, emptyState, h, pageHeader, toast } from "./ui.js";
import { formatDateTime } from "./lib/dates.js";
import { disablePush, enablePush, pushState } from "./lib/push.js";

export function createNotificationPages({ api, feed }) {
  function notificationsPage() {
    const page = h("div", { class: "page" });
    const deviceHost = h("section", { class: "card stack" });
    const listHost = h("section", { class: "stack", "aria-live": "polite" });
    const state = { items: [], status: "loading", device: null };

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
          feed.refreshCount();
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
        feed.refreshCount();
        drawList();
      } catch {
        toast("That did not work. Try again.", { tone: "error" });
      }
    }

    function drawDevice() {
      const d = state.device;
      const children = [
        h("h2", {}, "Alerts on this device"),
      ];
      if (!d) {
        children.push(h("p", { class: "muted" }, "Checking this device..."));
      } else if (!d.supported) {
        children.push(
          h(
            "p",
            { class: "muted" },
            "This browser cannot receive alerts while the app is closed. Messages still appear here and while the app is open. On an iPhone, add the app to your Home Screen first, then open it from there.",
          ),
        );
      } else if (d.permission === "denied") {
        children.push(
          h(
            "p",
            { class: "muted" },
            "Alerts are blocked for this site. Allow notifications in your browser's site settings, then come back here.",
          ),
        );
      } else if (d.registered) {
        children.push(
          h(
            "p",
            {},
            badge("On", "success"),
            " This device gets alerts even when the app is in the background or closed.",
          ),
          button({
            label: "Turn off alerts on this device",
            onClick: async () => {
              try {
                await disablePush(api);
                toast("Alerts are off on this device.", { tone: "success" });
              } catch {
                toast("That did not work. Try again.", { tone: "error" });
              }
              loadDevice();
            },
          }),
        );
      } else {
        children.push(
          h(
            "p",
            { class: "muted" },
            "Get a message on this device the moment something happens: your membership or booking is decided, a payment is checked, the draw is made, results are in, or your rank changes. It works even when the app is in the background or closed.",
          ),
          button({
            label: "Turn on alerts on this device",
            variant: "primary",
            onClick: async () => {
              const r = await enablePush(api);
              if (r.ok) {
                toast("Alerts are on for this device.", { tone: "success" });
              } else if (r.reason === "denied") {
                toast(
                  "Alerts were not allowed. You can change this in your browser settings.",
                  { tone: "warning" },
                );
              } else {toast("Alerts could not be turned on. Try again.", {
                  tone: "error",
                });}
              loadDevice();
            },
          }),
        );
      }
      deviceHost.replaceChildren(...children);
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
          button({ label: "Try again", onClick: load }),
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
      const unread = state.items.filter((n) => !n.is_read).length;
      listHost.replaceChildren(
        h(
          "div",
          { class: "actions" },
          h("strong", {}, unread ? `${unread} unread` : "All read"),
          unread
            ? button({
              label: "Mark all as read",
              size: "sm",
              onClick: markAll,
            })
            : null,
        ),
        h(
          "ul",
          { class: "notice-list" },
          ...state.items.map((n) =>
            h(
              "li",
              {},
              h(
                "button",
                {
                  type: "button",
                  class: `notice-item${n.is_read ? "" : " is-unread"}`,
                  onClick: () => open(n),
                },
                h("span", { class: "notice-title" }, n.title),
                n.body ? h("span", { class: "notice-body" }, n.body) : null,
                h(
                  "span",
                  { class: "notice-time" },
                  formatDateTime(n.created_at),
                ),
              ),
            )
          ),
        ),
      );
    }

    const onLive = () => {
      if (page.isConnected) load();
    };
    addEventListener("cpc:notification", onLive);

    page.append(
      pageHeader({
        icon: "inbox",
        eyebrow: "Account",
        title: "Notifications",
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
