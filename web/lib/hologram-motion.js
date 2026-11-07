/** Restart iOS foil effects after browser backgrounding; avoid nested CSS animation layers. */
export function enableHologramMotion(sticker) {
  const ios = /iPhone|iPad|iPod/.test(navigator.userAgent) ||
    (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  if (!ios || !sticker?.animate) return;
  const preference = matchMedia("(prefers-reduced-motion: reduce)");
  const animations = [];
  const start = () => {
    animations.splice(0).forEach((animation) => animation.cancel());
    sticker.classList.remove("has-ios-motion");
    if (preference.matches || document.hidden || !sticker.isConnected) return;
    sticker.classList.add("has-ios-motion");
    const run = (node, frames, duration) => {
      if (node) animations.push(node.animate(frames, { duration, iterations: Infinity, easing: "ease-in-out" }));
    };
    run(sticker, [
      { transform: "rotate(-2deg) scale(1)" },
      { transform: "rotate(-1deg) scale(1.015)" },
      { transform: "rotate(-3deg) scale(0.99)" },
      { transform: "rotate(-2deg) scale(1)" },
    ], 6000);
    run(sticker.querySelector("img"), [
      { filter: "saturate(0.55) hue-rotate(0deg) brightness(1)" },
      { filter: "saturate(0.65) hue-rotate(30deg) brightness(1.12)" },
      { filter: "saturate(0.55) hue-rotate(0deg) brightness(1)" },
    ], 4200);
    run(sticker.querySelector(".digital-id-holo-sticker-glare"), [
      { backgroundPosition: "190% 0%", opacity: 0 },
      { backgroundPosition: "50% 50%", opacity: 0.4 },
      { backgroundPosition: "-90% 100%", opacity: 0 },
    ], 3000);
  };
  queueMicrotask(() => {
    if (!sticker.isConnected) return;
    start();
    document.addEventListener("visibilitychange", start);
    globalThis.addEventListener("pageshow", start);
    preference.addEventListener("change", start);
    const observer = new MutationObserver(() => {
      if (sticker.isConnected) return;
      animations.forEach((animation) => animation.cancel());
      document.removeEventListener("visibilitychange", start);
      globalThis.removeEventListener("pageshow", start);
      preference.removeEventListener("change", start);
      observer.disconnect();
    });
    observer.observe(document.body, { childList: true, subtree: true });
  });
}
