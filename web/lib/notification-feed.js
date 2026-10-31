// Live notifications for the open page (PLAN 9.3). While someone is signed in, the page listens to Supabase Realtime for new
// rows in member_notifications (row-level security lets it hear only the person's own). Each new message raises a toast,
// updates the unread count (tab title, side menu badge and the installed app's icon badge) and tells the notifications
// page to refresh. Messages that arrive while the app is closed are pushed to the device by the service worker instead.
const BASE_TITLE = "Capitol Pickleball Club";

export function createNotificationFeed({ client, api, toast, onOpen }) {
  let channel = null;
  let count = 0;
  let started = false;

  function show(n) {
    count = Math.max(0, n);
    globalThis.__cpcUnread = count;
    try {
      navigator.setAppBadge?.(count);
      if (!count) navigator.clearAppBadge?.();
    } catch {
      // not an installed app: no icon badge
    }
    dispatchEvent(new CustomEvent("cpc:unread", { detail: { count } }));
  }

  async function refreshCount() {
    try {
      show(Number(await api.rpc("my_unread_count")) || 0);
    } catch {
      // keep the last known count
    }
  }

  function start() {
    if (started) return;
    started = true;
    refreshCount();
    channel = client.channel(
      `notifications-${Math.random().toString(36).slice(2, 10)}`,
    )
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "member_notifications" },
        (payload) => {
          const n = payload?.new;
          if (!n) return;
          show(count + 1);
          dispatchEvent(new CustomEvent("cpc:notification", { detail: n }));
          toast(n.body ?? "", {
            title: n.title,
            actionLabel: n.url ? "Open" : undefined,
            onAction: n.url ? () => onOpen?.(n) : undefined,
            timeout: 30_000,
          });
        },
      )
      .subscribe();
    document.addEventListener("visibilitychange", onVisible);
  }

  function onVisible() {
    if (document.visibilityState === "visible") refreshCount();
  }

  function stop() {
    if (!started) return;
    started = false;
    document.removeEventListener("visibilitychange", onVisible);
    if (channel) client.removeChannel(channel);
    channel = null;
    show(0);
  }

  addEventListener("cpc:unread", (e) => {
    const n = e.detail?.count ?? 0;
    const clean = document.title.replace(/^\(\d+\)\s*/, "");
    document.title = n > 0 ? `(${n}) ${clean}` : clean;
  });

  return { start, stop, refreshCount };
}

export { BASE_TITLE };
