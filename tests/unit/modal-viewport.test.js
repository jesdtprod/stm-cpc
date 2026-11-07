import { fitModalViewport } from "../../web/lib/modal-viewport.js";

Deno.test("modal viewport follows visible screen and keyboard, removes listeners on close", () => {
  const viewport = new EventTarget();
  Object.assign(viewport, { height: 640, offsetTop: 0 });
  const view = new EventTarget();
  Object.assign(view, { visualViewport: viewport, innerHeight: 800 });
  const values = new Map();
  const dialog = new EventTarget();
  Object.assign(dialog, {
    ownerDocument: { defaultView: view },
    style: { setProperty: (key, value) => values.set(key, value) },
  });
  fitModalViewport(dialog);
  if (values.get("--modal-visible-height") !== "640px") throw new Error("Must use visible height");
  viewport.height = 320;
  viewport.offsetTop = 48;
  viewport.dispatchEvent(new Event("resize"));
  if (values.get("--modal-visible-height") !== "320px" || values.get("--modal-visible-top") !== "48px") {
    throw new Error("Must follow keyboard viewport");
  }
  dialog.dispatchEvent(new Event("close"));
  viewport.height = 700;
  viewport.dispatchEvent(new Event("resize"));
  view.dispatchEvent(new Event("resize"));
  if (values.get("--modal-visible-height") !== "320px") throw new Error("Listeners must be removed");
});

Deno.test("modal viewport falls back to window height without VisualViewport", () => {
  const view = new EventTarget();
  view.innerHeight = 568;
  const values = new Map();
  const dialog = new EventTarget();
  Object.assign(dialog, {
    ownerDocument: { defaultView: view },
    style: { setProperty: (key, value) => values.set(key, value) },
  });
  fitModalViewport(dialog);
  if (values.get("--modal-visible-height") !== "568px") throw new Error("Fallback height unavailable");
  dialog.dispatchEvent(new Event("close"));
});
