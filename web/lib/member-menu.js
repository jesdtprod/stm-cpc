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
