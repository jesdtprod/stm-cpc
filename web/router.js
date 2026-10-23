// Hash router. Routes map "#/path" to a render function returning a Node.
// Stale renders never overwrite a newer navigation.

const routes = new Map();
let token = 0;

export function route(path, render, title) {
  routes.set(path, { render, title });
}

export function currentPath() {
  const hash = location.hash.replace(/^#/, "");
  const path = hash.split("?")[0] || "/";
  return path.startsWith("/") ? path : `/${path}`;
}

export function start(main, { onChange, notFound }) {
  const run = async () => {
    const mine = ++token;
    const path = currentPath();
    const entry = routes.get(path) ??
      { render: notFound, title: "Page not found" };
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
  return run();
}
