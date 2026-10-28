import assert from "node:assert/strict";
import { dropdownPosition } from "../../web/lib/dropdown-position.js";

function fixture(
  { top = 100, viewportHeight = 800, height = 300, parent, center = false } = {},
) {
  let rect = { top, bottom: top + 44 };
  let resize;
  let disconnected = false;
  const view = Object.assign(new EventTarget(), {
    innerHeight: viewportHeight,
    innerWidth: 1000,
    visualViewport: Object.assign(new EventTarget(), {
      offsetTop: 0,
      height: viewportHeight,
    }),
    getComputedStyle: (element) => ({ overflowY: element.overflowY }),
    ResizeObserver: class {
      constructor(callback) {
        resize = callback;
      }
      observe() {}
      disconnect() {
        disconnected = true;
      }
    },
  });
  const doc = Object.assign(new EventTarget(), { defaultView: view });
  const trigger = {
    ownerDocument: doc,
    parentElement: parent,
    isConnected: true,
    getBoundingClientRect: () => ({ ...rect, left: 400 }),
  };
  const attrs = {};
  const styles = {};
  const popup = {
    hidden: false,
    offsetWidth: 540,
    get offsetHeight() {
      const limit = Number.parseFloat(styles["--dropdown-max-height"]);
      return Number.isFinite(limit) ? Math.min(height, limit) : height;
    },
    get scrollHeight() {
      return this.offsetHeight;
    },
    contains: (target) => target === popup,
    setAttribute: (name, value) => attrs[name] = value,
    style: { setProperty: (name, value) => styles[name] = value },
  };
  return {
    position: dropdownPosition(trigger, popup, { center }),
    attrs,
    styles,
    view,
    doc,
    trigger,
    move: (top) => rect = { top, bottom: top + 44 },
    resize: () => resize(),
    disconnected: () => disconnected,
  };
}

Deno.test("calendar placement: centers wide popups within a clipping modal", () => {
  const f = fixture({
    center: true,
    parent: {
      overflowY: "auto",
      clientTop: 0,
      clientHeight: 700,
      clientWidth: 600,
      getBoundingClientRect: () => ({ top: 0, left: 100 }),
    },
  });
  f.position.start();
  assert.equal(f.styles["--dropdown-max-width"], "584px");
  assert.equal(f.styles["--dropdown-left"], "-270px");
  f.position.stop();
});

Deno.test("dropdown placement: opens below when it fits and above near the bottom", () => {
  const f = fixture();
  f.position.start();
  assert.equal(f.attrs["data-placement"], "bottom");
  f.move(700);
  f.doc.dispatchEvent(new Event("scroll"));
  assert.equal(f.attrs["data-placement"], "top");
  assert.equal(f.styles["--dropdown-max-height"], "686px");
  f.position.stop();
});

Deno.test("dropdown placement: respects a scrolling modal even when the viewport has room", () => {
  const f = fixture({
    top: 450,
    height: 260,
    parent: {
      overflowY: "auto",
      clientTop: 1,
      clientHeight: 400,
      getBoundingClientRect: () => ({ top: 100 }),
    },
  });
  f.position.start();
  assert.equal(f.attrs["data-placement"], "top");
  assert.equal(f.styles["--dropdown-max-height"], "335px");
  f.position.stop();
});

Deno.test("dropdown placement: constrains tall panels and reacts to the mobile keyboard", () => {
  const f = fixture({ top: 170, viewportHeight: 400, height: 500 });
  f.position.start();
  assert.equal(f.attrs["data-placement"], "bottom");
  assert.equal(f.styles["--dropdown-max-height"], "172px");
  f.view.visualViewport.height = 260;
  f.view.visualViewport.dispatchEvent(new Event("resize"));
  assert.equal(f.attrs["data-placement"], "top");
  assert.equal(f.styles["--dropdown-max-height"], "156px");
  f.position.stop();
});

Deno.test("dropdown placement: remeasures full content on reopen and cleans up listeners", () => {
  const f = fixture({ top: 150, viewportHeight: 300, height: 350 });
  f.position.start();
  assert.equal(f.styles["--dropdown-max-height"], "136px");
  f.position.stop();
  assert(f.disconnected());
  f.view.visualViewport.height = 1000;
  f.move(700);
  f.position.start();
  assert.equal(f.attrs["data-placement"], "top");
  f.move(100);
  f.resize();
  assert.equal(f.attrs["data-placement"], "bottom");
  f.position.stop();
  const last = f.styles["--dropdown-max-height"];
  f.move(950);
  f.doc.dispatchEvent(new Event("scroll"));
  f.view.dispatchEvent(new Event("resize"));
  assert.equal(f.styles["--dropdown-max-height"], last);
});
