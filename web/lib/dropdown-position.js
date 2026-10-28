// Keep shared dropdowns inside the viewport and any scrolling modal body.
export function dropdownPosition(trigger, popup, { center = false } = {}) {
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
    let left = (viewport?.offsetLeft ?? 0) + 8;
    let right = (viewport?.offsetLeft ?? 0) +
      (viewport?.width ?? view.innerWidth ?? doc.documentElement?.clientWidth ?? 1024) - 8;
    for (
      let parent = trigger.parentElement;
      parent;
      parent = parent.parentElement
    ) {
      const style = view.getComputedStyle(parent);
      if (!/(auto|scroll|hidden|clip)/.test(`${style.overflowY} ${style.overflowX}`)) continue;
      const rect = parent.getBoundingClientRect();
      if (center && Number.isFinite(rect.left) && parent.clientWidth) {
        left = Math.max(left, rect.left + (parent.clientLeft ?? 0) + 8);
        right = Math.min(right, rect.left + (parent.clientLeft ?? 0) + parent.clientWidth - 8);
      }
      if (!/(auto|scroll|hidden|clip)/.test(style.overflowY)) continue;
      const innerTop = rect.top + parent.clientTop;
      top = Math.max(top, innerTop + 8);
      bottom = Math.min(bottom, innerTop + parent.clientHeight - 8);
    }
    const rect = trigger.getBoundingClientRect();
    if (center) {
      const availableWidth = Math.max(0, right - left);
      popup.style.setProperty("--dropdown-max-width", `${availableWidth}px`);
      const width = Math.min(popup.offsetWidth, availableWidth);
      const origin = popup.offsetParent?.getBoundingClientRect().left ?? rect.left;
      popup.style.setProperty("--dropdown-left", `${left + (availableWidth - width) / 2 - origin}px`);
    }
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
