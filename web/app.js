import { componentsPage, homePage, notFoundPage } from "./pages.js";
import { currentPath, route, start } from "./router.js";
import { h, icon, toast } from "./ui.js";

const NAV = [
  { path: "/", label: "Home", icon: "home" },
  { path: "/components", label: "Components", icon: "grid" },
];

route("/", homePage, "Home");
route("/components", componentsPage, "Components");

const main = document.getElementById("main");
const nav = document.getElementById("nav");

document.getElementById("skip").addEventListener("click", () => main.focus());

function drawNav(path) {
  nav.replaceChildren(
    ...NAV.map((n) =>
      h(
        "a",
        { href: `#${n.path}`, "aria-current": n.path === path ? "page" : null },
        icon(n.icon),
        n.label,
      )
    ),
  );
}

drawNav(currentPath());
start(main, { onChange: drawNav, notFound: notFoundPage });

// Service worker: app shell only. A waiting worker is announced, never applied silently.
if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("./service-worker.js").then((reg) => {
    const announce = (worker) =>
      toast("A new version is ready.", {
        actionLabel: "Reload",
        onAction: () => worker.postMessage({ type: "SKIP_WAITING" }),
      });
    if (reg.waiting && navigator.serviceWorker.controller) {
      announce(reg.waiting);
    }
    reg.addEventListener("updatefound", () => {
      const worker = reg.installing;
      worker?.addEventListener("statechange", () => {
        if (
          worker.state === "installed" && navigator.serviceWorker.controller
        ) announce(worker);
      });
    });
  });
  let reloading = false;
  navigator.serviceWorker.addEventListener("controllerchange", () => {
    if (reloading) return;
    reloading = true;
    location.reload();
  });
}
