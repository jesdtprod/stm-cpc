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
  toast,
  timeControl,
} from "../../web/ui.js";
import { createRanksPages } from "../../web/pages-ranks.js";
import { createScoringPages } from "../../web/pages-scoring.js";
import { createStaffPages } from "../../web/pages-staff.js";
import { createBookingAdminPages } from "../../web/pages-bookings-admin.js";
import { createMemberEventsPages } from "../../web/pages-events-member.js";
import { createRankingPages } from "../../web/pages-ranking.js";
import { createAdminPages } from "../../web/pages-admin.js";
import { createEventsPages, divisionStatusBadge } from "../../web/pages-events.js";
import { createPublicPages } from "../../web/pages-public.js";
import { createGuestEventActions } from "../../web/event-guests.js";
import { bookingPage } from "../../web/pages.js";
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
    setAuth({ signedIn: true, grants: [{ code: "members.read" }] });
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
    clearAuth();
  }));

Deno.test("ranking ratings: Singles and Doubles with three decimals, provisional and unrated labels", () =>
  withDom(async (document) => {
    setAuth({ signedIn: true, grants: [{ code: "members.read" }] });
    const row = (id, extra) => ({
      member_id: id, member_no: null, since: "2026-10-27T00:00:00Z",
      display_name: `Player ${id}`, category_name: "Novice", rank_name: "Novice High (2.750–2.999)",
      singles_points: null, singles_matches: 0, singles_provisional: false,
      doubles_points: null, doubles_matches: 0, doubles_provisional: false, ...extra,
    });
    // one stub serves categories and the rank bands: rows carry both shapes
    const bandRows = [
      { id: "b1", name: "Novice High (2.750–2.999)", rating_min: 2.75, rating_max: 2.999 },
      { id: "b2", name: "Intermediate Low (3.000–3.499)", rating_min: 3, rating_max: 3.499 },
    ];
    const page = createRankingPages({
      api: {
        read: () => Promise.resolve(bandRows),
        rpc: (name) =>
          Promise.resolve(
            name === "cpc_ranking_list"
              ? [
                row("a", { singles_points: 3.04, singles_matches: 3, singles_provisional: true, doubles_points: 2.9, doubles_matches: 8 }),
                row("b", { singles_points: 3.4, singles_matches: 7 }),
                row("c", { category_name: null, rank_name: null }),
              ]
              : name === "cpc_points_status"
              ? { enabled: false, active_members: 3, prepared: 3, rated_singles: 2, rated_doubles: 1 }
              : [],
          ),
      },
    }).rankingPage();
    document.body.append(page);
    await new Promise((resolve) => setTimeout(resolve, 0));
    const values = page.querySelectorAll(".cpc-points-value").map((n) => n.textContent);
    const subs = page.querySelectorAll(".cpc-points-sub").map((n) => n.textContent);
    // columns per row: Singles, Doubles
    assert(values[0] === "3.040" && values[1] === "2.900", "Singles and Doubles show three decimals");
    assert(subs[0] === "Intermediate Low", "The line under a rating is the rank it equals");
    assert(subs[1] === "Novice High", "Singles and Doubles map to their own ranks");
    assert(values[2] === "3.400" && values[3] === "Unrated", "A member can be rated in one and unrated in the other");
    assert(subs[2] === "Intermediate Low", "3.400 equals Intermediate Low");
    assert(subs[3] === "Not assessed yet", "A ranked member without a rating is Unrated");
    assert(values[4] === "Unrated" && subs[4] === "Provisional Beginner Low", "An unranked member shows the provisional fallback");
    assert(
      page.textContent.includes("Singles Rating") && page.textContent.includes("Doubles Rating"),
      "Two rating columns",
    );
    assert(!page.textContent.includes("CPC Points"), "The old CPC Points label is gone");
    assert(subs.every((t) => !t.startsWith("Provisional ·")), "Only an unranked unrated member shows a provisional line");
    assert(!page.textContent.includes("null"), "No null text is written to the page");
    clearAuth();
  }));

Deno.test("ranking photos: signed private images replace icons and missing photos use initials", () =>
  withDom(async (document) => {
    setAuth({ signedIn: true, grants: [{ code: "members.read" }] });
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
    clearAuth();
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

Deno.test("grid pagination: defaults to ten records with or without search and allows an external pager", () =>
  withDom(() => {
    const config = {
      schema: { columns: [{ key: "name", label: "Record" }] },
      rows: Array.from({ length: 12 }, (_, i) => ({ name: `Record ${i + 1}` })),
    };
    for (const searchable of [true, false]) {
      const grid = dataTable({ ...config, searchable });
      const rows = grid.querySelector(".tbl-body").querySelectorAll(".tbl-row");
      assert(rows.filter((row) => !row.hidden).length === 10);
      const next = grid.querySelectorAll("button").find((button) =>
        button.getAttribute("aria-label") === "Next Page"
      );
      next.click();
      assert(rows.filter((row) => !row.hidden).length === 2);
      assert(!rows[10].hidden && !rows[11].hidden);
    }
    const external = dataTable({ ...config, searchable: false, pageSize: 0 });
    assert(!external.querySelector(".grid-pager"));
    assert(external.querySelector(".tbl-body").querySelectorAll(".tbl-row").every((row) => !row.hidden));
  }));

Deno.test("mobile tables: all matching records remain accessible without pagination", () =>
  withDom(() => {
    const previous = globalThis.matchMedia;
    globalThis.matchMedia = () => ({ matches: true });
    try {
      const view = dataTable({
        schema: { columns: [{ key: "name", label: "Name", render: (r) => r.name }] },
        rows: Array.from({ length: 12 }, (_, i) => ({ name: `Player ${i + 1}` })),
      });
      const rows = view.querySelector(".tbl-body").querySelectorAll(".tbl-row");
      assert(rows.length === 12 && rows.every((row) => !row.hidden));
      assert(view.querySelector(".grid-pager").hidden);
      assert(!view.querySelector('[aria-label="Next Page"]'));
      const search = view.querySelector("input");
      search.value = "Player 12";
      search.dispatchEvent(new Event("input"));
      assert(rows.filter((row) => !row.hidden).length === 1);
      assert(!rows[11].hidden);
    } finally {
      if (previous === undefined) delete globalThis.matchMedia;
      else globalThis.matchMedia = previous;
    }
  }));

Deno.test("toasts: sentence casing preserves acronyms and semantic tones", () =>
  withDom((document) => {
    document.getElementById = () => null;
    for (const tone of ["info", "success", "warning", "error"]) {
      const view = toast("a draw needs at least 2 entries (this division has 0)", {
        tone,
        title: "check CPC and DUPR settings",
        timeout: 0,
      });
      assert(view.matches(`.toast-${tone}`));
      assert(view.querySelector(".toast-msg").textContent === "A draw needs at least 2 entries (this division has 0)");
      assert(view.querySelector(".toast-title").textContent === "Check CPC and DUPR settings");
      assert(view.querySelector(".toast-close-btn").getAttribute("aria-label") === "Dismiss Notification");
      assert(view.getAttribute("role") === (["warning", "error"].includes(tone) ? "alert" : "status"));
    }
    const view = toast("DUPR settings saved.", { timeout: 0 });
    assert(view.querySelector(".toast-msg").textContent === "DUPR settings saved.");
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
    const calls = [];
    const api = {
      read: (build) => {
        const query = {
          select: () => query,
          is: () => query,
          eq: () => query,
          order: () => query,
          then: (resolve) => resolve(query.table === "categories" ? cats
            : query.table === "rank_rules" ? rules : []),
        };
        return build({ from: (table) => { query.table = table; return query; } });
      },
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

Deno.test("pagination: compact mobile controls retain the current page and end navigation", () =>
  withDom(() => {
    for (const [page, expected] of [
      [1, [1, 2, 3]],
      [4, [3, 4, 5]],
      [119, [118, 119, 120]],
      [120, [118, 119, 120]],
    ]) {
      let selected;
      const pager = pagination({
        page,
        pageSize: 12,
        total: 1429,
        compactMobile: true,
        onPage: (next) => selected = next,
      });
      const buttons = pager.querySelectorAll("button");
      const numbered = buttons.filter((button) =>
        button.getAttribute("aria-label")?.startsWith("Page ") &&
        !button.className.split(" ").includes("pager-extra-page")
      );
      assert(
        JSON.stringify(numbered.map((button) => Number(button.textContent))) ===
          JSON.stringify(expected),
        "Mobile must keep three useful page links at the start, middle and end",
      );
      assert(
        numbered.some((button) => button.getAttribute("aria-current") === "page"),
        "The current page must never be hidden on mobile",
      );
      const previous = buttons.find((button) =>
        button.getAttribute("aria-label") === "Previous Page"
      );
      const next = buttons.find((button) =>
        button.getAttribute("aria-label") === "Next Page"
      );
      assert(previous.disabled === (page === 1));
      assert(next.disabled === (page === 120));
      numbered[0].click();
      assert(selected === expected[0], "Compact page links must still navigate");
      assert(buttons.length === 7, "Desktop keeps its five numbered page links");
    }
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

Deno.test("member details modal: consolidates status and audit into 1 unified section", () =>
  withDom(async (document) => {
    setAuth({
      signedIn: true,
      grants: [{ code: "members.read" }],
      gate: null,
    });
    const mockRow = {
      id: "mem-01",
      member_no: "CPC-2026-00001",
      status: "active",
      status_reason: "active",
      flags: [],
      deleted_at: null,
      profile_id: "user-123",
      persons: {
        display_name: "Kyle Marquez",
        mobile: "09566997151",
        email: "kyxymiller@gmail.com",
        address_text: "Poblacion III, Lebak, Sultan Kudarat",
        date_of_birth: "1994-11-28",
        gender: "male",
        emergency_name: "Marlon Quinto",
        emergency_relationship: "Team Leader",
        emergency_phone: "09171247192",
      },
    };
    const api = {
      read: () => Promise.resolve(null),
    };
    const mockQuery = {
      in: () => mockQuery,
      order: () => mockQuery,
      range: () => mockQuery,
      is: () => mockQuery,
      not: () => mockQuery,
      ilike: () => mockQuery,
      then: (resolve) => resolve({ data: [mockRow], count: 1, error: null }),
    };
    const client = {
      from: () => ({
        select: () => mockQuery,
      }),
    };
    const pages = createAdminPages({ api, client, adminResetPassword: () => {} });
    const page = pages.membersPage();
    document.body.append(page);
    await new Promise((r) => setTimeout(r, 10));

    const viewBtn = document.querySelectorAll("button").find((b) =>
      b.getAttribute("aria-label") === "View Details"
    );
    assert(viewBtn, "View details button must exist in table");
    viewBtn.click();
    await new Promise((r) => setTimeout(r, 10));

    const modal = document.body.querySelector("dialog");
    assert(modal, "Modal must be opened");

    // Must have exactly 1 Membership & Audit card
    const auditCards = modal.querySelectorAll(".member-audit-card");
    assert(
      auditCards.length === 1,
      "Must have exactly 1 unified Membership & Audit card",
    );

    const auditCard = auditCards[0];
    const statusStrip = auditCard.querySelector(".member-status-strip");
    assert(statusStrip, "Unified card must contain status strip");

    // The status strip contains Membership, Account, Club Ranking, Singles Rating and Doubles Rating
    const summaryItems = statusStrip.querySelectorAll(".member-summary-item");
    assert(
      summaryItems.length === 5,
      "Status strip must have 5 summary items (Membership, Account, Club Ranking, Singles Rating, Doubles Rating)",
    );

    // The audit card also contains Reason on Record and Review Flags
    const detailsGrid = auditCard.querySelector(".member-details-grid");
    assert(detailsGrid, "Unified card must contain audit details grid");
    assert(
      detailsGrid.textContent.includes("Reason on Record"),
      "Must include Reason on Record",
    );
    assert(
      detailsGrid.textContent.includes("Review Flags"),
      "Must include Review Flags",
    );
    assert(
      detailsGrid.textContent.includes("DUPR ID"),
      "Must include DUPR ID",
    );

    modal.close();
    clearAuth();
  }));

Deno.test("division status follows event registration without hiding tournament progress", () => {
  for (const [eventStatus, label, tone] of [
    ["draft", "Draft", "neutral"],
    ["registration_open", "Open", "success"],
    ["registration_closed", "Closed", "warning"],
    ["cancelled", "Cancelled", "danger"],
  ]) {
    const result = divisionStatusBadge("open", eventStatus);
    assert(result[0] === label && result[1] === tone);
  }
  for (const eventStatus of ["draft", "registration_open", "registration_closed"]) {
    for (const [status, label] of [
      ["drawn", "Drawn"], ["in_progress", "In Progress"],
      ["finalized", "Finalized"], ["cancelled", "Cancelled"],
    ]) {
      assert(divisionStatusBadge(status, eventStatus)[0] === label);
    }
  }
});

Deno.test("guest forms: policy and guest identity use shared accessible controls", () =>
  withDom(() => {
    const actions = createGuestEventActions({
      api: { newKey: () => "fake-key" }, refresh: () => {},
      getEvent: () => ({ id: "fake-event", name: "Fake Guest Event", allow_guest_players: true }),
      getDivisions: () => [], getRanks: () => [],
    });
    let modal = actions.policy();
    assert(modal.textContent.includes("Guest Registration"));
    const toggle = modal.querySelectorAll("input").find((el) => el.getAttribute("name") === "allow-event-guests");
    assert(toggle.hasAttribute("checked"));
    modal.close();
    modal = actions.addGuest();
    const names = modal.querySelectorAll("input,select").map((el) => el.getAttribute("name"));
    assert(names.includes("guest-name") && names.includes("guest-gender") && names.includes("guest-dob"));
    const dupr = modal.querySelectorAll("input").find((el) => el.getAttribute("name") === "guest-dupr-id");
    assert(dupr && dupr.getAttribute("maxlength") === "32" && !dupr.hasAttribute("required"), "Guest DUPR ID stays optional and uses the member ID length limit");
    assert(!names.some((name) => /password|email/.test(name ?? "")), "Guests need no sign-in credentials");
    modal.close();
  }));

Deno.test("guest registration: primary selection excludes members and supports mixed partners", () =>
  withDom(async () => {
    const calls = [];
    const actions = createGuestEventActions({
      api: {
        newKey: () => "fake-key",
        rpc: (name, args) => {
          calls.push({ name, args });
          return Promise.resolve([
            { id: "guest-one", display_name: "Fake Guest", member_id: null },
            { id: "member-one", display_name: "Fake Member", member_id: "fake-member", member_no: "CPC-2030-99999" },
          ]);
        },
      },
      refresh: () => {}, getEvent: () => ({ id: "fake-event", name: "Fake Guest Event" }),
      getDivisions: () => [{ id: "fake-doubles", name: "Fake Doubles", status: "open" }],
      getRanks: () => [{ id: "fake-rank", label: "Novice: Low" }],
    });
    const modal = await actions.register("fake-doubles");
    const controls = modal.querySelectorAll("select");
    const guest = controls.find((el) => el.getAttribute("name") === "guest-player");
    const partner = controls.find((el) => el.getAttribute("name") === "guest-partner");
    assert(guest.querySelectorAll("option").length === 1, "Primary guest picker must exclude members");
    assert(partner.querySelectorAll("option").length === 3, "Partner picker accepts guests and members");
    assert(modal.textContent.includes("Assessed Guest Rank"));
    assert(calls.length === 1 && calls[0].name === "event_participant_choices");
    modal.close();
  }));

Deno.test("admin guest roster: closed-event move selects another undrawn division and requires a reason", () =>
  withDom(async () => {
    const actions = createGuestEventActions({
      api: { newKey: () => "fake-change", rpc: () => Promise.resolve([
        { id: "fake-guest", display_name: "Fake Guest", member_id: null },
        { id: "fake-partner", display_name: "Fake Partner", member_id: null },
      ]) },
      refresh: () => {}, getEvent: () => ({ id: "fake-event", name: "Fake Closed Event", status: "registration_closed" }),
      getDivisions: () => [
        { id: "source", name: "Fake Source", status: "open" },
        { id: "target", name: "Fake Destination", status: "open" },
        { id: "drawn", name: "Fake Drawn Division", status: "drawn" },
      ],
      getRanks: () => [{ id: "fake-rank", label: "Novice: Low" }],
    });
    const row = { id: "fake-registration", division_id: "source", guest_participant_id: "fake-guest", guest_rank_id: "fake-rank", guest_partner_participant_id: "fake-partner" };
    let modal = await actions.change(row, "move");
    let selects = modal.querySelectorAll("select");
    const destination = selects.find((el) => el.getAttribute("name") === "guest-division");
    assert(destination.querySelectorAll("option").length === 1 && destination.value === "target");
    assert(selects.find((el) => el.getAttribute("name") === "guest-player").querySelectorAll("option").length === 1);
    assert(modal.querySelector("textarea").hasAttribute("required"));
    modal.close();
    modal = await actions.change(row, "replace");
    selects = modal.querySelectorAll("select");
    assert(selects.find((el) => el.getAttribute("name") === "guest-division").value === "source");
    assert(selects.find((el) => el.getAttribute("name") === "guest-player").querySelectorAll("option").length === 2);
    modal.close();
  }));

Deno.test("admin guest roster: management permissions alone do not show guest write actions", () =>
  withDom(async (document) => {
    try {
      for (const administrator of [false, true]) {
        setAuth({ signedIn: true, grants: ["events.manage", "registrations.manage", ...(administrator ? ["events.admin_roster"] : [])].map((code) => ({ code, unit_id: null })) });
        const event = { id: "fake-admin-event", name: "Fake Admin Event", status: "registration_closed", allow_guest_players: true, starts_on: "2030-11-01", ends_on: "2030-11-01", fee: 0, divisions: [] };
        const api = {
          newKey: () => "fake-key", rpc: () => Promise.resolve([]),
          read: (build) => {
            const q = { select: () => q, order: () => q, is: () => q, eq: () => q,
              then: (resolve) => resolve(q.table === "events" ? [event] : []) };
            return build({ from: (table) => { q.table = table; return q; } });
          },
        };
        const page = createEventsPages({ api }).eventsPage();
        document.body.append(page);
        await new Promise((resolve) => setTimeout(resolve, 0));
        page.querySelectorAll("button").find((b) => b.getAttribute("aria-label") === "Divisions of Fake Admin Event").click();
        await new Promise((resolve) => setTimeout(resolve, 0));
        const labels = page.querySelectorAll("button").map((b) => b.textContent);
        for (const label of ["Add Guest", "Add Existing Player", "Register Guest", "Guest Registration"]) {
          assert(labels.includes(label) === administrator, `${label} is admin-only in closed events`);
        }
        page.remove();
      }
    } finally { clearAuth(); }
  }));

Deno.test("event settings: draft defaults and saved ranking options remain separate", () =>
  withDom(async (document) => {
    const event = {
      id: "fake-event",
      doc_no: "EV-2030-99999",
      name: "Fake Rating Event",
      starts_on: "2030-11-01",
      ends_on: "2030-11-01",
      fee: 0,
      status: "draft",
      dupr_rated: true,
      apply_cpc_rank_changes: false,
      default_format_template_id: "fake-template",
      divisions: [],
    };
    const api = {
      newKey: () => "01K00000000000000000000000",
      read: (build) => {
        const query = {
          select: () => query,
          order: () => query,
          is: () => query,
          eq: () => query,
          then: (resolve) =>
            resolve(
              query.table === "events"
                ? [event]
                : query.table === "format_templates"
                ? [{ id: "fake-template", name: "Round Robin" }]
                : [],
            ),
        };
        return build({
          from: (table) => {
            query.table = table;
            return query;
          },
        });
      },
    };
    const page = createEventsPages({ api }).eventsPage();
    document.body.append(page);
    await new Promise((resolve) => setTimeout(resolve, 0));
    page.querySelectorAll("button").find((b) => b.textContent === "New Event")
      .click();
    let modal = document.body.querySelector("dialog");
    const control = (id) =>
      modal.querySelectorAll("input,select").find((el) =>
        el.getAttribute("id") === id ||
        (id === "ev-format-tpl" &&
          el.getAttribute("name") === "default_format_template_id")
      );
    assert(
      !control("ev-dupr-rated").hasAttribute("checked"),
      "New events default to CPC only",
    );
    assert(
      control("ev-cpc-ranks").hasAttribute("checked"),
      "New events keep CPC rank movement",
    );
    assert(
      control("ev-format-tpl").value === "",
      "The format default is optional for legacy setup",
    );
    modal.close();
    page.querySelectorAll("button").find((b) =>
      b.getAttribute("aria-label") === "Edit Fake Rating Event"
    ).click();
    modal = document.body.querySelector("dialog");
    assert(
      control("ev-dupr-rated").hasAttribute("checked"),
      "Saved DUPR setting is displayed",
    );
    assert(
      !control("ev-cpc-ranks").hasAttribute("checked"),
      "Saved CPC opt-out is displayed independently",
    );
    assert(
      control("ev-format-tpl").value === "fake-template",
      "Saved event default is displayed",
    );
    assert(!control("ev-dupr-rated").disabled, "Draft settings can be edited");
    modal.close();
    event.status = "registration_open";
    page.querySelectorAll("button").find((b) =>
      b.getAttribute("aria-label") === "Edit Fake Rating Event"
    ).click();
    modal = document.body.querySelector("dialog");
    assert(
      control("ev-dupr-rated").disabled && control("ev-cpc-ranks").disabled &&
        control("ev-format-tpl").disabled,
      "Ranking and format options are locked after draft",
    );
    modal.close();
  }));

Deno.test("rank rules: template selector preserves scope and list displays the template", () =>
  withDom(async (document) => {
    const templates = [{ id: "fake-format", name: "round robin" }];
    const rules = [{
      id: "fake-rule", name: "Fake Scoped Rule", conditions: {},
      format_template_id: "fake-format", template: { name: "round robin" },
      action: "retain", levels: 0, priority: 10, is_active: true,
    }];
    const api = {
      newKey: () => "01K00000000000000000000000",
      read: (build) => {
        const query = {
          select: () => query, is: () => query, eq: () => query, order: () => query,
          then: (resolve) => resolve(query.table === "rank_rules" ? rules
            : query.table === "format_templates" ? templates : []),
        };
        return build({ from: (table) => { query.table = table; return query; } });
      },
    };
    const page = createRanksPages({ api, getOrgId: () => "fake-org" }).ranksPage();
    document.body.append(page);
    await new Promise((resolve) => setTimeout(resolve, 0));
    page.querySelectorAll("button").find((b) => b.textContent === "New Rule").click();
    let dialog = document.body.querySelector("dialog");
    const selector = () => dialog.querySelectorAll("select").find((s) => s.getAttribute("name") === "format_template_id");
    assert(selector().value === "", "New rules default to All Formats");
    assert(selector().options[0].textContent === "All Formats", "The unrestricted choice is explicit");
    assert(selector().options[1].textContent === "Open Play", "Round Robin templates use the Open Play label");
    dialog.close();
    page.querySelectorAll("div").find((el) => el.getAttribute("id") === "ranks-view").querySelectorAll("button")[1].click();
    assert(page.querySelector(".tbl").textContent.includes("Format Template"), "Rules list includes the template column");
    assert(page.querySelector(".tbl").textContent.includes("Open Play"), "The saved scope is visible in the list");
    page.querySelectorAll("button").find((b) => b.getAttribute("aria-label") === "Edit Fake Scoped Rule").click();
    dialog = document.body.querySelector("dialog");
    assert(selector().value === "fake-format", "Editing retains the saved template restriction");
    dialog.close();
  }));

Deno.test("public members: renders executive cards, preserves search bar, and filters in real time", () =>
  withDom(async (document) => {
    const fakeMembers = [
      { name: "Carlyn Bless Guarde", photo: null, category: "Intermediate", rank: "Intermediate Low", member_no: "CPC-001" },
      { name: "Arian Samama", photo: null, category: "Novice", rank: "Novice High", member_no: "CPC-002" },
      { name: "Kyle Marquez", photo: null, category: "Novice", rank: "Novice Low", member_no: "CPC-003" },
      { name: "Aaron L. Alam", photo: null, category: null, rank: null, member_no: "CPC-004" },
    ];
    const api = {
      rpc: (method) => {
        if (method === "public_members") {
          return Promise.resolve({ enabled: true, members: fakeMembers });
        }
        return Promise.resolve(null);
      },
    };
    const pages = createPublicPages({ api, client: null });
    const page = pages.membersPage();
    document.body.append(page);
    await new Promise((resolve) => setTimeout(resolve, 20));

    // Search bar is present and not removed
    const searchInput = page.querySelector('input');
    assert(searchInput, "Search bar must be present");
    assert(searchInput.getAttribute("placeholder") === "Search members", "Search placeholder matches");

    // Grid of cards
    const grid = page.querySelector(".public-members-grid");
    assert(grid, "Card grid must exist");
    const cards = grid.querySelectorAll(".public-member-card");
    assert(cards.length === 4, "Renders 4 member cards");

    // Check card details
    const firstCard = cards[0];
    assert(firstCard.querySelector(".public-member-name").textContent.includes("Guarde"), "Displays member name");
    assert(firstCard.querySelector(".public-member-sub").textContent === "CPC-001", "Displays CPC number");
    assert(firstCard.textContent.includes("Intermediate Low"), "Displays rank badge");

    // Check unranked member
    const unrankedCard = cards[3];
    assert(unrankedCard.textContent.includes("Not Ranked"), "Displays Not Ranked badge");

    // Real-time search
    searchInput.value = "Guarde";
    searchInput.dispatchEvent(new Event("input", { bubbles: true }));
    await new Promise((resolve) => setTimeout(resolve, 10));

    const filteredCards = page.querySelectorAll(".public-member-card");
    assert(filteredCards.length === 1, "Filters cards in real time");
    assert(filteredCards[0].textContent.includes("Guarde"), "Matching card displayed");

    // Clear search
    searchInput.value = "";
    searchInput.dispatchEvent(new Event("input", { bubbles: true }));
    await new Promise((resolve) => setTimeout(resolve, 10));
    assert(page.querySelectorAll(".public-member-card").length === 4, "Restores all cards after clear");

    // Empty search state
    searchInput.value = "NonexistentPlayer";
    searchInput.dispatchEvent(new Event("input", { bubbles: true }));
    await new Promise((resolve) => setTimeout(resolve, 10));

    const empty = page.querySelector(".public-members-state");
    assert(empty, "Empty state must be displayed");
    assert(empty.textContent.includes("No matching members"), "Empty state message shown");

    // Clear search button in empty state
    const clearBtn = empty.querySelector("button");
    assert(clearBtn, "Clear button in empty state");
    clearBtn.click();
    await new Promise((resolve) => setTimeout(resolve, 10));
    assert(page.querySelectorAll(".public-member-card").length === 4, "Restores cards on empty state clear");
  }));

Deno.test("guest existing player: searchable list transitions to executive selected preview with change action", () =>
  withDom(async (document) => {
    let calledRpc = null;
    let rpcArgs = null;
    const players = [
      { person_id: "p-1", display_name: "Kyle Marquez", member_id: "m-1", member_no: "CPC-2026-00001" },
      { person_id: "p-2", display_name: "Maria Santos", member_id: null, member_no: null },
    ];
    const api = {
      newKey: () => "part-key-1",
      rpc: (method, args) => {
        calledRpc = method;
        rpcArgs = args;
        if (method === "search_event_players") {
          return Promise.resolve(players);
        }
        if (method === "create_event_participant") {
          return Promise.resolve({ ok: true });
        }
        return Promise.resolve([]);
      },
    };
    const guestActions = createGuestEventActions({
      api,
      getEvent: () => ({ id: "ev-1", name: "STM Halloween Tournament 2026" }),
      getDivisions: () => [],
      getRanks: () => [],
      refresh: () => Promise.resolve(),
    });

    const modal = guestActions.addExisting();
    document.body.append(modal);

    assert(modal.textContent.includes("Add Existing Player"), "Modal header has title");
    assert(modal.textContent.includes("Find Player"), "Section has Find Player");

    const searchInput = modal.querySelector("input");
    assert(searchInput, "Has search input");
    searchInput.value = "Kyle";
    searchInput.dispatchEvent(new Event("input", { bubbles: true }));

    await new Promise((resolve) => setTimeout(resolve, 350));

    const results = modal.querySelectorAll(".guest-player-result");
    assert(results.length === 2, "Found 2 matching players");
    assert(results[0].textContent.includes("Kyle Marquez"), "First result is Kyle Marquez");
    assert(results[0].textContent.includes("Member"), "Member badge shown");
    assert(results[1].textContent.includes("Maria Santos"), "Second result is Maria Santos");
    assert(results[1].textContent.includes("Guest"), "Guest badge shown");

    // Select Kyle Marquez
    const radio = results[0].querySelector("input");
    radio.click();
    radio.dispatchEvent(new Event("change", { bubbles: true }));
    await new Promise((resolve) => setTimeout(resolve, 50));

    // Preview card must be shown
    const preview = modal.querySelector(".staff-selected-card");
    assert(preview, "Selected player card displayed");
    assert(preview.textContent.includes("Kyle Marquez"), "Preview has player name");
    assert(preview.textContent.includes("CPC-2026-00001"), "Preview has member ID");
    assert(preview.textContent.includes("Member"), "Preview has Member badge");

    // Change button
    const changeBtn = preview.querySelector(".staff-change-btn");
    assert(changeBtn, "Preview has Change button");
    changeBtn.click();
    await new Promise((resolve) => setTimeout(resolve, 50));

    assert(!modal.querySelector(".staff-selected-card"), "Selected card removed after clicking Change");
    assert(modal.querySelectorAll(".guest-player-result").length === 2, "Results restored after Change");

    // Re-select and submit
    results[0].querySelector("input").click();
    results[0].querySelector("input").dispatchEvent(new Event("change", { bubbles: true }));
    await new Promise((resolve) => setTimeout(resolve, 50));

    const confirmBtn = modal.querySelectorAll("button").find((b) => b.textContent.includes("Add Participant"));
    assert(confirmBtn, "Confirm button found");
    modal.querySelector("form").dispatchEvent(new Event("submit"));
    await new Promise((resolve) => setTimeout(resolve, 50));

    assert(calledRpc === "create_event_participant", "Calls create_event_participant");
    assert(rpcArgs.p_member_id === "m-1", "Passes member_id");
    assert(rpcArgs.p_guest_person_id === null, "Passes null for guest_person_id for member");

    modal.remove();
  }));

Deno.test("court cards skeleton: loading state renders structured court cards with matching geometry", () =>
  withDom(async () => {
    const mockApi = {
      rpc: () => new Promise(() => {}),
    };
    const page = bookingPage({ api: mockApi });
    document.body.appendChild(page);

    const grid = page.querySelector(".public-courts-grid");
    assert(grid, "Courts grid exists");
    assert(grid.getAttribute("aria-busy") === "true", "Grid is aria-busy");

    const cards = grid.querySelectorAll(".is-skeleton");
    assert(cards.length === 4, "Renders 4 skeleton court cards");
    assert(cards[0].className.includes("public-court-card"), "Is a public-court-card");

    const first = cards[0];
    assert(first.querySelector(".sk-court-avatar"), "Has court avatar skeleton");
    assert(first.querySelector(".sk-court-title"), "Has court title skeleton");
    assert(first.querySelector(".sk-court-badge"), "Has court status badge skeleton");
    assert(first.querySelector(".sk-court-hours-val"), "Has operating hours skeleton");
    assert(first.querySelector(".sk-court-surface-val"), "Has surface skeleton");
    assert(first.querySelector(".public-court-counts"), "Has court counts skeleton block");
    assert(first.querySelector(".sk-vacant"), "Has vacant counts indicator skeleton");
    assert(first.querySelector(".sk-court-btn-primary"), "Has primary reserve court button skeleton");

    page.remove();
  }));

Deno.test("tournament draw modal: renders structured seeding list with seed badges and audit callout", () =>
  withDom(async () => {
    setAuth({
      signedIn: true,
      grants: ["events.manage", "events.admin_roster"].map((code) => ({ code, unit_id: null })),
    });

    const entriesData = [
      {
        id: "e-1",
        seed: 1,
        members: [
          { member: { person: { display_name: "Player One" } } },
          { member: { person: { display_name: "Player Two" } } },
        ],
        guests: [],
      },
      {
        id: "e-2",
        seed: 2,
        members: [
          { member: { person: { display_name: "Player Three" } } },
        ],
        guests: [
          { display_name_snapshot: "Guest Player Four" },
        ],
      },
    ];

    const fakeDivision = {
      id: "div-drawn",
      name: "Men's Doubles Open",
      status: "drawn",
      stages: [{ id: "st-1", stage_no: 1, stage_type: "single_elimination", status: "drawn" }],
    };

    const fakeEvent = {
      id: "ev-draw-test",
      name: "Draw Test Tournament",
      status: "in_progress",
      allow_guest_players: true,
      starts_on: "2030-11-01",
      ends_on: "2030-11-02",
      fee: 0,
      divisions: [fakeDivision],
    };

    const api = {
      newKey: () => "test-key",
      rpc: () => Promise.resolve([]),
      read: (build) => {
        const q = {
          select: () => q,
          order: () => q,
          is: () => q,
          eq: () => q,
          then: (resolve) => {
            if (q.table === "events") resolve([fakeEvent]);
            else if (q.table === "divisions") resolve([fakeDivision]);
            else if (q.table === "entries") resolve(entriesData);
            else resolve([]);
          },
        };
        return build({
          from: (table) => {
            q.table = table;
            return q;
          },
        });
      },
    };

    const page = createEventsPages({ api }).eventsPage();
    document.body.append(page);
    await new Promise((resolve) => setTimeout(resolve, 0));

    // Navigate to event divisions
    const divBtn = page.querySelectorAll("button").find(
      (b) => b.getAttribute("aria-label") === "Divisions of Draw Test Tournament",
    );
    assert(divBtn, "Found Divisions button");
    divBtn.click();
    await new Promise((resolve) => setTimeout(resolve, 0));

    // Click "View the draw for Men's Doubles Open"
    const viewDrawBtn = page.querySelectorAll("button").find(
      (b) => b.getAttribute("aria-label") === "View the draw for Men's Doubles Open",
    );
    assert(viewDrawBtn, "Found View the draw button");
    await viewDrawBtn.click();
    await new Promise((resolve) => setTimeout(resolve, 50));

    const modal = document.body.querySelector("dialog");
    assert(modal, "Draw modal opened");
    assert(modal.querySelector(".draw-info-callout"), "Has draw info callout");
    assert(modal.querySelector(".draw-list-panel"), "Has draw list panel");

    const rows = modal.querySelectorAll(".draw-entry-row");
    assert(rows.length === 2, "Renders 2 drawn entry rows");

    // Seed badge on first row
    const seedBadge = rows[0].querySelector(".draw-seed-badge");
    assert(seedBadge, "Row 1 has seed badge");
    assert(seedBadge.textContent === "1", "Seed badge has seed 1");

    // Team names
    const teamNames = rows[0].querySelector(".draw-team-names");
    assert(teamNames, "Row 1 has team names");
    assert(teamNames.textContent.includes("Player One"), "Shows Player One");
    assert(teamNames.textContent.includes("Player Two"), "Shows Player Two");

    // Guest tag on row 2
    assert(rows[1].querySelector(".draw-guest-tag"), "Row 2 has guest indicator");

    // Redo warning
    assert(modal.querySelector(".draw-redo-callout"), "Has redo draw warning callout");

    modal.close();
    clearAuth();
    page.remove();
  }));
