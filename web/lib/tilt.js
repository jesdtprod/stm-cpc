// Card tilt: a card turns left or right toward the mouse (side to side only, never up or down) and settles flat when the
// mouse leaves.
// Only the movement lives here; every colour and style stays in the stylesheet. Mouse only (touch and pens are left alone)
// and skipped when the person asks for reduced motion. One listener on the container serves every card in it.
export function enableTilt(container, selector, { max = 7 } = {}) {
  if (!container || globalThis.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches) return;
  const reset = (card) => {
    card.classList.remove("is-tilting");
    card.style.removeProperty("--tilt-y");
  };
  container.addEventListener("pointermove", (event) => {
    if (event.pointerType !== "mouse") return;
    const card = event.target.closest?.(selector);
    if (!card) return;
    const box = card.getBoundingClientRect();
    if (!box.width || !box.height) return;
    const px = (event.clientX - box.left) / box.width - 0.5; // -0.5 (left) .. 0.5 (right)
    card.classList.add("is-tilting");
    card.style.setProperty("--tilt-y", `${(px * 2 * max).toFixed(2)}deg`);
  });
  container.addEventListener("pointerout", (event) => {
    const card = event.target.closest?.(selector);
    if (card && !card.contains(event.relatedTarget)) reset(card);
  });
}
