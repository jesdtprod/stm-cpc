// Keep shared dropdowns inside the viewport and any scrolling modal body.
export function dropdownPosition(trigger, popup) {
  const doc = trigger.ownerDocument ?? globalThis.document;
  const view = doc?.defaultView ?? globalThis;
  let active = false;
  let naturalHeight = 0;
  let observer;

  function update() {
    if (!active || popup.hidden || !trigger.getBoundingClientRect) return;
    if (trigger.isConnected === false) return stop();
    const viewport = view.visualViewport;
    let top = (viewport?.offsetTop ?? 0) + 8;
    let bottom = (viewport?.offsetTop ?? 0) +
      (viewport?.height ?? view.innerHeight ??
        doc.documentElement.clientHeight) -
      8;
    for (
      let parent = trigger.parentElement;
      parent;
      parent = parent.parentElement
    ) {
      const style = view.getComputedStyle(parent);
      if (!/(auto|scroll|hidden|clip)/.test(style.overflowY)) continue;
      const rect = parent.getBoundingClientRect();
      const innerTop = rect.top + parent.clientTop;
      top = Math.max(top, innerTop + 8);
      bottom = Math.min(bottom, innerTop + parent.clientHeight - 8);
    }
    const rect = trigger.getBoundingClientRect();
    naturalHeight = Math.max(
      naturalHeight,
      popup.scrollHeight,
      popup.offsetHeight,
    );
    const above = Math.max(0, rect.top - top - 6);
    const below = Math.max(0, bottom - rect.bottom - 6);
    const up = naturalHeight > below && above > below;
    popup.setAttribute("data-placement", up ? "top" : "bottom");
    popup.style.setProperty("--dropdown-max-height", `${up ? above : below}px`);
  }
  function onScroll(event) {
    if (!popup.contains(event.target)) update();
  }
  function start() {
    if (active) return update();
    active = true;
    naturalHeight = 0;
    popup.style.setProperty("--dropdown-max-height", "none");
    update();
    doc.addEventListener("scroll", onScroll, true);
    view.addEventListener?.("resize", update);
    view.visualViewport?.addEventListener("resize", update);
    view.visualViewport?.addEventListener("scroll", update);
    if (view.ResizeObserver) {
      observer = new view.ResizeObserver(update);
      observer.observe(popup);
      observer.observe(trigger);
    }
  }
  function stop() {
    active = false;
    doc.removeEventListener("scroll", onScroll, true);
    view.removeEventListener?.("resize", update);
    view.visualViewport?.removeEventListener("resize", update);
    view.visualViewport?.removeEventListener("scroll", update);
    observer?.disconnect();
    observer = null;
  }
  return { start, stop, update };
}
