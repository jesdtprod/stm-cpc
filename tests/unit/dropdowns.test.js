import {
  dataTable,
  dateControl,
  dateTimeControl,
  dropdownMenu,
  h,
  iconButton,
  inputWithIcon,
  memberHero,
  pagination,
  searchableSelect,
  searchControl,
  selectControl,
  selectField,
  switchToggle,
  tableFilter,
  timeControl,
} from "../../web/ui.js";
import { createRanksPages } from "../../web/pages-ranks.js";
import { createScoringPages } from "../../web/pages-scoring.js";
import { createStaffPages } from "../../web/pages-staff.js";
import { createBookingAdminPages } from "../../web/pages-bookings-admin.js";
import { createMemberEventsPages } from "../../web/pages-events-member.js";
import { createRankingPages } from "../../web/pages-ranking.js";
import { clearAuth, setAuth } from "../../web/lib/permissions.js";

// Small DOM fixture for component events; rendered browser checks remain separate.
function withDom(run) {
  const keys = [
    "document",
    "Node",
    "HTMLSelectElement",
    "HTMLInputElement",
    "requestAnimationFrame",
  ];
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
    get classList() {
      return {
        add: (name) => {
          this.className = [
            ...new Set(`${this.className ?? ""} ${name}`.trim().split(/\s+/)),
          ].join(" ");
        },
        remove: (name) => {
          this.className = (this.className ?? "").split(/\s+/).filter((value) =>
            value !== name
          ).join(" ");
        },
      };
    }
    prepend(...nodes) {
      for (const node of [...nodes].reverse()) {
        node.parent = this;
        this.children.unshift(node);
      }
    }
    appendChild(node) {
      this.append(node);
      return node;
    }
    setAttribute(key, value) {
      this.attributes[key] = String(value);
      if (key === "class") this.className = value;
    }
    getAttribute(key) {
      return this.attributes[key] ?? null;
    }
    hasAttribute(key) {
      return key in this.attributes;
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
        const child = typeof node === "string"
          ? document.createTextNode(node)
          : node;
        child.parent = this;
        this.children.push(child);
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
    showModal() {
      this.setAttribute("open", "");
    }
    close() {
      this.removeAttribute("open");
      this.dispatchEvent(new Event("close"));
    }
    remove() {
      if (this.parent) {
        this.parent.children = this.parent.children.filter((child) =>
          child !== this
        );
      }
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
  document.body = new Element("body");
  document.append(document.body);
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
  globalThis.requestAnimationFrame = (callback) => callback();
  const restore = () => {
    for (const key of keys) {
      if (previous[key] === undefined) delete globalThis[key];
      else globalThis[key] = previous[key];
    }
  };
  try {
    const result = run(document);
    if (result?.then) return result.finally(restore);
    restore();
    return result;
  } catch (error) {
    restore();
    throw error;
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

Deno.test("datetime adapter: native name, constraints and value remain synchronized with time pane", () =>
  withDom(() => {
    const dt = dateTimeControl({
      id: "ev-opens",
      name: "opens_at",
      value: "2030-02-01T09:30",
      required: true,
    });
    const parent = h("div", {}, dt);
    assert(
      dt.getAttribute("name") === "opens_at" &&
        dt.getAttribute("required") !== null,
      "Datetime form contract must be preserved",
    );
    assert(
      parent.querySelector(".calendar-drop-val").textContent.includes("2030"),
      "Calendar display must reflect formatted date",
    );
    assert(
      parent.querySelector(".calendar-drop-val").textContent.includes(
        "09:30 AM",
      ),
      "Calendar display must reflect formatted time",
    );
    const trigger = parent.querySelector(".calendar-drop-trigger");
    trigger.click();
    assert(
      !parent.querySelector(".calendar-popover").hidden,
      "Popover must open",
    );
    assert(
      parent.querySelector(".calendar-time-pane") !== null,
      "Time pane must be present",
    );
  }));

Deno.test("time adapter: native name, constraints and value remain synchronized with time-only popover", () =>
  withDom(() => {
    const t = timeControl({
      id: "hr-open",
      name: "opens",
      value: "08:00",
      required: true,
    });
    const parent = h("div", {}, t);
    assert(
      t.getAttribute("name") === "opens" &&
        t.getAttribute("required") !== null,
      "Time form contract must be preserved",
    );
    assert(
      parent.querySelector(".calendar-drop-val").textContent.includes(
        "08:00 AM",
      ),
      "Calendar display must reflect formatted time",
    );
    t.value = "21:00";
    assert(
      parent.querySelector(".calendar-drop-val").textContent.includes(
        "09:00 PM",
      ),
      "Programmatic time change must update the display to PM format",
    );
    const trigger = parent.querySelector(".calendar-drop-trigger");
    trigger.click();
    assert(
      !parent.querySelector(".calendar-popover").hidden,
      "Popover must open",
    );
    assert(
      parent.querySelector(".calendar-popover").className.includes(
        "is-time-only",
      ),
      "Popover must be marked is-time-only",
    );
    assert(
      parent.querySelector(".calendar-main") === null,
      "Calendar month main view must NOT be present in time-only mode",
    );
  }));

Deno.test("table search: filters visible values, preserves actions, and clears no-results", () =>
  withDom(() => {
    let viewed = 0;
    const schema = {
      columns: [
        {
          key: "name",
          label: "Category",
          render: (r) =>
            h("span", {}, r.name, h("span", { class: "sub" }, r.code)),
        },
        {
          key: "actions",
          label: "Action",
          actionCount: 1,
          render: () =>
            iconButton({
              icon: "eye",
              label: "View hidden label",
              onClick: () => viewed++,
            }),
        },
      ],
    };
    const table = dataTable({
      schema,
      rows: [{ name: "D\u00e9butant", code: "beginner" }, {
        name: "Advanced",
        code: "advanced",
      }],
      ariaLabel: "Categories",
    });
    const search = table.querySelector(".data-grid-toolbar").querySelector(
      "input",
    );
    const records = table.querySelector(".tbl-body").querySelectorAll(
      ".tbl-row",
    );
    search.value = "DEBUTANT beginner";
    search.dispatchEvent(new Event("input"));
    assert(
      !records[0].hidden && records[1].hidden,
      "Search must match all words across displayed values, ignoring case and accents",
    );
    records[0].querySelector("button").click();
    assert(viewed === 1, "Filtering must preserve existing action handlers");
    search.value = "hidden label";
    search.dispatchEvent(new Event("input"));
    assert(
      records.every((row) => row.hidden),
      "Action labels must not count as searchable data",
    );
    assert(
      !table.querySelector(".tbl-search-empty").hidden,
      "No matches must have a distinct empty state",
    );
    table.querySelector(".search-box-clear").click();
    assert(
      records.every((row) => !row.hidden) &&
        table.querySelector(".tbl-search-empty").hidden,
      "Clearing search must restore the records",
    );
  }));

Deno.test("table search: retains page-scoped query through refresh without duplicating external search", () =>
  withDom(() => {
    const searchState = {};
    const config = {
      schema: { columns: [{ key: "name", label: "Name" }] },
      rows: [{ name: "Beginner" }, { name: "Advanced" }],
      ariaLabel: "Categories",
      searchState,
    };
    const first = dataTable(config);
    const input = first.querySelector(".data-grid-toolbar").querySelector(
      "input",
    );
    input.value = "Advanced";
    input.dispatchEvent(new Event("input"));
    const refreshed = dataTable(config);
    assert(
      refreshed.querySelector("input").value === "Advanced",
      "Refresh must retain the page query",
    );
    assert(
      refreshed.querySelector(".tbl-body").querySelectorAll(".tbl-row")[0]
        .hidden,
      "Refresh must apply the retained filter",
    );
    assert(
      !dataTable({ ...config, searchable: false }).querySelector(
        ".data-grid-toolbar",
      ),
      "An external list search must not get a second search box",
    );
    assert(
      dataTable({ ...config, state: "loading" }).querySelector("input")
        .disabled,
      "Loading tables must keep search disabled",
    );
  }));

Deno.test("grid controls: search and status badges stay outside the table panel", () =>
  withDom(() => {
    let selected;
    const filter = tableFilter({
      activeId: "active",
      tabs: [{ id: "active", label: "Active", badge: 2 }, {
        id: "deleted",
        label: "Deleted",
        badge: 0,
      }],
      onChange: (value) => selected = value,
    });
    const view = dataTable({
      schema: { columns: [{ key: "name", label: "Name" }] },
      rows: [{ name: "Sample" }],
      filter,
    });
    const panel = view.querySelector(".data-grid");
    const toolbar = view.querySelector(".data-grid-toolbar");
    assert(
      panel && toolbar && !panel.contains(toolbar),
      "Controls must be outside the bordered table panel",
    );
    assert(
      toolbar.contains(filter),
      "Status badges must share the search toolbar",
    );
    assert(
      !filter.querySelector("select"),
      "Status badges replace the dropdown",
    );
    assert(
      filter.querySelectorAll(".badge")[1].textContent === "0",
      "Empty categories must show zero",
    );
    filter.querySelectorAll("button")[1].click();
    assert(
      selected === "deleted",
      "Status selection must keep its original callback value",
    );
    assert(
      filter.querySelectorAll("button")[1].getAttribute("aria-pressed") ===
        "true",
      "Selected status must be accessible",
    );
    filter.setOptions([{ value: "active", label: "Active", badge: 3 }, {
      value: "deleted",
      label: "Deleted",
      badge: 1,
    }]);
    assert(filter.value === "deleted", "Count refresh must preserve selection");
    filter.setOptions([
      { value: "active", label: "Active" },
      { value: "deleted", label: "Deleted", badge: null },
      { value: "pending", label: "Pending", badge: "—" },
    ]);
    assert(
      filter.querySelectorAll(".badge").every((count) =>
        count.textContent === "0"
      ),
      "Missing, null and unavailable counts must all display zero",
    );
    filter.value = "active";
    assert(
      filter.querySelectorAll("button")[0].getAttribute("aria-pressed") ===
        "true",
      "Programmatic selection must update badges",
    );
  }));

Deno.test("booking actions: approval, rejection and cancellation open their confirmation dialogs", () =>
  withDom(async (document) => {
    setAuth({
      signedIn: true,
      grants: ["bookings.approve", "bookings.cancel_any"].map((code) => ({
        code,
      })),
    });
    try {
      const row = {
        id: "01K00000000000000000000000",
        doc_no: "BK-2099-00001",
        court_id: "court-test",
        court_name_snapshot: "Test Court",
        during: '["2099-01-01 01:00:00+00","2099-01-01 02:00:00+00")',
        status: "pending_approval",
        price_snapshot: 0,
        requester: {
          member_no: "CPC-2099-00001",
          persons: { display_name: "Test Member" },
        },
      };
      let reads = 0;
      let writes = 0;
      const api = {
        read: () => Promise.resolve(reads++ === 0 ? [row] : []),
        newKey: () => "01K00000000000000000000001",
        rpc: () => {
          writes++;
        },
      };
      const page = createBookingAdminPages({ api, client: {} }).bookingsPage();
      document.body.append(page);
      await new Promise((resolve) => setTimeout(resolve, 0));
      for (
        const [action, title] of [
          ["Approve", "Approve This Booking"],
          ["Reject", "Reject This Request"],
          ["Cancel", "Cancel This Booking"],
        ]
      ) {
        const button = page.querySelectorAll("button").find((button) =>
          button.getAttribute("aria-label")?.startsWith(
            `${action} ${row.doc_no}`,
          )
        );
        assert(button, `${action} action must be available`);
        button.click();
        const dialog = document.body.querySelector("dialog");
        assert(
          dialog?.getAttribute("open") !== null,
          `${action} must open its dialog`,
        );
        assert(
          dialog.querySelector("h2").textContent === title,
          `${action} must show the correct confirmation`,
        );
        assert(
          dialog.querySelector(".member-avatar").textContent === "TM",
          "Member initials must render without a photo",
        );
        if (action !== "Approve") {
          assert(
            dialog.querySelector("textarea").getAttribute("required") !== null,
            "Rejection and cancellation must require a reason",
          );
        }
        dialog.close();
      }
      assert(
        writes === 0,
        "Opening and dismissing dialogs must not change bookings",
      );
    } finally {
      clearAuth();
    }
  }));

Deno.test("member events: one shared search filters divisions and retains registration controls", () =>
  withDom(async (document) => {
    const api = {
      read: () => Promise.resolve([]),
      rpc: () =>
        Promise.resolve([{
          id: "fake-event",
          name: "Sample Open",
          starts_on: "2099-01-01",
          ends_on: "2099-01-01",
          divisions: [
            { id: "beginner", name: "Beginner", format: "singles", taken: 0 },
            { id: "advanced", name: "Advanced", format: "doubles", taken: 1 },
          ],
        }]),
    };
    const page = createMemberEventsPages({
      api,
      client: {},
      session: { getState: () => ({}) },
    }).eventsPage();
    document.body.append(page);
    await new Promise((resolve) => setTimeout(resolve, 0));
    const search = page.querySelectorAll("input").find((input) =>
      input.getAttribute("id") === "member-events-search"
    );
    assert(
      page.querySelectorAll("input").length === 1,
      "Events must have one shared search",
    );
    search.value = "Advanced";
    search.dispatchEvent(new Event("input"));
    assert(
      page.querySelector(".tbl-body").textContent.includes("Advanced"),
      "Search must retain matching divisions",
    );
    assert(
      !page.querySelector(".tbl-body").textContent.includes("Beginner"),
      "Search must exclude other divisions",
    );
    assert(
      page.querySelectorAll("button").some((button) =>
        button.getAttribute("aria-label") === "Register"
      ),
      "Filtered divisions must retain registration actions",
    );
    search.value = "no-match";
    search.dispatchEvent(new Event("input"));
    assert(
      page.textContent.includes("No matching events"),
      "Search must explain empty results",
    );
    const buttons = page.querySelector(".member-status-badges")
      .querySelectorAll("button");
    buttons[1].click();
    assert(
      page.querySelector(".member-status-badges").querySelectorAll("button")[1]
        .getAttribute("aria-pressed") === "true",
      "Registration view must remain selectable",
    );
  }));

Deno.test("ranking identity: actual CPC number appears below the player name without invented IDs", () =>
  withDom(async (document) => {
    const page = createRankingPages({
      api: {
        read: () => Promise.resolve([]),
        rpc: () =>
          Promise.resolve([
            {
              member_id: "fake-member-a",
              member_no: "CPC-2026-99991",
              since: "2026-10-27T00:00:00Z",
              display_name: "Sample Player",
              category_name: "Beginner",
              rank_name: "Beginner Low",
            },
            {
              member_id: "fake-member-b",
              member_no: null,
              since: "2026-10-27T00:00:00Z",
              display_name: "Another Player",
              category_name: "Beginner",
              rank_name: "Beginner Low",
            },
          ]),
      },
    }).rankingPage();
    document.body.append(page);
    await new Promise((resolve) => setTimeout(resolve, 0));
    const identities = page.querySelectorAll(".ranking-player-meta");
    assert(
      identities[0].children[0].textContent === "Sample Player",
      "Name must appear first",
    );
    assert(
      identities[0].children[1].textContent === "CPC-2026-99991",
      "Actual member number must appear beneath the name",
    );
    assert(
      !identities[1].querySelector(".ranking-player-id"),
      "Missing member numbers must never be fabricated from database IDs",
    );
  }));

Deno.test("ranking photos: signed private images replace icons and missing photos use initials", () =>
  withDom(async (document) => {
    const photoPath = "fake-org/fake-profile/photo.jpg";
    const page = createRankingPages({
      api: {
        read: () => Promise.resolve([]),
        rpc: (name) =>
          Promise.resolve(
            name === "ranking_photos"
              ? [{ member_id: "fake-photo-member", avatar_path: photoPath }]
              : [
                {
                  member_id: "fake-photo-member",
                  display_name: "Sample Photo",
                  category_name: "Beginner",
                  rank_name: "Low",
                  since: "2026-10-27T00:00:00Z",
                },
                {
                  member_id: "fake-no-photo",
                  display_name: "Sample Initials",
                  category_name: "Beginner",
                  rank_name: "Low",
                  since: "2026-10-27T00:00:00Z",
                },
              ],
          ),
      },
      client: {
        storage: {
          from: (bucket) => {
            assert(
              bucket === "avatars",
              "Photos must use the private avatar bucket",
            );
            return {
              createSignedUrls: (paths) => {
                assert(
                  paths[0] === photoPath,
                  "Only ranking photo paths should be signed",
                );
                return Promise.resolve({
                  data: [{
                    path: photoPath,
                    signedUrl: "https://example.invalid/signed-photo",
                  }],
                });
              },
            };
          },
        },
      },
    }).rankingPage();
    document.body.append(page);
    await new Promise((resolve) => setTimeout(resolve, 0));
    const photos = page.querySelectorAll(".ranking-player-photo");
    assert(
      photos[0].querySelector("img").src ===
        "https://example.invalid/signed-photo",
      "Player photo must use the signed image link",
    );
    assert(
      photos[1].textContent === "SI",
      "A player without a photo must show initials",
    );
    assert(
      !page.querySelector(".mobile-record-icon"),
      "Player rows must no longer show the generic ranking icon",
    );
  }));

Deno.test("icon inputs: preserve native validation attributes and existing handlers", () =>
  withDom(() => {
    let changes = 0;
    const input = h("input", {
      id: "court-name",
      name: "name",
      required: true,
      maxlength: 60,
      onInput: () => changes++,
    });
    const view = inputWithIcon(input, "grid");
    assert(
      view.querySelector("input") === input,
      "Icon decoration must retain the native control",
    );
    assert(
      input.getAttribute("name") === "name" &&
        input.getAttribute("required") !== null,
      "Form contract must be unchanged",
    );
    assert(
      view.querySelector(".input-affix").getAttribute("aria-hidden") === "true",
      "Decorative icon must not replace the input label",
    );
    input.value = "Court 1";
    input.dispatchEvent(new Event("input"));
    assert(
      changes === 1,
      "Existing code generation handler must still receive input",
    );
  }));

Deno.test("switch: supports the existing indoor field name without changing other switches", () =>
  withDom(() => {
    const indoor = switchToggle({
      id: "ct-indoor",
      name: "indoor",
      label: "Indoor court",
      checked: true,
    });
    const standard = switchToggle({
      id: "notifications",
      label: "Notifications",
    });
    assert(
      indoor.querySelector("input").getAttribute("name") === "indoor",
      "Court submission must keep its indoor field name",
    );
    assert(
      indoor.querySelector("input").getAttribute("checked") !== null,
      "Editing must retain indoor state",
    );
    assert(
      standard.querySelector("input").getAttribute("name") === "notifications",
      "Existing switches must retain default names",
    );
  }));

Deno.test("grid pagination: filters the full list before paging and retains the selected page on refresh", () =>
  withDom(() => {
    const searchState = {};
    const config = {
      schema: { columns: [{ key: "name", label: "Court" }] },
      rows: Array.from({ length: 5 }, (_, i) => ({ name: `Court ${i + 1}` })),
      pageSize: 2,
      searchState,
      ariaLabel: "Courts",
    };
    const view = dataTable(config);
    const rows = view.querySelector(".tbl-body").querySelectorAll(".tbl-row");
    const findButton = (root, label) =>
      root.querySelectorAll("button").find((button) =>
        button.getAttribute("aria-label") === label
      );
    assert(
      rows.filter((row) => !row.hidden).length === 2,
      "Only the first page should be visible",
    );
    findButton(view, "Next Page").click();
    assert(
      rows[0].hidden && !rows[2].hidden && !rows[3].hidden,
      "Next must show the following records",
    );
    const refreshed = dataTable(config);
    assert(
      refreshed.querySelector(".tbl-body").querySelectorAll(".tbl-row")[0]
        .hidden,
      "Refresh must preserve the selected page",
    );
    const search = view.querySelector(".data-grid-toolbar").querySelector(
      "input",
    );
    search.value = "Court 5";
    search.dispatchEvent(new Event("input"));
    assert(
      !rows[4].hidden && rows.slice(0, 4).every((row) => row.hidden),
      "Search must include later pages and reset to page one",
    );
    assert(
      findButton(view, "Next Page").disabled &&
        findButton(view, "Previous Page").disabled,
      "A single search result must disable both navigation buttons",
    );
  }));

Deno.test("calendar: full seven-column month and single-date selection remain separate from range styling", () =>
  withDom((document) => {
    const native = dateControl({ id: "schedule-day", value: "2030-02-10" });
    const view = h("div", {}, native);
    const trigger = view.querySelector(".calendar-drop-trigger");
    trigger.click();
    assert(
      !view.querySelector(".calendar-popover").hidden,
      "Calendar must open",
    );
    assert(
      view.querySelectorAll(".calendar-weekday").length === 7,
      "Weekday row must retain seven columns",
    );
    assert(
      view.querySelectorAll(".calendar-nav-btn").length === 2,
      "Both month navigation controls must be present",
    );
    assert(
      view.querySelector(".calendar-month-btn").textContent === "February 2030",
      "Month and year must stay in one header control",
    );
    const selected = view.querySelector(".is-selected");
    assert(
      selected.textContent === "10" && !selected.matches(".is-range-start"),
      "A single selected date must have full rounded corners",
    );
    assert(
      view.querySelector(".calendar-presets").querySelectorAll("button")
        .length === 3,
      "Preset controls must retain all three actions",
    );
    const escape = new Event("keydown", { cancelable: true });
    Object.defineProperty(escape, "key", { value: "Escape" });
    document.dispatchEvent(escape);
    assert(
      view.querySelector(".calendar-popover").hidden,
      "Escape must close the calendar",
    );
  }));

Deno.test("ranks page: search keeps full ladder context and movement uses the original ordered IDs", () =>
  withDom(async () => {
    const cats = [
      {
        id: "category-a",
        code: "beginner",
        name: "Beginner",
        is_active: true,
        sort_order: 1,
        ladders: [{
          id: "ladder-a",
          overflow: "chain",
          version: 1,
          ranks: [
            {
              id: "low",
              name: "Beginner Low",
              code: "beginner-low",
              sort_order: 0,
              is_starting: true,
            },
            {
              id: "high",
              name: "Beginner High",
              code: "beginner-high",
              sort_order: 1,
            },
            {
              id: "elite",
              name: "Beginner Elite",
              code: "beginner-elite",
              sort_order: 2,
            },
          ],
        }],
      },
      {
        id: "category-b",
        code: "novice",
        name: "Novice",
        is_active: true,
        sort_order: 2,
        ladders: [],
      },
    ];
    const rules = [{
      id: "rule-a",
      name: "Reward finalists",
      priority: 1,
      conditions: { placement: 1 },
      action: "up",
      levels: 1,
      is_active: true,
    }];
    let reads = 0;
    const calls = [];
    const api = {
      read: () => Promise.resolve(reads++ % 2 === 0 ? cats : rules),
      newKey: () => "01K00000000000000000000000",
      // Keep the mutation at the API boundary so this test checks the submitted order.
      rpc: (name, args) => {
        calls.push({ name, args });
        return new Promise(() => {});
      },
    };
    const page = createRanksPages({ api, getOrgId: () => "org-test" })
      .ranksPage();
    await new Promise((resolve) => setTimeout(resolve, 0));
    assert(
      page.querySelectorAll(".ladder-card").length === 2,
      "Both categories should initially appear",
    );
    const search = page.querySelectorAll("input").find((input) =>
      input.getAttribute("id") === "ranks-search"
    );
    search.value = "Low";
    search.dispatchEvent(new Event("input"));
    assert(
      page.querySelectorAll(".ladder-card").length === 1,
      "Search must find the matching category",
    );
    assert(
      page.querySelectorAll(".rank-item").length === 3,
      "Search must retain all ranks for reorder context",
    );
    page.querySelectorAll("button").find((button) =>
      button.getAttribute("aria-label") === "Move Beginner Low up"
    ).click();
    assert(
      calls[0].name === "reorder_ranks" &&
        calls[0].args.p_rank_ids.join(",") === "high,low,elite",
      "Movement must submit the full correctly reordered ladder",
    );
    const view = page.querySelectorAll("div").find((element) =>
      element.getAttribute("id") === "ranks-view"
    );
    view.querySelectorAll("button")[1].click();
    assert(
      page.querySelector(".tbl") && page.querySelector(".pager"),
      "Rules view must use the shared table and pagination",
    );
    assert(
      search.value === "",
      "Changing views must reset the unrelated search",
    );
  }));

Deno.test("ranks page: New rule opens its dialog directly without changing the active view", () =>
  withDom(async (document) => {
    const api = {
      read: () => Promise.resolve([]),
      newKey: () => "01K00000000000000000000000",
    };
    const page = createRanksPages({ api, getOrgId: () => "org-test" })
      .ranksPage();
    document.body.append(page);
    await new Promise((resolve) => setTimeout(resolve, 0));
    const view = page.querySelectorAll("div").find((element) =>
      element.getAttribute("id") === "ranks-view"
    );
    assert(view.value === "ladders", "Start in the ladder view");
    page.querySelectorAll("button").find((button) =>
      button.textContent === "New Rule"
    ).click();
    const dialog = document.body.querySelector("dialog");
    assert(
      dialog && dialog.getAttribute("open") !== null,
      "New rule must open a modal",
    );
    assert(
      dialog.querySelector("h2").textContent === "New Rule",
      "New rule must open its creation form",
    );
    assert(
      view.value === "ladders",
      "Opening a creation form must not redirect to the rule list",
    );
    dialog.close();
    assert(
      view.value === "ladders" && !document.body.querySelector("dialog"),
      "Cancelling must close the form and retain the original view",
    );
  }));

Deno.test("pagination: empty lists have no visible footer or controls", () =>
  withDom(() => {
    const pager = pagination({ page: 1, total: 0, onPage: () => {} });
    assert(
      pager.hidden && pager.querySelectorAll("button").length === 0,
      "No-record lists must hide the entire pagination footer",
    );
    const grid = dataTable({
      schema: { columns: [{ key: "name", label: "Name" }] },
      rows: [],
      pageSize: 10,
    });
    assert(
      grid.querySelector(".pager").hidden,
      "The shared grid must also hide empty pagination",
    );
    assert(
      grid.querySelector(".pager").textContent === "",
      "No records text must not remain in a redundant footer",
    );
  }));

Deno.test("pagination: shared default is ten records with correct range and navigation", () =>
  withDom(() => {
    let page;
    const pager = pagination({
      page: 1,
      total: 80,
      onPage: (next) => page = next,
    });
    assert(
      !pager.hidden &&
        pager.querySelector(".pager-range").textContent.includes("1\u201310"),
      "Default first page must cover ten records",
    );
    assert(
      pager.querySelector(".pager-size").textContent === "10 records per page",
      "Default page size must be explicit",
    );
    pager.querySelectorAll("button").find((button) =>
      button.getAttribute("aria-label") === "Next Page"
    ).click();
    assert(page === 2, "Next page must retain the shared navigation callback");
    const second = pagination({ page: 2, total: 80, onPage: () => {} });
    assert(
      second.querySelector(".pager-range").textContent.includes("11\u201320"),
      "Second page must use the same ten-record size",
    );
  }));

Deno.test("scoring modal: shared sections preserve scoring fields, limits and tiebreak defaults", () =>
  withDom(async (document) => {
    const api = {
      read: () => Promise.resolve([]),
      newKey: () => "01K00000000000000000000000",
    };
    const page = createScoringPages({ api, getOrgId: () => "org-test" })
      .scoringPage();
    document.body.append(page);
    await new Promise((resolve) => setTimeout(resolve, 0));
    page.querySelectorAll("button").find((button) =>
      button.textContent === "New Scoring Rule"
    ).click();
    const modal = document.body.querySelector("dialog");
    assert(
      modal?.getAttribute("open") !== null,
      "New scoring rule must open its modal",
    );
    assert(
      modal.querySelectorAll(".form-section").length === 2,
      "Scoring and tiebreak settings must have distinct groups",
    );
    assert(
      modal.querySelectorAll(".input-affix").length === 10,
      "Every scoring field must retain its icon wrapper",
    );
    const find = (name) =>
      modal.querySelectorAll("input, select").find((input) =>
        input.getAttribute("name") === name
      );
    assert(
      find("games_to_win").value === "1" &&
        find("games_to_win").getAttribute("max") === "5",
      "Games-to-win defaults and limits must remain intact",
    );
    assert(
      find("points_per_game").value === "11" && find("win_by").value === "2",
      "Scoring defaults must remain unchanged",
    );
    assert(
      find("point_cap").value === "" &&
        find("point_cap").getAttribute("required") === null,
      "The optional point cap must stay optional",
    );
    assert(
      find("forfeit_score").value === "11" &&
        find("forfeit_score").getAttribute("min") === "0",
      "Forfeit form contract must be preserved",
    );
    assert(
      find("tb0").value === "head_to_head" &&
        find("tb1").value === "point_diff",
      "Tiebreak priority must retain the existing defaults",
    );
    modal.close();
  }));

Deno.test("staff assignment modal: member selection, role defaults and audit reason stay intact", () =>
  withDom(async (document) => {
    const rows = [
      {
        member_id: "member-test",
        display_name: "Test Member",
        member_no: "CPC-2030-00001",
        role_name: "Member",
        role_code: "member",
        is_self: false,
      },
      {
        member_id: "admin-test",
        display_name: "Test Admin",
        member_no: "CPC-2030-00002",
        role_name: "Admin",
        role_code: "admin",
        is_self: true,
      },
    ];
    const api = {
      newKey: () => "01K00000000000000000000000",
      rpc: (name, args) =>
        Promise.resolve(
          name === "role_catalog"
            ? [{ code: "member", name: "Member", permissions: [] }, {
              code: "front_desk",
              name: "Front desk",
              permissions: [],
            }]
            : args?.p_only_staff
            ? []
            : rows,
        ),
    };
    const page = createStaffPages({ api }).staffPage();
    document.body.append(page);
    await new Promise((resolve) => setTimeout(resolve, 0));
    page.querySelectorAll("button").find((button) =>
      button.textContent === "Give Someone a Role"
    ).click();
    const modal = document.body.querySelector("dialog");
    assert(
      modal && modal.getAttribute("open") !== null,
      "Assignment must open its modal",
    );
    assert(
      modal.querySelector(".staff-selected-preview").children.length === 0,
      "No member should be preselected",
    );
    const term = modal.querySelectorAll("input").find((input) =>
      input.getAttribute("id") === "st-term"
    );
    term.value = "Test";
    modal.querySelectorAll("button").find((button) =>
      button.textContent === "Search"
    ).click();
    await new Promise((resolve) => setTimeout(resolve, 0));
    const members = modal.querySelector(".staff-results").querySelectorAll(
      "input",
    );
    assert(
      members.length === 2 && members[1].disabled,
      "Search must retain the self-assignment restriction",
    );
    members[0].dispatchEvent(new Event("change"));
    assert(
      modal.querySelector(".staff-selected-preview").textContent.includes(
        "Test Member",
      ),
      "Selecting a member must update the shared identity preview",
    );
    assert(
      modal.querySelector("select").value === "front_desk",
      "The existing role default must remain unchanged",
    );
    const reason = modal.querySelector("textarea");
    assert(
      reason.getAttribute("name") === "reason" &&
        reason.getAttribute("minlength") === "3" &&
        reason.getAttribute("maxlength") === "500",
      "Audit reason validation and field name must be retained",
    );
    reason.value = "Front desk support";
    reason.dispatchEvent(new Event("input"));
    assert(
      modal.querySelector(".decision-reason-count").textContent ===
        `${reason.value.length} / 500`,
      "Audit reason count must update while typing",
    );
    modal.close();
  }));

Deno.test("shared controls: lists, dates, date-times and action menus flip upward near the viewport bottom", () => {
  withDom((document) => {
    document.defaultView = Object.assign(new EventTarget(), {
      innerHeight: 800,
    });
    const cases = [
      [
        selectField({
          id: "flip-list",
          options: [{ value: "a", label: "Alpha" }],
        }),
        ".searchable-select-trigger",
        ".searchable-select-dropdown",
      ],
      [
        h("div", {}, dateControl({ id: "flip-date", value: "2026-10-25" })),
        ".calendar-drop-trigger",
        ".calendar-popover",
      ],
      [
        h(
          "div",
          {},
          dateTimeControl({ id: "flip-datetime", value: "2026-10-25T09:00" }),
        ),
        ".calendar-drop-trigger",
        ".calendar-popover",
      ],
      [
        dropdownMenu({
          trigger: h("button", {}, "Actions"),
          items: [{ label: "Edit" }],
        }),
        "button",
        ".dropdown-menu-list",
      ],
    ];
    for (const [control, triggerSelector, popupSelector] of cases) {
      document.body.append(control);
      const trigger = control.querySelector(triggerSelector);
      const popup = control.querySelector(popupSelector);
      trigger.getBoundingClientRect = () => ({ top: 700, bottom: 744 });
      popup.offsetHeight = popup.scrollHeight = 300;
      trigger.click();
      assert(
        popup.getAttribute("data-placement") === "top",
        `${popupSelector} must open upward`,
      );
      assert(
        popup.attributes["--dropdown-max-height"] === "686px",
        "Every control must use the same viewport bounds",
      );
      trigger.click();
      assert(popup.hidden, "The trigger must still close its popup");
    }
  });
});

Deno.test("memberHero: renders dash-hero with chips, title, subtitle and respects actions", () => {
  withDom(() => {
    const hero = memberHero({
      eyebrow: "Play",
      title: "Book a Court",
      chip: "Court Availability",
      description: "Pick a day, then a free time.",
    });
    assert(hero.className.includes("dash-hero"), "Must use dash-hero class");
    assert(
      hero.querySelector(".dash-hero-title")?.textContent === "Book a Court",
      "Must render title",
    );
    assert(
      hero.querySelector(".dash-hero-sub")?.textContent ===
        "Pick a day, then a free time.",
      "Must render subtitle",
    );
    assert(
      !hero.querySelector(".dash-hero-actions"),
      "No actions container when actions array is empty",
    );
    const chips = hero.querySelectorAll(".dash-chip");
    assert(chips.length >= 3, "Must render eyebrow, date and status chips");
  });
});
