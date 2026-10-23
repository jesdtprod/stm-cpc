// Hash router with access rules. Routes map "#/path" to a render function returning a Node.
// Stale renders never overwrite a newer navigation. Access rules are in lib/permissions.js.
const routes = new Map();
let token = 0;

export function route(path, render, title, access = "public") {
  routes.set(path, { render, title, access });
}

export function routeAccess(path) {
  return routes.get(path)?.access ?? "public";
}

export function currentPath() {
  const hash = location.hash.replace(/^#/, "");
  const path = hash.split("?")[0] || "/";
  return path.startsWith("/") ? path : `/${path}`;
}

/**
 * start(main, { onChange, notFound, forbidden, check })
 *   check(access) -> { allow } | { redirect: "#/x" } | { forbidden }
 * Returns { refresh } so the caller can re-run the current route after sign-in or sign-out.
 */
export function start(main, { onChange, notFound, forbidden, check }) {
  const run = async () => {
    const mine = ++token;
    const path = currentPath();
    let entry = routes.get(path) ??
      { render: notFound, title: "Page not found", access: "public" };
    const verdict = check ? check(entry.access) : { allow: true };
    if (verdict.redirect && verdict.redirect !== location.hash) {
      location.hash = verdict.redirect; // the hashchange event runs this again
      return;
    }
    if (verdict.forbidden || verdict.redirect) {
      entry = {
        render: forbidden ?? notFound,
        title: "No access",
        access: "public",
      };
    }
    main.setAttribute("aria-busy", "true");
    const node = await entry.render();
    if (mine !== token) return;
    main.replaceChildren(node);
    main.setAttribute("aria-busy", "false");
    document.title = `${entry.title} · Capitol Pickleball Club`;
    onChange?.(path);
    (main.querySelector("#page-title") ?? main).focus({ preventScroll: false });
  };
  addEventListener("hashchange", run);
  run();
  return { refresh: run };
}
