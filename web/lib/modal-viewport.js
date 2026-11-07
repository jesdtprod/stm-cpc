// Follow browser bars and the keyboard without leaving listeners after close.
export function fitModalViewport(dialog) {
  const view = dialog.ownerDocument?.defaultView ?? globalThis;
  const viewport = view.visualViewport;
  const update = () => {
    const height = viewport?.height ?? view.innerHeight;
    if (Number.isFinite(height) && height > 0) {
      dialog.style.setProperty("--modal-visible-height", `${height}px`);
      dialog.style.setProperty("--modal-visible-top", `${viewport?.offsetTop ?? 0}px`);
    }
  };
  update();
  viewport?.addEventListener("resize", update);
  viewport?.addEventListener("scroll", update);
  view.addEventListener?.("resize", update);
  dialog.addEventListener("close", () => {
    viewport?.removeEventListener("resize", update);
    viewport?.removeEventListener("scroll", update);
    view.removeEventListener?.("resize", update);
  }, { once: true });
}
