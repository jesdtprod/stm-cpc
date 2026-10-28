// Member menu switches (Settings > Member Menu). Each key turns one member menu link on or off: the side menu, the
// dashboard quick links and the shortcut tabs. Hiding a link is a convenience only; the page and its data are still
// guarded by the router and the database.
export const MEMBER_MENU_SETTINGS = {
  "member_menu.book": "/book",
  "member_menu.bookings": "/bookings",
  "member_menu.events": "/events",
  "member_menu.ranking": "/ranking",
};

let hidden = new Set();

/** rows: [{ key, value }] from the settings table; a key that is missing or not false stays visible. */
export function setMemberMenu(rows = []) {
  hidden = new Set(
    rows.filter((r) => MEMBER_MENU_SETTINGS[r.key] && r.value === false)
      .map((r) => MEMBER_MENU_SETTINGS[r.key]),
  );
}

/** path: "/book" or "#/book". */
export function memberMenuHidden(path) {
  return hidden.has(String(path).replace(/^#/, ""));
}

// Live menu (Settings > Member Menu). After an admin saves a member_menu switch, announce() sends an empty Realtime
// broadcast; every signed-in page that hears it reads the switches again (under row-level security) and redraws.
// The broadcast carries nothing, so a forged one can only cause a harmless re-read. Returning to the tab also re-reads,
// in case a broadcast was missed.
const LIVE_TOPIC = "member-menu";

export function createMemberMenuLive({ client, api, onChange }) {
  let channel = null;

  async function reload() {
    try {
      const rows = await api.read((c) =>
        c.from("settings").select("key,value")
          .in("key", Object.keys(MEMBER_MENU_SETTINGS))
          .is("unit_id", null).is("deleted_at", null)
      );
      const before = [...hidden].sort().join();
      setMemberMenu(Array.isArray(rows) ? rows : []);
      if ([...hidden].sort().join() !== before) onChange?.();
    } catch {
      // keep the menu as it was
    }
  }

  function onVisible() {
    if (document.visibilityState === "visible") reload();
  }

  function start() {
    if (channel) return;
    channel = client.channel(LIVE_TOPIC)
      .on("broadcast", { event: "changed" }, reload)
      .subscribe();
    document.addEventListener("visibilitychange", onVisible);
  }

  function stop() {
    if (!channel) return;
    document.removeEventListener("visibilitychange", onVisible);
    client.removeChannel(channel);
    channel = null;
  }

  function announce() {
    reload();
    channel?.send({ type: "broadcast", event: "changed", payload: {} });
  }

  return { start, stop, announce };
}
