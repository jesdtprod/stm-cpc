import { h, icon } from "../ui.js";

// Page-local listeners disappear with the routed page.
export function enablePullRefresh(page, onRefresh) {
  if (!page?.prepend || !page?.addEventListener) return;
  let editing = false;
  page.addEventListener("input", (event) => {
    if (
      event.target.closest("form, [role=dialog], .field") &&
      !event.target.matches('input[type="search"]')
    ) editing = true;
  }, { passive: true });
  const pullStatus = h(
    "div",
    {
      class: "ranking-pull-status",
      role: "status",
      "aria-label": "Pull down to refresh",
      hidden: true,
    },
    icon("spinner"),
  );
  const setPullState = (stateName) => {
    const label = stateName === "refreshing"
      ? "Refreshing"
      : stateName === "ready"
      ? "Release to refresh"
      : "Pull down to refresh";
    pullStatus.setAttribute("aria-label", label);
    pullStatus.classList.toggle("is-ready", stateName === "ready");
    pullStatus.classList.toggle("is-refreshing", stateName === "refreshing");
  };
  let pullStart = null;
  let pullDistance = 0;
  let refreshing = false;
  const atTop = () => {
    for (let node = page; node; node = node.parentElement) {
      if (node.scrollTop > 0) return false;
    }
    return globalThis.scrollY <= 0;
  };
  page.addEventListener("touchstart", (event) => {
    pullStart = !refreshing && !editing &&
        !document.querySelector(
          "dialog[open], [role=dialog][aria-modal=true]",
        ) &&
        matchMedia("(max-width: 720px)").matches &&
        event.touches.length === 1 && atTop() &&
        !event.target.closest(
          "button, a, input, select, textarea, [role=dialog]",
        )
      ? { x: event.touches[0].clientX, y: event.touches[0].clientY }
      : null;
    pullDistance = 0;
  }, { passive: true });
  page.addEventListener("touchmove", (event) => {
    if (!pullStart) return;
    if (event.touches.length !== 1 || !atTop()) {
      pullStart = null;
      pullStatus.hidden = true;
      setPullState("idle");
      return;
    }
    const dy = event.touches[0].clientY - pullStart.y;
    const dx = Math.abs(event.touches[0].clientX - pullStart.x);
    if (dx > 16 && dx > Math.abs(dy)) {
      pullStart = null;
      pullStatus.hidden = true;
      setPullState("idle");
      return;
    }
    pullDistance = Math.max(0, dy);
    if (pullDistance > 12) {
      event.preventDefault();
      pullStatus.hidden = false;
      setPullState(pullDistance >= 72 ? "ready" : "idle");
    }
  }, { passive: false });
  page.addEventListener("touchend", async () => {
    const ready = pullStart && pullDistance >= 72;
    pullStart = null;
    pullDistance = 0;
    if (!ready || refreshing) {
      pullStatus.hidden = true;
      setPullState("idle");
      return;
    }
    refreshing = true;
    setPullState("refreshing");
    try {
      await onRefresh();
    } finally {
      refreshing = false;
      pullStatus.hidden = true;
      setPullState("idle");
    }
  });
  page.addEventListener("touchcancel", () => {
    pullStart = null;
    pullDistance = 0;
    if (!refreshing) {
      pullStatus.hidden = true;
      setPullState("idle");
    }
  }, { passive: true });
  page.prepend(pullStatus);
}
