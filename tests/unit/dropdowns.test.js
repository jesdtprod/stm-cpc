import {
  dataTable,
  dateControl,
  h,
  iconButton,
  searchableSelect,
  searchControl,
  selectControl,
  selectField,
} from "../../web/ui.js";

// Small DOM fixture for component events; rendered browser checks remain separate.
function withDom(run) {
  const keys = ["document", "Node", "HTMLSelectElement", "HTMLInputElement"];
  const previous = Object.fromEntries(
    keys.map((key) => [key, globalThis[key]]),
  );
  class Element {
    constructor(tag) {
      this.tag = tag;
      this.children = [];
      this.attributes = {};
      this.listeners = new Map();
      this._value = undefined;
      this.style = {
        setProperty: (key, value) => this.attributes[key] = value,
      };
    }
    setAttribute(key, value) {
      this.attributes[key] = String(value);
      if (key === "class") this.className = value;
    }
    getAttribute(key) {
      return this.attributes[key] ?? null;
    }
    removeAttribute(key) {
      delete this.attributes[key];
    }
    get options() {
      return this.children.filter((child) => child.tag === "option");
    }
    get value() {
      if (this.tag === "option") {
        return this.attributes.value ?? this.textContent;
      }
      if (this.tag === "select") {
        if (this._value !== undefined) {
          return this.options.some((o) => o.value === this._value)
            ? this._value
            : "";
        }
        return (this.options.find((o) => "selected" in o.attributes) ??
          this.options[0])?.value ?? "";
      }
      return this._value ?? this.attributes.value ?? "";
    }
    set value(value) {
      this._value = String(value);
    }
    set disabled(value) {
      if (value) this.attributes.disabled = "";
      else delete this.attributes.disabled;
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
  globalThis.HTMLSelectElement = Element;
  globalThis.HTMLInputElement = Element;
  try {
    run(document);
  } finally {
    for (const key of keys) {
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

Deno.test("dropdown adapter: dependent options, value, disabled and change handlers stay usable", () =>
  withDom(() => {
    let changes = 0;
    const native = selectControl(
      { id: "district", onChange: () => changes++ },
      h("option", { value: "a" }, "District A"),
    );
    const parent = h("div", {}, native);
    const trigger = parent.querySelector(".searchable-select-trigger");
    native.replaceChildren(h("option", { value: "b" }, "District B"));
    native.value = "b";
    assert(
      parent.querySelector(".searchable-select-text").textContent ===
        "District B",
      "Dependent options must refresh the visible selection",
    );
    native.disabled = true;
    assert(trigger.disabled, "Native disabled state must disable the trigger");
    native.disabled = false;
    trigger.click();
    parent.querySelector(".searchable-select-item").click();
    assert(
      changes === 1 && native.value === "b",
      "Existing native change callback must run exactly once",
    );
  }));

Deno.test("search: clear visibility follows typing and programmatic resets", () =>
  withDom(() => {
    let changes = 0;
    const input = searchControl({ class: "input", onInput: () => changes++ });
    const parent = h("div", {}, input);
    const clear = parent.querySelector(".search-box-clear");
    assert(clear.hidden, "Empty searches must hide clear");
    input.value = "Member";
    input.dispatchEvent(new Event("input"));
    assert(!clear.hidden, "Text must reveal clear");
    clear.click();
    assert(
      input.value === "" && clear.hidden && changes === 2,
      "Clear must reset and notify once",
    );
    input.value = "Again";
    input.value = "";
    assert(clear.hidden, "Reset must synchronize clear visibility");
  }));

Deno.test("table: loading and ready rows share geometry and semantic alignment", () =>
  withDom(() => {
    const schema = {
      columns: [
        { key: "member", label: "Member" },
        { key: "amount", label: "Amount", kind: "money" },
        {
          key: "actions",
          label: "Action",
          actionCount: 3,
          render: () =>
            [1, 2, 3].map(() => iconButton({ label: "View", icon: "info" })),
        },
      ],
    };
    const loading = dataTable({ schema, state: "loading", rows: [] });
    const ready = dataTable({
      schema,
      state: "ready",
      rows: [{ member: "Sample", amount: 100 }],
    });
    assert(
      loading.querySelector(".tbl").attributes["--tbl-grid"] ===
        ready.querySelector(".tbl").attributes["--tbl-grid"],
      "Loading must reserve the final column tracks",
    );
    assert(
      ready.querySelectorAll(".right").length === 2,
      "Money heading and value must both align right",
    );
    assert(
      ready.querySelectorAll(".tbl-actions").length === 2,
      "Action heading and value must share alignment",
    );
  }));

Deno.test("dropdown: unnamed controls receive unique accessible IDs", () =>
  withDom(() => {
    const first = searchableSelect({ options });
    const second = searchableSelect({ options });
    assert(
      first.querySelector(".searchable-select-options").getAttribute("id") !==
        second.querySelector(".searchable-select-options").getAttribute("id"),
      "Every listbox must have a distinct ID",
    );
  }));

Deno.test("date adapter: native name, constraints and value remain synchronized", () =>
  withDom(() => {
    const date = dateControl({
      id: "first-day",
      name: "starts_on",
      value: "2030-02-01",
      required: true,
      min: "2030-01-01",
    });
    const parent = h("div", {}, date);
    assert(
      date.getAttribute("name") === "starts_on" &&
        date.getAttribute("required") !== null,
      "Date form contract must be preserved",
    );
    assert(
      date.getAttribute("min") === "2030-01-01",
      "Native constraints must be retained",
    );
    date.value = "2030-02-03";
    assert(
      parent.querySelector(".calendar-drop-val").textContent === date.value,
      "Programmatic changes must update the calendar display",
    );
    date.disabled = true;
    assert(
      parent.querySelector(".calendar-drop-trigger").disabled,
      "Disabled date must disable its trigger",
    );
  }));
