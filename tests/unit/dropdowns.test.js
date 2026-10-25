import { searchableSelect, selectField } from "../../web/ui.js";

// Small DOM fixture for component events; rendered browser checks remain separate.
function withDom(run) {
  const previous = { document: globalThis.document, Node: globalThis.Node };
  class Element {
    constructor(tag) {
      this.tag = tag;
      this.children = [];
      this.attributes = {};
      this.listeners = new Map();
      this.value = "";
    }
    setAttribute(key, value) {
      this.attributes[key] = String(value);
      if (key === "class") this.className = value;
    }
    getAttribute(key) {
      return this.attributes[key] ?? null;
    }
    get disabled() {
      return "disabled" in this.attributes;
    }
    get hidden() {
      return "hidden" in this.attributes;
    }
    set hidden(value) {
      if (value) this.attributes.hidden = "";
      else delete this.attributes.hidden;
    }
    append(...nodes) {
      for (const node of nodes) {
        node.parent = this;
        this.children.push(node);
      }
    }
    replaceChildren(...nodes) {
      this.children = [];
      this.append(...nodes);
    }
    get textContent() {
      return this.text ??
        this.children.map((node) => node.textContent).join("");
    }
    set textContent(value) {
      this.text = String(value ?? "");
      this.children = [];
    }
    addEventListener(type, handler) {
      if (!this.listeners.has(type)) this.listeners.set(type, new Set());
      this.listeners.get(type).add(handler);
    }
    removeEventListener(type, handler) {
      this.listeners.get(type)?.delete(handler);
    }
    dispatchEvent(event) {
      if (!event.target) {
        Object.defineProperty(event, "target", { value: this });
      }
      for (const handler of this.listeners.get(event.type) ?? []) {
        handler(event);
      }
      if (event.bubbles && !event.cancelBubble) {
        this.parent?.dispatchEvent(event);
      }
      return !event.defaultPrevented;
    }
    contains(node) {
      return this === node ||
        this.children.some((child) => child.contains(node));
    }
    matches(selector) {
      return selector.split(",").some((part) => {
        if (part.includes(":not(:disabled)") && this.disabled) return false;
        const simple = part.trim().replace(":not(:disabled)", "");
        return simple.startsWith(".")
          ? String(this.className ?? "").split(" ").includes(simple.slice(1))
          : this.tag === simple;
      });
    }
    querySelectorAll(selector) {
      return this.children.flatMap((
        child,
      ) => [
        ...(child.matches(selector) ? [child] : []),
        ...child.querySelectorAll(selector),
      ]);
    }
    querySelector(selector) {
      return this.querySelectorAll(selector)[0] ?? null;
    }
    focus() {
      globalThis.document.activeElement = this;
    }
    click() {
      if (!this.disabled) {
        this.dispatchEvent(new Event("click", { bubbles: true }));
      }
    }
    scrollIntoView() {}
  }
  const document = new Element("document");
  document.createElement = document.createElementNS = (...args) =>
    new Element(args.at(-1));
  document.createTextNode = (text) => {
    const node = new Element("text");
    node.textContent = text;
    return node;
  };
  globalThis.document = document;
  globalThis.Node = Element;
  try {
    run(document);
  } finally {
    for (const key of ["document", "Node"]) {
      if (previous[key] === undefined) delete globalThis[key];
      else globalThis[key] = previous[key];
    }
  }
}
const assert = (condition, message) => {
  if (!condition) throw new Error(message);
};
const options = [{ value: "pending", label: "Waiting for approval" }, {
  value: "active",
  label: "Active",
}];

Deno.test("dropdown: shared select is searchable and emits native form change values", () =>
  withDom((document) => {
    let changed;
    const field = selectField({
      id: "status",
      options,
      value: "pending",
      onChange: (event) => changed = event.target.value,
    });
    const trigger = field.querySelector(".searchable-select-trigger");
    const popup = field.querySelector(".searchable-select-dropdown");
    const search = field.querySelector("input");
    assert(popup.hidden, "Popup must start closed");
    trigger.click();
    assert(
      !popup.hidden && document.activeElement === search,
      "Opening must focus option search",
    );
    search.value = "active";
    search.dispatchEvent(new Event("input"));
    const items = field.querySelectorAll(".searchable-select-item");
    assert(
      items.length === 1 && items[0].textContent === "Active",
      "Search must filter options",
    );
    items[0].click();
    assert(
      changed === "active" && field.value === "active",
      "Form callback and component value must agree",
    );
    assert(
      popup.hidden && document.activeElement === trigger,
      "Selection must close and restore focus",
    );
    assert(
      document.listeners.get("pointerdown").size === 0,
      "Closed controls must remove outside listeners",
    );
  }));

Deno.test("dropdown: count updates and programmatic selection stay synchronized without emitting changes", () =>
  withDom(() => {
    let changes = 0;
    const field = searchableSelect({
      id: "status",
      options,
      value: "active",
      onChange: () => changes++,
    });
    field.setOptions(
      options.map((option) => ({ ...option, label: `${option.label} (2)` })),
    );
    assert(
      field.querySelector(".searchable-select-text").textContent ===
        "Active (2)",
      "Count updates must refresh trigger text",
    );
    field.value = "pending";
    assert(
      field.querySelector("select").value === "pending",
      "KPI filters must update the form value",
    );
    assert(
      field.querySelector(".searchable-select-text").textContent ===
        "Waiting for approval (2)",
      "KPI filters must update the trigger",
    );
    assert(
      changes === 0,
      "Programmatic synchronization must not reload the page",
    );
  }));

Deno.test("dropdown: keyboard skips disabled options and Escape restores focus", () =>
  withDom((document) => {
    const field = searchableSelect({
      id: "status",
      options: [options[0], {
        value: "blocked",
        label: "Unavailable",
        disabled: true,
      }, options[1]],
    });
    const wrap = field.querySelector(".searchable-select-wrap");
    const trigger = field.querySelector(".searchable-select-trigger");
    const key = (value) => {
      const event = new Event("keydown", { cancelable: true });
      Object.defineProperty(event, "key", { value });
      wrap.dispatchEvent(event);
    };
    trigger.focus();
    key("ArrowDown");
    assert(
      document.activeElement.textContent === "Waiting for approval",
      "First arrow must focus the first enabled option",
    );
    key("ArrowDown");
    assert(
      document.activeElement.textContent === "Active",
      "Navigation must skip disabled options",
    );
    key("Escape");
    assert(
      field.querySelector(".searchable-select-dropdown").hidden &&
        document.activeElement === trigger,
      "Escape must close and restore focus",
    );
  }));
