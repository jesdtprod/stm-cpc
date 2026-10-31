import { LUCIDE, LUCIDE_SOLID } from "./lib/lucide.js";
import { buttonClasses } from "./lib/buttons.js";
import { dropdownPosition } from "./lib/dropdown-position.js";
import { DEFAULT_PAGE_SIZE } from "./lib/paginate.js";
export { DEFAULT_PAGE_SIZE } from "./lib/paginate.js";
import { tableColumn, tableMinWidth, tableTracks } from "./lib/table-layout.js";

// Shared UI components. Every dynamic value goes through textContent / text nodes,
// never innerHTML, so output is escaped by construction.

const SVG_NS = "http://www.w3.org/2000/svg";
const controlNodes = new WeakMap();
const tableSearches = new WeakMap();
const tablePages = new WeakMap();
const selectSequence = { next: 0 };

/** Create an element. Event handlers must be functions; string `on*` attributes are ignored. */
export function h(tag, props = {}, ...children) {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(props ?? {})) {
    if (value == null || value === false) continue;
    if (key === "class") el.className = value;
    else if (key.startsWith("on")) {
      if (typeof value === "function") {
        el.addEventListener(key.slice(2).toLowerCase(), value);
      }
    } else if (value === true) el.setAttribute(key, "");
    else el.setAttribute(key, String(value));
  }
  for (const child of children.flat()) {
    if (child == null || child === false) continue;
    el.append(
      child instanceof Node
        ? controlNodes.get(child) ?? child
        : document.createTextNode(String(child)),
    );
  }
  return el;
}

export function icon(name, { solid = false } = {}) {
  const svg = document.createElementNS(SVG_NS, "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("class", solid ? "icon icon-solid" : "icon");
  svg.setAttribute("aria-hidden", "true");
  const shapes = (solid && LUCIDE_SOLID[name]) || LUCIDE[name] || LUCIDE.info;
  for (const [tag, attrs] of shapes) {
    const node = document.createElementNS(SVG_NS, tag);
    for (const [key, value] of Object.entries(attrs)) {
      node.setAttribute(key, value);
    }
    svg.append(node);
  }
  return svg;
}

export function toProperCase(text) {
  if (typeof text !== "string" || !text) return text;
  if (text.startsWith("--")) return text;
  return text
    .replace(/_/g, " ")
    .replace(/\b[a-z]/g, (c) => c.toUpperCase());
}

/** Consistent template names, including older Split Single Elimination labels. */
export function formatTemplateLabel(name) {
  if (/^regular\s*\(bracketing\)$/i.test(String(name ?? "").trim())) {
    return "Tournament";
  }
  if (/^round\s+robin$/i.test(String(name ?? "").trim())) {
    return "Open Play";
  }
  return toProperCase(
    String(name ?? "")
      .replace(/\s*\((?:H\s+and\s+L|High\s*\/\s*Low)\)\s*$/i, "")
      .trim(),
  );
}

export function badge(text, tone = "info") {
  const properText = typeof text === "string" ? toProperCase(text) : text;
  return h("span", { class: `badge badge-${tone}` }, properText);
}

export function button(
  {
    label,
    variant = "secondary",
    size = "default",
    icon: iconName,
    iconPosition = "left",
    onClick,
    type = "button",
    disabled,
    title,
    ariaLabel,
    loading = false,
    class: extraClass,
  },
) {
  const cls = [buttonClasses({ variant, size }), extraClass].filter(Boolean)
    .join(" ");

  const iconEl = iconName ? icon(iconName) : null;
  const children = iconPosition === "right" ? [label, iconEl] : [iconEl, label];

  const btn = h(
    "button",
    {
      class: cls,
      type,
      disabled: disabled || loading,
      onClick,
      title: title ?? (typeof label === "string" ? label : undefined),
      "aria-label": ariaLabel,
      "aria-busy": loading ? "true" : null,
      ...(loading ? { "data-pending": "true" } : {}),
    },
    ...children,
  );
  return btn;
}

/** Row actions are icon-only, so the accessible label and tooltip are required. */
export function iconButton(
  {
    label,
    icon: iconName,
    onClick,
    variant = "secondary",
    tone,
    size = "default",
    disabled = false,
    title,
    class: customClass = "",
  },
) {
  if (!label) throw new Error("iconButton needs a label");
  const cls = [
    buttonClasses({ variant: tone ?? variant, size, iconOnly: true }),
    customClass,
  ].filter(Boolean).join(" ");
  return h("button", {
    class: cls,
    type: "button",
    "aria-label": label,
    title: title ?? label,
    disabled,
    onClick,
  }, icon(iconName));
}

export function buttonGroup(buttons = []) {
  return h("div", { class: "btn-group", role: "group" }, ...buttons);
}

/** Shows pending state and blocks duplicate submits while the handler runs. */
export function withPending(btn, task) {
  return async (event) => {
    if (btn.dataset.pending === "true") return;
    btn.dataset.pending = "true";
    btn.setAttribute("aria-disabled", "true");
    try {
      await task(event);
    } finally {
      delete btn.dataset.pending;
      btn.removeAttribute("aria-disabled");
    }
  };
}

export function field(
  {
    id,
    label,
    type = "text",
    value = "",
    error,
    hint,
    required,
    placeholder,
    disabled,
    readonly,
    prefix,
    suffix,
    iconLeading,
    iconTrailing,
    showToggle = false,
    min,
    max,
    step,
    onInput,
    onChange,
  },
) {
  if (type === "date") {
    return dateField({
      id,
      label,
      value,
      required,
      disabled,
      min,
      max,
      error,
      hint,
      onChange,
    });
  }
  if (type === "datetime-local") {
    return dateTimeField({
      id,
      label,
      value,
      required,
      disabled,
      min,
      max,
      error,
      hint,
      onChange,
    });
  }
  const describedBy = [error ? `${id}-err` : null, hint ? `${id}-hint` : null]
    .filter(Boolean).join(" ");

  const inputEl = h("input", {
    class: "input",
    id,
    name: id,
    type,
    value,
    placeholder,
    required,
    disabled,
    readonly,
    min,
    max,
    step,
    "aria-invalid": error ? "true" : null,
    "aria-describedby": describedBy || null,
    onInput,
    onChange,
  });

  let toggleBtn = null;
  if (type === "password" || showToggle) {
    let isPasswordToggled = false;
    toggleBtn = h("button", {
      type: "button",
      class: "input-toggle-btn",
      "aria-label": "Show Password",
      title: "Show Password",
      tabindex: "-1",
      onClick: (e) => {
        e.preventDefault();
        isPasswordToggled = !isPasswordToggled;
        inputEl.type = isPasswordToggled ? "text" : "password";
        toggleBtn.replaceChildren(icon(isPasswordToggled ? "eyeOff" : "eye"));
        const lbl = isPasswordToggled ? "Hide Password" : "Show Password";
        toggleBtn.setAttribute("aria-label", lbl);
        toggleBtn.setAttribute("title", lbl);
      },
    }, icon("eye"));
  }

  const hasWrap = prefix || suffix || iconLeading || iconTrailing || toggleBtn;
  let control = inputEl;
  if (hasWrap) {
    control = h(
      "div",
      {
        class: `input-wrap${disabled ? " is-disabled" : ""}${
          error ? " is-invalid" : ""
        }`,
      },
      iconLeading
        ? h("span", { class: "input-affix icon-leading" }, icon(iconLeading))
        : null,
      prefix ? h("span", { class: "input-affix prefix-text" }, prefix) : null,
      inputEl,
      suffix ? h("span", { class: "input-affix suffix-text" }, suffix) : null,
      iconTrailing
        ? h("span", { class: "input-affix icon-trailing" }, icon(iconTrailing))
        : null,
      toggleBtn,
    );
  }

  const errId = `${id}-err`;
  const errorEl = h(
    "span",
    {
      class: "field-error",
      id: errId,
      role: "alert",
      hidden: !error,
    },
    error || "",
  );

  const fieldEl = h(
    "div",
    { class: `field${error ? " field-error-state" : ""}` },
    label ? h("label", { for: id }, label, required ? " *" : "") : null,
    control,
    hint ? h("span", { class: "field-hint", id: `${id}-hint` }, hint) : null,
    errorEl,
  );

  fieldEl.setError = (errMsg) => {
    errorEl.className = "field-error";
    if (errMsg) {
      errorEl.textContent = errMsg;
      errorEl.hidden = false;
      fieldEl.classList.add("field-error-state");
      fieldEl.classList.remove("field-success-state");
      inputEl.setAttribute("aria-invalid", "true");
      if (hasWrap) control.classList.add("is-invalid");
    } else {
      errorEl.textContent = "";
      errorEl.hidden = true;
      fieldEl.classList.remove("field-error-state");
      inputEl.removeAttribute("aria-invalid");
      if (hasWrap) control.classList.remove("is-invalid");
    }
  };

  fieldEl.setSuccess = (msg = "") => {
    fieldEl.setError("");
    if (msg) {
      fieldEl.classList.add("field-success-state");
      errorEl.textContent = msg;
      errorEl.hidden = false;
      errorEl.className = "field-success";
    } else {
      fieldEl.classList.remove("field-success-state");
      errorEl.className = "field-error";
    }
  };

  fieldEl.inputEl = inputEl;
  return fieldEl;
}

export function textareaField(
  {
    id,
    label,
    value = "",
    rows = 3,
    error,
    hint,
    required,
    placeholder,
    disabled,
    readonly,
    onInput,
    onChange,
  },
) {
  const describedBy = [error ? `${id}-err` : null, hint ? `${id}-hint` : null]
    .filter(Boolean).join(" ");
  return h(
    "div",
    { class: `field${error ? " field-error-state" : ""}` },
    label ? h("label", { for: id }, label, required ? " *" : "") : null,
    h("textarea", {
      class: "input textarea",
      id,
      name: id,
      rows,
      placeholder,
      required,
      disabled,
      readonly,
      "aria-invalid": error ? "true" : null,
      "aria-describedby": describedBy || null,
      onInput,
      onChange,
    }, value),
    hint ? h("span", { class: "field-hint", id: `${id}-hint` }, hint) : null,
    error ? h("span", { class: "field-error", id: `${id}-err` }, error) : null,
  );
}

/** All single-choice dropdowns use the searchable component. */
export function selectField(config) {
  return searchableSelect(config);
}

/** Reuse native input references and form contracts with a decorative leading icon. */
export function inputWithIcon(control, iconName) {
  return h(
    "div",
    { class: "input-wrap" },
    h(
      "span",
      { class: "input-affix icon-leading", "aria-hidden": "true" },
      icon(iconName),
    ),
    control,
  );
}

/** Members-style search; returning the input preserves existing event/value code. */
export function searchControl(props = {}) {
  const input = h("input", { ...props, type: "search" });
  const clear = h("button", {
    class: "search-box-clear",
    type: "button",
    hidden: !input.value,
    "aria-label": "Clear Search",
    title: "Clear Search",
    onClick: () => {
      input.value = "";
      input.focus();
      input.dispatchEvent(new Event("input", { bubbles: true }));
    },
  }, icon("x"));
  const wrap = h(
    "div",
    { class: "search-box grow" },
    h(
      "span",
      { class: "search-box-icon", "aria-hidden": "true" },
      icon("search"),
    ),
    input,
    clear,
  );
  const descriptor = Object.getOwnPropertyDescriptor(
    HTMLInputElement.prototype,
    "value",
  );
  Object.defineProperty(input, "value", {
    get() {
      return descriptor.get.call(this);
    },
    set(value) {
      descriptor.set.call(this, value);
      clear.hidden = !this.value;
    },
    configurable: true,
  });
  input.addEventListener("input", () => {
    clear.hidden = !input.value;
  });
  input.setAttribute(
    "aria-label",
    props["aria-label"] || props.placeholder || "Search",
  );
  controlNodes.set(input, wrap);
  return input;
}

/** Native-select API for existing forms, rendered with the shared searchable UI. */
export function selectControl(props = {}, ...children) {
  const native = h("select", props, ...children);
  const control = searchableSelect({
    id: props.id,
    name: props.name,
    required: props.required,
    disabled: props.disabled,
    ariaLabel: props["aria-label"],
    options: [...native.options].map((option) => ({
      value: option.value,
      label: option.textContent,
      disabled: option.disabled,
    })),
    value: native.value,
    nativeSelect: native,
  });
  const refresh = () => control.refreshFromNative();
  // Preserve references used by dependent selectors and price previews.
  for (const property of ["value", "disabled"]) {
    const descriptor = Object.getOwnPropertyDescriptor(
      HTMLSelectElement.prototype,
      property,
    );
    Object.defineProperty(native, property, {
      get() {
        return descriptor.get.call(this);
      },
      set(next) {
        descriptor.set.call(this, next);
        refresh();
      },
      configurable: true,
    });
  }
  const replace = native.replaceChildren.bind(native);
  native.replaceChildren = (...options) => {
    replace(...options);
    refresh();
  };
  controlNodes.set(native, control);
  return native;
}

/** Record filters: accessible badge buttons with optional counts. */
export function tableFilter(
  { id, activeId, tabs: options = [], onChange, label = "Filter Records" },
) {
  const container = h("div", {
    id,
    class: "member-status-badges",
    role: "group",
    "aria-label": label,
  });
  let selected = activeId;
  const updateSelection = () => {
    for (const button of container.children) {
      button.setAttribute(
        "aria-pressed",
        String(button.getAttribute("data-value") === selected),
      );
    }
  };
  container.setOptions = (items, value = selected) => {
    selected = value;
    container.replaceChildren(...items.map((item) => {
      const value = item.id ?? item.value;
      return h(
        "button",
        {
          type: "button",
          class: "tab-btn",
          "data-value": value,
          onClick: () => {
            selected = value;
            updateSelection();
            onChange?.(value);
          },
        },
        item.label,
        badge(String(Number(item.badge) || 0), "neutral"),
      );
    }));
    updateSelection();
  };
  Object.defineProperty(container, "value", {
    get: () => selected,
    set: (value) => {
      selected = value;
      updateSelection();
    },
  });
  container.setOptions(options);
  return container;
}

export function searchableSelect({
  id = `select-${++selectSequence.next}`,
  label,
  ariaLabel,
  name = id,
  options = [],
  value = "",
  placeholder = "Select option...",
  error,
  hint,
  required,
  disabled,
  onSelect,
  onChange,
  searchable = true,
  nativeSelect = null,
}) {
  const optionValue = (item) => typeof item === "object" ? item.value : item;
  const optionLabel = (item) =>
    String(typeof item === "object" ? item.label : item);
  const findOption = (next) =>
    options.find((item) => String(optionValue(item)) === String(next)) ?? null;
  let selected = findOption(value);
  let isOpen = false;
  let filtered = [...options];
  const description = [hint ? `${id}-hint` : null, `${id}-err`].filter(Boolean)
    .join(" ");
  const triggerText = h("span", { class: "searchable-select-text" });
  const validation = h("span", {
    class: "field-error",
    id: `${id}-err`,
    hidden: !error,
  }, error);
  const listEl = h("div", {
    class: "searchable-select-options",
    role: "listbox",
    id: `${id}-options`,
    "aria-label": ariaLabel || label || "Options",
  });
  const native = nativeSelect ?? h("select", {
    class: "searchable-select-native",
    name,
    required,
    disabled,
    tabindex: "-1",
    "aria-hidden": "true",
    onChange,
    onInvalid: (event) => {
      event.preventDefault();
      validation.textContent = error || "Please select an option.";
      validation.hidden = false;
      triggerBtn.setAttribute("aria-invalid", "true");
      toggle(true);
    },
  });
  if (nativeSelect) {
    native.className = "searchable-select-native";
    native.removeAttribute("id");
    native.setAttribute("tabindex", "-1");
    native.setAttribute("aria-hidden", "true");
    native.addEventListener("invalid", (event) => {
      event.preventDefault();
      validation.textContent = "Please select an option.";
      validation.hidden = false;
      triggerBtn.setAttribute("aria-invalid", "true");
      toggle(true);
    });
  }
  const searchInput = h("input", {
    type: "search",
    class: "input input-sm",
    placeholder: "Search options...",
    "aria-label": `Search ${ariaLabel || label || "options"}`,
    autocomplete: "off",
    onInput: () => {
      const query = searchInput.value.trim().toLocaleLowerCase();
      filtered = options.filter((item) =>
        optionLabel(item).toLocaleLowerCase().includes(query)
      );
      renderList();
    },
  });
  const dropdown = h(
    "div",
    { class: "searchable-select-dropdown", hidden: true },
    searchable ? searchInput : null,
    listEl,
  );

  function sync() {
    if (!nativeSelect) {
      native.replaceChildren(...options.map((item) =>
        h("option", {
          value: optionValue(item),
          disabled: typeof item === "object" && item.disabled,
        }, optionLabel(item))
      ));
    }
    native.value = selected === null ? "" : String(optionValue(selected));
    triggerText.textContent = selected === null
      ? placeholder
      : optionLabel(selected);
  }
  function choose(item) {
    selected = item;
    sync();
    validation.hidden = !error;
    triggerBtn.setAttribute("aria-invalid", error ? "true" : "false");
    toggle(false, true);
    native.dispatchEvent(new Event("change", { bubbles: true }));
    onSelect?.(optionValue(item), item);
  }
  function renderList() {
    listEl.replaceChildren(...filtered.map((item) => {
      const active = selected !== null &&
        String(optionValue(selected)) === String(optionValue(item));
      return h(
        "button",
        {
          class: `searchable-select-item${active ? " is-selected" : ""}`,
          type: "button",
          role: "option",
          tabindex: "-1",
          disabled: typeof item === "object" && item.disabled,
          "aria-selected": String(active),
          onClick: (event) => {
            event.stopPropagation();
            choose(item);
          },
        },
        h("span", {}, optionLabel(item)),
        active ? icon("check") : null,
      );
    }));
    if (!filtered.length) {
      listEl.append(
        h(
          "div",
          { class: "searchable-select-empty muted", role: "status" },
          "No options match",
        ),
      );
    }
  }
  function outside(event) {
    if (!wrap.contains(event.target)) toggle(false);
  }
  function toggle(open, restoreFocus = false, focusSearch = true) {
    if (native.disabled) return;
    isOpen = open;
    dropdown.hidden = !open;
    triggerBtn.setAttribute("aria-expanded", String(open));
    if (open) {
      searchInput.value = "";
      filtered = [...options];
      renderList();
      position.start();
      document.addEventListener("pointerdown", outside);
      if (focusSearch) {
        (searchable ? searchInput : listEl.querySelector(
          ".is-selected:not(:disabled), button:not(:disabled)",
        ))?.focus();
      }
    } else {
      document.removeEventListener("pointerdown", outside);
      position.stop();
      if (restoreFocus) triggerBtn.focus();
    }
  }
  const triggerBtn = h(
    "button",
    {
      class: "input searchable-select-trigger",
      type: "button",
      id,
      disabled,
      "aria-label": ariaLabel || label || placeholder,
      "aria-haspopup": "listbox",
      "aria-expanded": "false",
      "aria-controls": `${id}-options`,
      "aria-required": required ? "true" : null,
      "aria-invalid": error ? "true" : "false",
      "aria-describedby": description,
      onClick: () => toggle(!isOpen),
    },
    triggerText,
    icon("chevronDown"),
  );
  const position = dropdownPosition(triggerBtn, dropdown);
  const wrap = h(
    "div",
    { class: "searchable-select-wrap" },
    native,
    triggerBtn,
    dropdown,
  );
  wrap.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && isOpen) {
      event.preventDefault();
      event.stopPropagation();
      toggle(false, true);
      return;
    }
    if (event.key === "Tab") {
      toggle(false);
      return;
    }
    if (event.key === "Enter" && event.target === searchInput && isOpen) {
      event.preventDefault();
      listEl.querySelector("button:not(:disabled)")?.click();
      return;
    }
    if (!["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) return;
    if (["Home", "End"].includes(event.key) && event.target === searchInput) {
      return;
    }
    event.preventDefault();
    if (!isOpen) toggle(true, false, false);
    const items = [...listEl.querySelectorAll("button:not(:disabled)")];
    if (!items.length) return;
    const current = items.indexOf(document.activeElement);
    const index = event.key === "Home"
      ? 0
      : event.key === "End"
      ? items.length - 1
      : event.key === "ArrowDown"
      ? (current + 1) % items.length
      : current <= 0
      ? items.length - 1
      : current - 1;
    items[index].focus();
    items[index].scrollIntoView({ block: "nearest" });
  });
  wrap.addEventListener("focusout", (event) => {
    if (isOpen && !wrap.contains(event.relatedTarget)) toggle(false);
  });
  const fieldEl = h(
    "div",
    { class: `field${error ? " field-error-state" : ""}` },
    label ? h("label", { for: id }, label, required ? " *" : "") : null,
    wrap,
    hint ? h("span", { class: "field-hint", id: `${id}-hint` }, hint) : null,
    validation,
  );
  fieldEl.setValue = (next) => {
    selected = findOption(next);
    sync();
    if (isOpen) renderList();
  };
  fieldEl.setOptions = (next) => {
    const previous = selected === null ? "" : optionValue(selected);
    options = next;
    selected = findOption(previous);
    sync();
    filtered = options.filter((item) =>
      optionLabel(item).toLocaleLowerCase().includes(
        searchInput.value.trim().toLocaleLowerCase(),
      )
    );
    if (isOpen) renderList();
  };
  fieldEl.close = () => toggle(false);
  fieldEl.refreshFromNative = () => {
    options = [...native.options].map((option) => ({
      value: option.value,
      label: option.textContent,
      disabled: option.disabled,
    }));
    selected = findOption(native.value);
    filtered = [...options];
    triggerText.textContent = selected === null
      ? placeholder
      : optionLabel(selected);
    triggerBtn.disabled = native.disabled;
    if (native.disabled && isOpen) toggle(false);
    if (isOpen) renderList();
  };
  Object.defineProperty(fieldEl, "value", {
    get: () => selected === null ? "" : optionValue(selected),
    set: (next) => fieldEl.setValue(next),
  });
  sync();
  return fieldEl;
}

export function multiSelect(
  {
    id,
    label,
    options = [],
    values = [],
    placeholder = "Select multiple...",
    error,
    hint,
    required,
    disabled,
    onChange,
  },
) {
  const selectedSet = new Set(values);
  let isOpen = false;

  const tagsContainer = h("div", { class: "multi-select-tags" });
  const updateTags = () => {
    tagsContainer.replaceChildren();
    if (selectedSet.size === 0) {
      tagsContainer.append(h("span", { class: "muted" }, placeholder));
      return;
    }
    selectedSet.forEach((val) => {
      const opt = options.find((o) =>
        (typeof o === "object" ? o.value : o) === val
      );
      const lbl = opt ? (typeof opt === "object" ? opt.label : opt) : val;
      const tag = h(
        "span",
        { class: "multi-select-tag" },
        lbl,
        h(
          "button",
          {
            type: "button",
            class: "multi-select-tag-remove",
            "aria-label": `Remove ${lbl}`,
            onClick: (e) => {
              e.stopPropagation();
              selectedSet.delete(val);
              updateTags();
              renderDropdown();
              onChange?.(Array.from(selectedSet));
            },
          },
          icon("x"),
        ),
      );
      tagsContainer.append(tag);
    });
  };

  const listEl = h("div", {
    class: "searchable-select-options",
    role: "listbox",
  });
  const dropdown = h(
    "div",
    { class: "searchable-select-dropdown", hidden: true },
    listEl,
  );

  const renderDropdown = () => {
    listEl.replaceChildren();
    options.forEach((opt) => {
      const val = typeof opt === "object" ? opt.value : opt;
      const lbl = typeof opt === "object" ? opt.label : opt;
      const isChecked = selectedSet.has(val);
      const row = h(
        "button",
        {
          class: `searchable-select-item${isChecked ? " is-selected" : ""}`,
          type: "button",
          role: "option",
          "aria-selected": isChecked ? "true" : "false",
          onClick: (e) => {
            e.stopPropagation();
            if (selectedSet.has(val)) selectedSet.delete(val);
            else selectedSet.add(val);
            updateTags();
            renderDropdown();
            onChange?.(Array.from(selectedSet));
          },
        },
        h("span", {}, lbl),
        isChecked ? icon("check") : null,
      );
      listEl.append(row);
    });
  };

  const trigger = h(
    "div",
    {
      class: "input multi-select-trigger",
      tabindex: disabled ? "-1" : "0",
      onClick: () => {
        if (disabled) return;
        isOpen = !isOpen;
        dropdown.hidden = !isOpen;
        if (isOpen) renderDropdown();
      },
    },
    tagsContainer,
    icon("chevronDown"),
  );

  const wrap = h("div", { class: "searchable-select-wrap" }, trigger, dropdown);

  document.addEventListener("click", (e) => {
    if (!wrap.contains(e.target) && isOpen) {
      isOpen = false;
      dropdown.hidden = true;
    }
  });

  updateTags();

  return h(
    "div",
    { class: `field${error ? " field-error-state" : ""}` },
    label ? h("label", { for: id }, label, required ? " *" : "") : null,
    wrap,
    hint ? h("span", { class: "field-hint", id: `${id}-hint` }, hint) : null,
    error ? h("span", { class: "field-error", id: `${id}-err` }, error) : null,
  );
}

export function autocompleteField(
  {
    id,
    label,
    suggestions = [],
    value = "",
    placeholder = "Type to search...",
    error,
    hint,
    required,
    disabled,
    onSelect,
  },
) {
  const inputEl = h("input", {
    type: "text",
    class: "input",
    id,
    name: id,
    value,
    placeholder,
    required,
    disabled,
    autocomplete: "off",
  });

  const listEl = h(
    "div",
    { class: "autocomplete-dropdown", hidden: true, role: "listbox" },
  );

  inputEl.addEventListener("input", (e) => {
    const val = e.target.value.toLowerCase();
    if (!val) {
      listEl.hidden = true;
      return;
    }
    const matches = suggestions.filter((s) => s.toLowerCase().includes(val));
    if (matches.length === 0) {
      listEl.hidden = true;
      return;
    }
    listEl.replaceChildren(
      ...matches.map((item) =>
        h(
          "button",
          {
            type: "button",
            class: "autocomplete-item",
            onClick: () => {
              inputEl.value = item;
              listEl.hidden = true;
              onSelect?.(item);
            },
          },
          item,
        )
      ),
    );
    listEl.hidden = false;
  });

  document.addEventListener("click", (e) => {
    if (!listEl.contains(e.target) && e.target !== inputEl) {
      listEl.hidden = true;
    }
  });

  const wrap = h("div", { class: "autocomplete-wrap" }, inputEl, listEl);

  return h(
    "div",
    { class: `field${error ? " field-error-state" : ""}` },
    label ? h("label", { for: id }, label, required ? " *" : "") : null,
    wrap,
    hint ? h("span", { class: "field-hint", id: `${id}-hint` }, hint) : null,
    error ? h("span", { class: "field-error", id: `${id}-err` }, error) : null,
  );
}

export function checkbox(
  {
    id,
    label,
    checked = false,
    disabled = false,
    required = false,
    hint,
    onChange,
  },
) {
  const inputEl = h("input", {
    type: "checkbox",
    id,
    name: id,
    checked,
    disabled,
    required,
    onChange: (e) => onChange?.(e.target.checked, e),
  });

  return h(
    "div",
    { class: `field-checkbox-wrap${disabled ? " is-disabled" : ""}` },
    h(
      "label",
      { class: "custom-check", for: id },
      inputEl,
      h(
        "div",
        { class: "check-content" },
        h("span", { class: "check-label" }, label, required ? " *" : ""),
        hint ? h("span", { class: "field-hint block" }, hint) : null,
      ),
    ),
  );
}

export function radioGroup(
  {
    name,
    label,
    options = [],
    value = "",
    disabled = false,
    required = false,
    hint,
    onChange,
  },
) {
  const inputs = options.map((opt, idx) => {
    const val = typeof opt === "object" ? opt.value : opt;
    const lbl = typeof opt === "object" ? opt.label : opt;
    const optId = `${name}-${idx}`;
    const inputEl = h("input", {
      type: "radio",
      id: optId,
      name,
      value: val,
      checked: String(val) === String(value),
      disabled,
      required,
      onChange: () => onChange?.(val),
    });
    return h(
      "label",
      { class: "custom-radio", for: optId },
      inputEl,
      h("span", {}, lbl),
    );
  });

  return h(
    "fieldset",
    { class: "field field-radio-group", disabled: disabled || null },
    label
      ? h("legend", { class: "field-legend" }, label, required ? " *" : "")
      : null,
    h("div", { class: "radio-stack" }, ...inputs),
    hint ? h("span", { class: "field-hint" }, hint) : null,
  );
}

export function switchToggle(
  {
    id,
    name = id,
    label,
    checked = false,
    disabled = false,
    hint,
    onChange,
  },
) {
  const inputEl = h("input", {
    type: "checkbox",
    class: "switch-input",
    id,
    name,
    checked,
    disabled,
    onChange: (e) => onChange?.(e.target.checked, e),
  });

  return h(
    "div",
    { class: `switch-wrap${disabled ? " is-disabled" : ""}` },
    h(
      "label",
      { class: "switch-control", for: id },
      inputEl,
      h(
        "span",
        { class: "switch-track", "aria-hidden": "true" },
        h("span", { class: "switch-thumb" }),
      ),
      h(
        "div",
        { class: "switch-label-wrap" },
        h("span", { class: "switch-label" }, label),
        hint ? h("span", { class: "field-hint block" }, hint) : null,
      ),
    ),
  );
}

export function segmentedControl(
  {
    name,
    label,
    options = [],
    value = "",
    onChange,
  },
) {
  let selected = value ||
    (typeof options[0] === "object" ? options[0].value : options[0]);
  const btns = options.map((opt) => {
    const val = typeof opt === "object" ? opt.value : opt;
    const lbl = typeof opt === "object" ? opt.label : opt;
    const isSelected = String(val) === String(selected);
    const btn = h(
      "button",
      {
        class: "segment-btn",
        type: "button",
        "aria-pressed": isSelected ? "true" : "false",
        onClick: () => {
          selected = val;
          btns.forEach((b) =>
            b.setAttribute("aria-pressed", b === btn ? "true" : "false")
          );
          onChange?.(val);
        },
      },
      lbl,
    );
    return btn;
  });

  return h(
    "div",
    { class: "field" },
    label ? h("label", {}, label) : null,
    h(
      "div",
      {
        class: "segmented-control",
        role: "group",
        "aria-label": label ?? name,
      },
      ...btns,
    ),
  );
}

export function sliderField(
  {
    id,
    label,
    min = 0,
    max = 100,
    step = 1,
    value = 50,
    unit = "",
    disabled = false,
    hint,
    onChange,
  },
) {
  const valDisplay = h("span", { class: "slider-val" }, `${value}${unit}`);
  const inputEl = h("input", {
    type: "range",
    class: "slider-input",
    id,
    name: id,
    min,
    max,
    step,
    value,
    disabled,
    onInput: (e) => {
      valDisplay.textContent = `${e.target.value}${unit}`;
      onChange?.(Number(e.target.value));
    },
  });

  return h(
    "div",
    { class: "slider-wrap" },
    h(
      "div",
      { class: "slider-header" },
      label ? h("label", { for: id }, label) : null,
      valDisplay,
    ),
    inputEl,
    hint ? h("span", { class: "field-hint" }, hint) : null,
  );
}

/** Date adapter preserves native validation and FormData while sharing the calendar. */
export function dateControl(props = {}) {
  const native = h("input", { ...props, type: "date" });
  const control = calendarDropdown({
    ...props,
    ariaLabel: props.ariaLabel || props["aria-label"],
    value: native.value,
    nativeInput: native,
    onChange: () =>
      native.dispatchEvent(new Event("change", { bubbles: true })),
  });
  for (const property of ["value", "disabled"]) {
    const descriptor = Object.getOwnPropertyDescriptor(
      HTMLInputElement.prototype,
      property,
    );
    Object.defineProperty(native, property, {
      get() {
        return descriptor.get.call(this);
      },
      set(next) {
        descriptor.set.call(this, next);
        control.refreshFromNative();
      },
      configurable: true,
    });
  }
  controlNodes.set(native, control);
  return native;
}

export function dateField(config) {
  return controlNodes.get(dateControl({ ...config, name: config.id }));
}

export function timeControl(props = {}) {
  const native = h("input", { ...props, type: "time" });
  const control = calendarDropdown({
    ...props,
    timeOnly: true,
    ariaLabel: props.ariaLabel || props["aria-label"],
    value: native.value,
    nativeInput: native,
    onChange: () =>
      native.dispatchEvent(new Event("change", { bubbles: true })),
  });
  for (const property of ["value", "disabled"]) {
    const descriptor = Object.getOwnPropertyDescriptor(
      HTMLInputElement.prototype,
      property,
    );
    Object.defineProperty(native, property, {
      get() {
        return descriptor.get.call(this);
      },
      set(next) {
        descriptor.set.call(this, next);
        control.refreshFromNative();
      },
      configurable: true,
    });
  }
  controlNodes.set(native, control);
  return native;
}

export function timeField(config) {
  return controlNodes.get(timeControl({ ...config, name: config.id }));
}

export function dateTimeControl(props = {}) {
  const native = h("input", { ...props, type: "datetime-local" });
  const control = calendarDropdown({
    ...props,
    includeTime: true,
    ariaLabel: props.ariaLabel || props["aria-label"],
    value: native.value,
    nativeInput: native,
    onChange: () =>
      native.dispatchEvent(new Event("change", { bubbles: true })),
  });
  for (const property of ["value", "disabled"]) {
    const descriptor = Object.getOwnPropertyDescriptor(
      HTMLInputElement.prototype,
      property,
    );
    Object.defineProperty(native, property, {
      get() {
        return descriptor.get.call(this);
      },
      set(next) {
        descriptor.set.call(this, next);
        control.refreshFromNative();
      },
      configurable: true,
    });
  }
  controlNodes.set(native, control);
  return native;
}

export function dateTimeField(config) {
  return controlNodes.get(dateTimeControl({ ...config, name: config.id }));
}

export function calendarDropdown(
  {
    id = "calendar-drop",
    label,
    ariaLabel,
    value = "",
    range = false,
    startValue = "",
    endValue = "",
    min,
    max,
    onChange,
    hint,
    error,
    required = false,
    disabled = false,
    defaultView = "",
    nativeInput = null,
    includeTime = false,
    timeOnly = false,
  },
) {
  let selectedStart = range ? startValue : value;
  let selectedEnd = range ? endValue : "";
  let isOpen = false;

  let selectedDate = "";
  let selectedHour = "09";
  let selectedMinute = "00";
  let selectedPeriod = "AM";

  const parseDateTime = (str) => {
    if (!str) {
      selectedDate = "";
      selectedHour = "09";
      selectedMinute = "00";
      selectedPeriod = "AM";
      return;
    }
    const [d, t] = String(str).split(/[T\s]/);
    if (!t && /^\d{1,2}:\d{2}/.test(d)) {
      const [hStr, mStr] = d.split(":");
      let hNum = parseInt(hStr, 10);
      if (!isNaN(hNum)) {
        selectedPeriod = hNum >= 12 ? "PM" : "AM";
        hNum = hNum % 12 || 12;
        selectedHour = String(hNum).padStart(2, "0");
      }
      if (mStr !== undefined) {
        selectedMinute = String(parseInt(mStr, 10) || 0).padStart(2, "0");
      }
      return;
    }
    selectedDate = d || "";
    if (t) {
      const [hStr, mStr] = t.split(":");
      let hNum = parseInt(hStr, 10);
      if (!isNaN(hNum)) {
        selectedPeriod = hNum >= 12 ? "PM" : "AM";
        hNum = hNum % 12 || 12;
        selectedHour = String(hNum).padStart(2, "0");
      }
      if (mStr !== undefined) {
        selectedMinute = String(parseInt(mStr, 10) || 0).padStart(2, "0");
      }
    }
  };

  if (timeOnly) {
    parseDateTime(value);
  } else if (includeTime) {
    parseDateTime(value);
    selectedStart = selectedDate;
  }

  const initialDate = selectedStart ? new Date(selectedStart) : new Date();
  let viewYear = isNaN(initialDate.getTime())
    ? new Date().getFullYear()
    : initialDate.getFullYear();
  let viewMonth = isNaN(initialDate.getTime())
    ? new Date().getMonth()
    : initialDate.getMonth();
  // "YYYY-MM": where the calendar opens when nothing is chosen yet (a birth date opens decades back)
  if (!selectedStart && /^\d{4}-\d{2}$/.test(defaultView)) {
    viewYear = Number(defaultView.slice(0, 4));
    viewMonth = Number(defaultView.slice(5, 7)) - 1;
  }
  let pickMode = "days"; // "days" | "months" | "years"

  const MONTH_NAMES = [
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
  ];
  const DAY_NAMES = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"];

  const getTimeString = () => {
    let h24 = parseInt(selectedHour, 10) % 12;
    if (selectedPeriod === "PM") h24 += 12;
    return `${String(h24).padStart(2, "0")}:${selectedMinute}`;
  };

  const getFullDateTimeString = () => {
    if (!selectedDate) return "";
    let h24 = parseInt(selectedHour, 10) % 12;
    if (selectedPeriod === "PM") h24 += 12;
    return `${selectedDate}T${String(h24).padStart(2, "0")}:${selectedMinute}`;
  };

  const formatDisplay = () => {
    if (timeOnly) {
      return `${selectedHour}:${selectedMinute} ${selectedPeriod}`;
    }
    if (includeTime) {
      if (!selectedDate) return "Select date & time";
      const [y, m, d] = selectedDate.split("-");
      const mName = MONTH_NAMES[parseInt(m, 10) - 1]?.slice(0, 3) || m;
      return `${mName} ${
        parseInt(d, 10)
      }, ${y}  ${selectedHour}:${selectedMinute} ${selectedPeriod}`;
    }
    if (range) {
      if (selectedStart && selectedEnd) {
        return `${selectedStart} → ${selectedEnd}`;
      }
      if (selectedStart) return `${selectedStart} → Select end date`;
      return "Select date range";
    }
    return selectedStart || "Select Date";
  };

  const displayText = h(
    "span",
    { class: "calendar-drop-val" },
    formatDisplay(),
  );
  const triggerBtn = h(
    "button",
    {
      type: "button",
      class: "input calendar-drop-trigger",
      id,
      "aria-label": ariaLabel || label ||
        (timeOnly
          ? "Choose Time"
          : (includeTime ? "Choose date and time" : "Choose Date")),
      "aria-haspopup": "dialog",
      "aria-expanded": "false",
      "aria-controls": `${id}-calendar`,
      disabled,
      onClick: (e) => {
        e.preventDefault();
        toggleCalendar(!isOpen);
      },
    },
    h(
      "span",
      { class: "calendar-drop-trigger-left" },
      icon(timeOnly || includeTime ? "clock" : "calendar"),
      displayText,
    ),
    icon("chevronDown"),
  );

  const popover = h("div", {
    id: `${id}-calendar`,
    class: `calendar-popover${
      timeOnly ? " has-time is-time-only" : (includeTime ? " has-time" : "")
    }`,
    role: "dialog",
    "aria-label": label ||
      (timeOnly
        ? "Choose Time"
        : (includeTime ? "Choose date and time" : "Choose Date")),
    hidden: true,
  });

  const hiddenInput = nativeInput ?? h("input", {
    type: "hidden",
    id: `${id}-value`,
    name: id,
    value: timeOnly
      ? getTimeString()
      : (includeTime ? getFullDateTimeString() : (selectedStart || "")),
  });

  const emitTimeSelect = () => {
    const val = getTimeString();
    hiddenInput.value = val;
    displayText.textContent = formatDisplay();
    if (onChange) {
      const evt = {
        target: { id, name: id, value: val },
        currentTarget: { id, name: id, value: val },
        value: val,
        toString: () => val,
      };
      onChange(evt);
    }
  };

  const emitDateTimeSelect = () => {
    if (!selectedDate) {
      selectedDate = new Date().toISOString().slice(0, 10);
    }
    const val = getFullDateTimeString();
    hiddenInput.value = val;
    displayText.textContent = formatDisplay();
    if (onChange) {
      const evt = {
        target: { id, name: id, value: val },
        currentTarget: { id, name: id, value: val },
        value: val,
        toString: () => val,
      };
      onChange(evt);
    }
  };

  const emitSingleSelect = (dStr) => {
    selectedStart = dStr;
    hiddenInput.value = dStr;
    displayText.textContent = formatDisplay();
    renderMonth();
    if (onChange) {
      const evt = {
        target: { id, name: id, value: dStr },
        currentTarget: { id, name: id, value: dStr },
        value: dStr,
        toString: () => dStr,
      };
      onChange(evt);
    }
    setTimeout(() => toggleCalendar(false), 160);
  };

  const renderMonth = () => {
    popover.replaceChildren();

    const header = h(
      "div",
      { class: "calendar-header" },
      h(
        "button",
        {
          type: "button",
          class: "calendar-nav-btn",
          "aria-label": "Previous Month",
          onClick: (e) => {
            e.stopPropagation();
            viewMonth--;
            if (viewMonth < 0) {
              viewMonth = 11;
              viewYear--;
            }
            renderMonth();
          },
        },
        icon("chevronLeft"),
      ),
      h(
        "button",
        {
          type: "button",
          class: "calendar-month-label calendar-month-btn",
          "aria-label": "Choose month and year",
          onClick: (e) => {
            e.stopPropagation();
            pickMode = pickMode === "days" ? "years" : "days";
            renderMonth();
          },
        },
        pickMode === "years"
          ? `${viewYear}`
          : `${MONTH_NAMES[viewMonth]} ${viewYear}`,
        icon("chevronDown"),
      ),
      h(
        "button",
        {
          type: "button",
          class: "calendar-nav-btn",
          "aria-label": "Next Month",
          onClick: (e) => {
            e.stopPropagation();
            viewMonth++;
            if (viewMonth > 11) {
              viewMonth = 0;
              viewYear++;
            }
            renderMonth();
          },
        },
        icon("chevronRight"),
      ),
    );

    const weekdaysRow = h(
      "div",
      { class: "calendar-weekdays" },
      ...DAY_NAMES.map((d) => h("span", { class: "calendar-weekday" }, d)),
    );

    const firstDayIndex = new Date(viewYear, viewMonth, 1).getDay();
    const daysInMonth = new Date(viewYear, viewMonth + 1, 0).getDate();
    const daysInPrevMonth = new Date(viewYear, viewMonth, 0).getDate();

    const daysGrid = h("div", { class: "calendar-days" });

    // Previous month filler days
    for (let i = firstDayIndex - 1; i >= 0; i--) {
      const prevDay = daysInPrevMonth - i;
      daysGrid.appendChild(
        h("span", { class: "calendar-day is-filler" }, `${prevDay}`),
      );
    }

    const todayStr = new Date().toISOString().slice(0, 10);

    // Current month days
    for (let day = 1; day <= daysInMonth; day++) {
      const dStr = `${viewYear}-${String(viewMonth + 1).padStart(2, "0")}-${
        String(day).padStart(2, "0")
      }`;
      const isToday = dStr === todayStr;
      const isStart = includeTime
        ? dStr === selectedDate
        : dStr === selectedStart;
      const isEnd = dStr === selectedEnd;
      const inRange = range && selectedStart && selectedEnd &&
        dStr > selectedStart && dStr < selectedEnd;
      const isDateDisabled = Boolean(
        (nativeInput?.disabled ?? disabled) ||
          (min && dStr < min) ||
          (max && dStr > max),
      );

      const classes = [
        "calendar-day",
        isToday ? "is-today" : "",
        isStart ? `is-selected${range ? " is-range-start" : ""}` : "",
        isEnd ? `is-selected${range ? " is-range-end" : ""}` : "",
        inRange ? "is-in-range" : "",
      ].filter(Boolean).join(" ");

      const dayBtn = h(
        "button",
        {
          type: "button",
          class: classes,
          "data-date": dStr,
          disabled: isDateDisabled,
          onClick: (e) => {
            e.stopPropagation();
            if (includeTime) {
              selectedDate = dStr;
              emitDateTimeSelect();
              renderMonth();
            } else if (range) {
              if (!selectedStart || (selectedStart && selectedEnd)) {
                selectedStart = dStr;
                selectedEnd = "";
              } else if (dStr < selectedStart) {
                selectedEnd = selectedStart;
                selectedStart = dStr;
              } else {
                selectedEnd = dStr;
              }
              hiddenInput.value = selectedStart;
              displayText.textContent = formatDisplay();
              renderMonth();
              onChange?.({ start: selectedStart, end: selectedEnd });
              if (selectedStart && selectedEnd) {
                setTimeout(() => toggleCalendar(false), 220);
              }
            } else {
              emitSingleSelect(dStr);
            }
          },
        },
        `${day}`,
      );
      daysGrid.appendChild(dayBtn);
    }

    const presetsBar = h(
      "div",
      { class: "calendar-presets" },
      h(
        "button",
        {
          type: "button",
          class: "preset-chip",
          onClick: (e) => {
            e.stopPropagation();
            const now = new Date();
            viewYear = now.getFullYear();
            viewMonth = now.getMonth();
            if (includeTime) {
              selectedDate = todayStr;
              emitDateTimeSelect();
              renderMonth();
            } else if (range) {
              selectedStart = todayStr;
              selectedEnd = todayStr;
              hiddenInput.value = todayStr;
              displayText.textContent = formatDisplay();
              renderMonth();
              onChange?.({ start: selectedStart, end: selectedEnd });
              setTimeout(() => toggleCalendar(false), 180);
            } else {
              emitSingleSelect(todayStr);
            }
          },
        },
        "Today",
      ),
      h(
        "button",
        {
          type: "button",
          class: "preset-chip",
          onClick: (e) => {
            e.stopPropagation();
            if (includeTime) {
              const now = new Date();
              viewYear = now.getFullYear();
              viewMonth = now.getMonth();
              selectedDate = todayStr;
              let nowH = now.getHours();
              selectedPeriod = nowH >= 12 ? "PM" : "AM";
              nowH = nowH % 12 || 12;
              selectedHour = String(nowH).padStart(2, "0");
              const nowM = Math.round(now.getMinutes() / 5) * 5;
              selectedMinute = String(nowM >= 60 ? 55 : nowM).padStart(2, "0");
              emitDateTimeSelect();
              renderMonth();
            } else {
              const now = new Date();
              viewYear = now.getFullYear();
              viewMonth = now.getMonth();
              const first = new Date(viewYear, viewMonth, 1).toISOString()
                .slice(
                  0,
                  10,
                );
              const last = new Date(viewYear, viewMonth + 1, 0).toISOString()
                .slice(0, 10);
              if (range) {
                selectedStart = first;
                selectedEnd = last;
                hiddenInput.value = first;
                displayText.textContent = formatDisplay();
                renderMonth();
                onChange?.({ start: selectedStart, end: selectedEnd });
                setTimeout(() => toggleCalendar(false), 180);
              } else {
                emitSingleSelect(first);
              }
            }
          },
        },
        includeTime ? "Now" : "This Month",
      ),
      h(
        "button",
        {
          type: "button",
          class: "preset-chip",
          onClick: (e) => {
            e.stopPropagation();
            if (includeTime) {
              selectedDate = "";
              hiddenInput.value = "";
              displayText.textContent = formatDisplay();
              renderMonth();
              onChange?.({
                target: { id, name: id, value: "" },
                currentTarget: { id, name: id, value: "" },
                value: "",
                toString: () => "",
              });
            } else {
              selectedStart = "";
              selectedEnd = "";
              hiddenInput.value = "";
              displayText.textContent = formatDisplay();
              renderMonth();
              if (range) {
                onChange?.({ start: "", end: "" });
              } else {
                emitSingleSelect("");
              }
            }
          },
        },
        "Clear",
      ),
    );

    if (includeTime || timeOnly) {
      if (includeTime) popover.classList.add("has-time");
      if (timeOnly) popover.classList.add("has-time", "is-time-only");
      const hours = [
        "01",
        "02",
        "03",
        "04",
        "05",
        "06",
        "07",
        "08",
        "09",
        "10",
        "11",
        "12",
      ];
      const baseMinutes = [
        "00",
        "05",
        "10",
        "15",
        "20",
        "25",
        "30",
        "35",
        "40",
        "45",
        "50",
        "55",
      ];
      const minuteList = baseMinutes.includes(selectedMinute)
        ? baseMinutes
        : [...baseMinutes, selectedMinute].sort((a, b) =>
          Number(a) - Number(b)
        );

      const emitTime = () => {
        if (timeOnly) emitTimeSelect();
        else emitDateTimeSelect();
      };

      let amBtn;
      let pmBtn;
      let hrDisplay;
      let minDisplay;
      let periodBadge;
      let hoursCol;
      let minutesCol;

      const updateTimeUI = (scrollIntoView = false) => {
        if (hrDisplay) hrDisplay.textContent = selectedHour;
        if (minDisplay) minDisplay.textContent = selectedMinute;
        if (periodBadge) periodBadge.textContent = selectedPeriod;

        if (amBtn) {
          amBtn.classList.toggle("is-selected", selectedPeriod === "AM");
          amBtn.setAttribute(
            "aria-checked",
            selectedPeriod === "AM" ? "true" : "false",
          );
        }
        if (pmBtn) {
          pmBtn.classList.toggle("is-selected", selectedPeriod === "PM");
          pmBtn.setAttribute(
            "aria-checked",
            selectedPeriod === "PM" ? "true" : "false",
          );
        }

        if (hoursCol) {
          for (const btn of hoursCol.children) {
            btn.classList.toggle(
              "is-selected",
              btn.getAttribute("data-hour") === selectedHour,
            );
          }
          if (scrollIntoView) {
            hoursCol.querySelector(".is-selected")?.scrollIntoView({
              block: "center",
              behavior: "smooth",
            });
          }
        }

        if (minutesCol) {
          for (const btn of minutesCol.children) {
            btn.classList.toggle(
              "is-selected",
              btn.getAttribute("data-minute") === selectedMinute,
            );
          }
          if (scrollIntoView) {
            minutesCol.querySelector(".is-selected")?.scrollIntoView({
              block: "center",
              behavior: "smooth",
            });
          }
        }
      };

      const selectTimeValues = (hStr, mStr, pStr, scroll = false) => {
        selectedHour = hStr;
        selectedMinute = mStr;
        selectedPeriod = pStr;
        updateTimeUI(scroll);
        emitTime();
        displayText.textContent = formatDisplay();
      };

      const hourBtns = hours.map((hStr) =>
        h("button", {
          type: "button",
          class: `calendar-time-btn${
            hStr === selectedHour ? " is-selected" : ""
          }`,
          "data-hour": hStr,
          onClick: (e) => {
            e.stopPropagation();
            selectTimeValues(hStr, selectedMinute, selectedPeriod);
          },
        }, hStr)
      );

      const minBtns = minuteList.map((mStr) =>
        h("button", {
          type: "button",
          class: `calendar-time-btn${
            mStr === selectedMinute ? " is-selected" : ""
          }`,
          "data-minute": mStr,
          onClick: (e) => {
            e.stopPropagation();
            selectTimeValues(selectedHour, mStr, selectedPeriod);
          },
        }, mStr)
      );

      amBtn = h("button", {
        type: "button",
        class: `calendar-time-period-btn${
          selectedPeriod === "AM" ? " is-selected" : ""
        }`,
        role: "radio",
        "aria-checked": selectedPeriod === "AM" ? "true" : "false",
        onClick: (e) => {
          e.stopPropagation();
          selectTimeValues(selectedHour, selectedMinute, "AM");
        },
      }, "AM");

      pmBtn = h("button", {
        type: "button",
        class: `calendar-time-period-btn${
          selectedPeriod === "PM" ? " is-selected" : ""
        }`,
        role: "radio",
        "aria-checked": selectedPeriod === "PM" ? "true" : "false",
        onClick: (e) => {
          e.stopPropagation();
          selectTimeValues(selectedHour, selectedMinute, "PM");
        },
      }, "PM");

      const periodGroup = h(
        "div",
        {
          class: "calendar-time-period-group",
          role: "radiogroup",
          "aria-label": "Time period",
        },
        amBtn,
        pmBtn,
      );

      const headerTitle = h(
        "div",
        { class: "calendar-time-heading" },
        h("span", { class: "calendar-time-icon" }, icon("clock")),
        h("span", { class: "calendar-time-title" }, "Time"),
      );

      const timeHeader = h(
        "div",
        { class: "calendar-time-header" },
        headerTitle,
        periodGroup,
      );

      hrDisplay = h(
        "span",
        { class: "calendar-time-val-hour" },
        selectedHour,
      );
      minDisplay = h(
        "span",
        { class: "calendar-time-val-min" },
        selectedMinute,
      );
      periodBadge = h(
        "span",
        { class: "calendar-time-period-badge" },
        selectedPeriod,
      );

      const displayCard = h(
        "div",
        { class: "calendar-time-display-card" },
        h(
          "div",
          { class: "calendar-time-readout calendar-time-display" },
          hrDisplay,
          h("span", { class: "calendar-time-colon" }, ":"),
          minDisplay,
        ),
        periodBadge,
      );

      const applyNow = () => {
        const now = new Date();
        let h24 = now.getHours();
        const p = h24 >= 12 ? "PM" : "AM";
        h24 = h24 % 12 || 12;
        const hStr = String(h24).padStart(2, "0");
        const mRounded = Math.round(now.getMinutes() / 5) * 5;
        const mStr = String(mRounded >= 60 ? 55 : mRounded).padStart(2, "0");
        selectTimeValues(hStr, mStr, p, true);
      };

      const presetChip = (chipLabel, hStr, mStr, pStr) =>
        h(
          "button",
          {
            type: "button",
            class: "preset-chip",
            onClick: (e) => {
              e.stopPropagation();
              selectTimeValues(hStr, mStr, pStr, true);
            },
          },
          chipLabel,
        );

      const timePresetsBar = h(
        "div",
        { class: "calendar-time-presets" },
        h(
          "button",
          {
            type: "button",
            class: "preset-chip",
            onClick: (e) => {
              e.stopPropagation();
              applyNow();
            },
          },
          "Now",
        ),
        presetChip("8:00 AM", "08", "00", "AM"),
        presetChip("1:00 PM", "01", "00", "PM"),
        presetChip("6:00 PM", "06", "00", "PM"),
      );

      const colLabels = h(
        "div",
        { class: "calendar-time-col-labels" },
        h("span", {}, "Hour"),
        h("span", {}, "Minute"),
      );

      hoursCol = h(
        "div",
        { class: "calendar-time-col hours-col" },
        ...hourBtns,
      );
      minutesCol = h(
        "div",
        { class: "calendar-time-col minutes-col" },
        ...minBtns,
      );

      const columnsGrid = h(
        "div",
        { class: "calendar-time-columns" },
        hoursCol,
        minutesCol,
      );

      const actionsBar = h(
        "div",
        { class: "calendar-time-actions" },
        h(
          "button",
          {
            type: "button",
            class: "preset-now-btn",
            onClick: (e) => {
              e.stopPropagation();
              applyNow();
            },
          },
          "Now",
        ),
        button({
          label: "Done",
          variant: "primary",
          size: "sm",
          onClick: (e) => {
            e.stopPropagation();
            toggleCalendar(false);
          },
        }),
      );

      const timePane = h(
        "div",
        { class: "calendar-time-pane" },
        timeHeader,
        displayCard,
        timeOnly ? timePresetsBar : null,
        colLabels,
        columnsGrid,
        actionsBar,
      );

      requestAnimationFrame(() => {
        hoursCol.querySelector(".is-selected")?.scrollIntoView({
          block: "center",
        });
        minutesCol.querySelector(".is-selected")?.scrollIntoView({
          block: "center",
        });
      });

      if (timeOnly) {
        popover.append(timePane);
        return;
      }

      const calendarMain = h(
        "div",
        { class: "calendar-main" },
        header,
        weekdaysRow,
        daysGrid,
        presetsBar,
      );
      popover.append(calendarMain, timePane);
      return;
    }

    if (pickMode === "years") {
      const minYear = min ? Number(min.slice(0, 4)) : viewYear - 100;
      const maxYear = max ? Number(max.slice(0, 4)) : viewYear + 20;
      const yearGrid = h("div", { class: "calendar-year-grid" });
      for (let y = maxYear; y >= minYear; y--) {
        yearGrid.append(
          h(
            "button",
            {
              type: "button",
              class: `calendar-year${y === viewYear ? " is-selected" : ""}`,
              onClick: (e) => {
                e.stopPropagation();
                viewYear = y;
                pickMode = "months";
                renderMonth();
              },
            },
            `${y}`,
          ),
        );
      }
      popover.append(header, yearGrid);
      requestAnimationFrame(() =>
        yearGrid.querySelector(".is-selected")?.scrollIntoView({
          block: "center",
        })
      );
      return;
    }
    if (pickMode === "months") {
      const monthGrid = h("div", { class: "calendar-month-grid" });
      MONTH_NAMES.forEach((name, i) => {
        monthGrid.append(
          h(
            "button",
            {
              type: "button",
              class: `calendar-year${i === viewMonth ? " is-selected" : ""}`,
              onClick: (e) => {
                e.stopPropagation();
                viewMonth = i;
                pickMode = "days";
                renderMonth();
              },
            },
            name.slice(0, 3),
          ),
        );
      });
      popover.append(header, monthGrid);
      return;
    }
    popover.append(header, weekdaysRow, daysGrid, presetsBar);
  };

  const position = dropdownPosition(triggerBtn, popover, { center: true });
  const closeOutside = (event) => {
    if (!container.contains(event.target)) toggleCalendar(false);
  };
  const closeOnEscape = (event) => {
    if (event.key !== "Escape") return;
    event.preventDefault();
    toggleCalendar(false);
    triggerBtn.focus();
  };
  const toggleCalendar = (show) => {
    isOpen = show;
    triggerBtn.setAttribute("aria-expanded", isOpen ? "true" : "false");
    if (isOpen) {
      pickMode = "days";
      renderMonth();
      popover.hidden = false;
      position.start();
      requestAnimationFrame(() => {
        popover.classList.add("is-open");
        if (includeTime || timeOnly) {
          popover.querySelector(".hours-col .is-selected")?.scrollIntoView({
            block: "center",
          });
          popover.querySelector(".minutes-col .is-selected")?.scrollIntoView({
            block: "center",
          });
        }
      });
      document.addEventListener("pointerdown", closeOutside);
      document.addEventListener("keydown", closeOnEscape);
    } else {
      document.removeEventListener("pointerdown", closeOutside);
      document.removeEventListener("keydown", closeOnEscape);
      popover.classList.remove("is-open");
      popover.hidden = true;
      position.stop();
    }
  };

  const container = h(
    "div",
    { class: "calendar-drop-container" },
    triggerBtn,
    popover,
  );

  const errorEl = h(
    "span",
    { class: "field-error", role: "alert", hidden: !error },
    error || "",
  );

  const wrapper = h(
    "div",
    { class: `field${error ? " field-error-state" : ""}` },
    label ? h("label", { for: id }, label, required ? " *" : "") : null,
    container,
    hiddenInput,
    hint ? h("span", { class: "field-hint" }, hint) : null,
    errorEl,
  );

  if (nativeInput) {
    nativeInput.removeAttribute("id");
    nativeInput.className = "searchable-select-native";
    nativeInput.setAttribute("tabindex", "-1");
    nativeInput.setAttribute("aria-hidden", "true");
    nativeInput.addEventListener("invalid", (event) => {
      event.preventDefault();
      errorEl.textContent = nativeInput.validationMessage ||
        (timeOnly
          ? "Choose a valid time."
          : (includeTime
            ? "Choose a valid date and time."
            : "Choose a valid date."));
      errorEl.hidden = false;
      triggerBtn.setAttribute("aria-invalid", "true");
      toggleCalendar(true);
    });
  }
  wrapper.refreshFromNative = () => {
    selectedStart = hiddenInput.value;
    if (timeOnly || includeTime) {
      parseDateTime(hiddenInput.value);
    }
    displayText.textContent = formatDisplay();
    triggerBtn.disabled = hiddenInput.disabled;
    if (hiddenInput.disabled && isOpen) toggleCalendar(false);
  };
  wrapper.inputEl = hiddenInput;
  Object.defineProperty(wrapper, "value", {
    get: () =>
      timeOnly
        ? getTimeString()
        : (includeTime ? getFullDateTimeString() : selectedStart),
    set: (v) => {
      selectedStart = v;
      if (timeOnly || includeTime) {
        parseDateTime(v);
      }
      hiddenInput.value = v;
      displayText.textContent = formatDisplay();
      if (isOpen) renderMonth();
    },
  });

  wrapper.setError = (errMsg) => {
    if (errMsg) {
      errorEl.textContent = errMsg;
      errorEl.hidden = false;
      wrapper.classList.add("field-error-state");
      triggerBtn.classList.add("is-invalid");
    } else {
      errorEl.textContent = "";
      errorEl.hidden = true;
      wrapper.classList.remove("field-error-state");
      triggerBtn.classList.remove("is-invalid");
    }
  };

  wrapper.setSuccess = (_msg = "") => {
    wrapper.setError("");
  };

  return wrapper;
}

export function dateRangePicker(
  {
    id,
    label,
    startValue = "",
    endValue = "",
    min,
    max,
    error,
    hint,
    required,
    disabled,
    onChange,
    presets = true,
  },
) {
  let start = startValue;
  let end = endValue;

  const startInput = h("input", {
    type: "date",
    class: "input",
    id: `${id}-start`,
    name: `${id}-start`,
    value: start,
    min,
    max,
    disabled,
    required,
    "aria-label": "Start Date",
    onChange: (e) => {
      start = e.target.value;
      onChange?.({ start, end });
    },
  });

  const endInput = h("input", {
    type: "date",
    class: "input",
    id: `${id}-end`,
    name: `${id}-end`,
    value: end,
    min,
    max,
    disabled,
    required,
    "aria-label": "End Date",
    onChange: (e) => {
      end = e.target.value;
      onChange?.({ start, end });
    },
  });

  let presetsEl = null;
  if (presets) {
    const applyPreset = (days) => {
      const today = new Date();
      const endD = today.toISOString().slice(0, 10);
      const startD = new Date(today.getTime() - days * 24 * 60 * 60 * 1000)
        .toISOString().slice(0, 10);
      start = startD;
      end = endD;
      startInput.value = start;
      endInput.value = end;
      onChange?.({ start, end });
    };

    presetsEl = h(
      "div",
      { class: "preset-chips" },
      h("button", {
        type: "button",
        class: "preset-chip",
        onClick: () => {
          const now = new Date();
          const first = new Date(now.getFullYear(), now.getMonth(), 1)
            .toISOString().slice(0, 10);
          start = first;
          end = now.toISOString().slice(0, 10);
          startInput.value = start;
          endInput.value = end;
          onChange?.({ start, end });
        },
      }, "This Month"),
      h("button", {
        type: "button",
        class: "preset-chip",
        onClick: () => applyPreset(30),
      }, "Last 30 Days"),
      h("button", {
        type: "button",
        class: "preset-chip",
        onClick: () => {
          start = "";
          end = "";
          startInput.value = "";
          endInput.value = "";
          onChange?.({ start, end });
        },
      }, "All Time"),
    );
  }

  return h(
    "div",
    { class: "field date-range-picker" },
    label ? h("label", {}, label, required ? " *" : "") : null,
    h(
      "div",
      { class: "date-range-inputs" },
      startInput,
      h("span", { class: "date-range-sep", "aria-hidden": "true" }, "→"),
      endInput,
    ),
    presetsEl,
    hint ? h("span", { class: "field-hint" }, hint) : null,
    error ? h("span", { class: "field-error" }, error) : null,
  );
}

export function fileUploadField(
  {
    id,
    label,
    accept = "image/*,.pdf",
    multiple = false,
    maxSizeMb = 5,
    dragAndDrop = true,
    preview = true,
    hint,
    error,
    required,
    disabled,
    onFiles,
  },
) {
  let fileList = [];
  const previewList = h("div", { class: "file-preview-list" });
  const progressBarEl = h("div", {
    class: "upload-progress-container",
    hidden: true,
  });

  const renderPreviews = () => {
    previewList.replaceChildren();
    fileList.forEach((file, idx) => {
      const isImg = file.type && file.type.startsWith("image/");
      let thumb = h("span", { class: "badge-icon" }, icon("file"));
      if (
        isImg && preview && typeof URL !== "undefined" && URL.createObjectURL
      ) {
        try {
          const url = URL.createObjectURL(file);
          thumb = h("img", { class: "file-thumb", src: url, alt: file.name });
        } catch {
          // Fallback to file icon
        }
      }
      const sizeKb = (file.size / 1024).toFixed(1);
      const row = h(
        "div",
        { class: "file-preview-item" },
        thumb,
        h(
          "div",
          { class: "grow" },
          h("div", { class: "file-name" }, file.name),
          h("span", { class: "muted" }, `${sizeKb} KB`),
        ),
        h("button", {
          class: "btn btn-icon",
          type: "button",
          "aria-label": `Remove ${file.name}`,
          title: "Remove",
          onClick: () => {
            fileList.splice(idx, 1);
            renderPreviews();
            onFiles?.(fileList);
          },
        }, icon("trash")),
      );
      previewList.append(row);
    });
  };

  const handleSelectedFiles = (newFiles) => {
    const valid = [];
    for (const f of newFiles) {
      if (f.size > maxSizeMb * 1024 * 1024) {
        toast(`File "${f.name}" exceeds ${maxSizeMb}MB limit.`, {
          tone: "error",
        });
        continue;
      }
      valid.push(f);
    }
    fileList = multiple ? [...fileList, ...valid] : valid.slice(0, 1);
    renderPreviews();
    onFiles?.(fileList);

    if (fileList.length > 0) {
      progressBarEl.hidden = false;
      progressBarEl.replaceChildren(
        progressBar({
          value: 45,
          label: "Simulating upload progress...",
          tone: "primary",
        }),
      );
      setTimeout(() => {
        progressBarEl.replaceChildren(
          progressBar({
            value: 100,
            label: "Ready to Upload",
            tone: "success",
          }),
        );
      }, 500);
    }
  };

  const inputEl = h("input", {
    type: "file",
    id,
    name: id,
    accept,
    multiple,
    disabled,
    required,
    hidden: true,
    onChange: (e) => handleSelectedFiles(Array.from(e.target.files ?? [])),
  });

  const dropzone = h(
    "div",
    {
      class: "file-dropzone",
      tabindex: disabled ? "-1" : "0",
      onClick: () => !disabled && inputEl.click(),
      onDragover: (e) => {
        if (!dragAndDrop) return;
        e.preventDefault();
        dropzone.classList.add("dragover");
      },
      onDragleave: () => dropzone.classList.remove("dragover"),
      onDrop: (e) => {
        if (!dragAndDrop) return;
        e.preventDefault();
        dropzone.classList.remove("dragover");
        if (disabled) return;
        if (e.dataTransfer?.files) {
          handleSelectedFiles(Array.from(e.dataTransfer.files));
        }
      },
    },
    h("span", { class: "badge-icon" }, icon("upload")),
    h(
      "div",
      { class: "dropzone-text" },
      h("strong", {}, "Click to upload"),
      " or drag and drop",
    ),
    h(
      "span",
      { class: "muted" },
      `Accepted formats: ${accept} (Max ${maxSizeMb}MB)`,
    ),
  );

  return h(
    "div",
    { class: `field${error ? " field-error-state" : ""}` },
    label ? h("label", { for: id }, label, required ? " *" : "") : null,
    inputEl,
    dropzone,
    progressBarEl,
    previewList,
    hint ? h("span", { class: "field-hint" }, hint) : null,
    error ? h("span", { class: "field-error", id: `${id}-err` }, error) : null,
  );
}

export function pageHeader(
  { icon: iconName, eyebrow, title, description, actions = [] },
) {
  return h(
    "div",
    { class: "page-header" },
    h(
      "div",
      { class: "lead" },
      iconName ? h("span", { class: "badge-icon" }, icon(iconName)) : null,
      h(
        "div",
        {},
        eyebrow ? h("div", { class: "eyebrow" }, eyebrow) : null,
        h("h1", { id: "page-title", tabindex: "-1" }, title),
        description ? h("p", { class: "muted" }, description) : null,
      ),
    ),
    h("div", { class: "actions" }, actions),
  );
}

const ADMIN_HERO_DATE = new Intl.DateTimeFormat("en-PH", {
  timeZone: "Asia/Manila",
  weekday: "short",
  month: "short",
  day: "numeric",
  year: "numeric",
});

/**
 * Admin page banner shared by every admin screen (same markup as the Members page): role, date and status chips,
 * the page title (the focus target for route changes), a short description and the page's primary actions.
 * `chip` is the status chip text, for example "Courts Management".
 */
export function adminHero(
  { title, description, chip, actions = [], roleLabel = "Admin Console" },
) {
  return h(
    "section",
    { class: "dash-hero is-admin", "aria-label": title },
    h(
      "div",
      { class: "dash-hero-copy" },
      h(
        "div",
        { class: "dash-hero-chips" },
        h(
          "span",
          { class: "dash-chip is-role" },
          icon("medal"),
          roleLabel,
        ),
        h(
          "span",
          { class: "dash-chip is-date" },
          icon("calendar"),
          ADMIN_HERO_DATE.format(new Date()),
        ),
        h(
          "span",
          { class: "dash-chip is-status" },
          h("span", { class: "status-dot-pulse", "aria-hidden": "true" }),
          chip ?? title,
        ),
      ),
      h(
        "h1",
        { class: "dash-hero-title", id: "page-title", tabindex: "-1" },
        title,
      ),
      description ? h("p", { class: "dash-hero-sub" }, description) : null,
    ),
    actions.length ? h("div", { class: "dash-hero-actions" }, actions) : null,
  );
}

/**
 * Member page banner shared across member screens (dash-hero styling): eyebrow role/section chip with icon,
 * current Manila date chip, status pulse chip, page title, description, and optional actions.
 */
export function memberHero({
  eyebrow = "Play",
  title,
  description,
  chip = "Court Availability",
  iconName = "calendar",
  actions = [],
  titleBadge = false,
  publicHeader = false,
}) {
  const heading = h(
    "h1",
    { class: "dash-hero-title", id: "page-title", tabindex: "-1" },
    title,
  );
  return h(
    "section",
    {
      class: `dash-hero is-plain${publicHeader ? " public-page-hero" : ""}`,
      "aria-label": title,
    },
    publicHeader
      ? h("img", {
        class: "member-header-logo public-header-logo",
        src: "icons/cpc-logo-256.webp",
        alt: "Capitol Pickleball Club",
        width: 128,
        height: 128,
      })
      : null,
    h(
      "div",
      { class: "dash-hero-copy" },
      h(
        "div",
        { class: "dash-hero-chips" },
        eyebrow
          ? h(
            "span",
            { class: "dash-chip is-role" },
            icon(iconName),
            eyebrow,
          )
          : null,
        h(
          "span",
          { class: "dash-chip is-date" },
          icon("calendar"),
          ADMIN_HERO_DATE.format(new Date()),
        ),
        chip
          ? h(
            "span",
            { class: "dash-chip is-status" },
            h("span", { class: "status-dot-pulse", "aria-hidden": "true" }),
            chip,
          )
          : null,
      ),
      titleBadge
        ? h(
          "div",
          { class: "member-hero-heading" },
          heading,
          h(
            "span",
            { class: "dash-chip mobile-title-badge" },
            icon(iconName),
            eyebrow,
          ),
        )
        : heading,
      description ? h("p", { class: "dash-hero-sub" }, description) : null,
    ),
    actions.length ? h("div", { class: "dash-hero-actions" }, actions) : null,
  );
}

/**
 * Summary card with the Members page look, for numbers that are not filters (no link). `tone` is "emerald", "amber",
 * "teal" or "rose"; `text` shrinks the value for dates and words; `loading` shows a skeleton instead of the value.
 */
export function adminStatCard(
  {
    label,
    value,
    hint,
    iconName,
    tone = "emerald",
    pill,
    text = false,
    loading = false,
  },
) {
  return h(
    "div",
    {
      class: `home-card member-stat-card is-tone-${tone}${
        text ? " is-text" : ""
      }`,
      "aria-busy": loading ? "true" : "false",
    },
    h(
      "div",
      { class: "member-stat-main" },
      h(
        "span",
        { class: "home-card-icon", "aria-hidden": "true" },
        icon(iconName),
      ),
      h(
        "div",
        { class: "member-stat-copy" },
        loading
          ? h("span", { class: "sk sk-stat-value" })
          : h("span", { class: "home-card-value" }, String(value ?? "—")),
        h("span", { class: "home-card-label" }, label),
      ),
      loading ? null : pill,
    ),
    h(
      "div",
      { class: "home-card-bottom" },
      h("div", { class: "home-card-hint" }, hint),
    ),
  );
}

export function kpiCard(label, value, opts = {}) {
  const iconName = opts.icon;
  const tone = opts.tone ? ` kpi-${opts.tone}` : "";
  const alert = opts.alert ? " is-alert" : "";
  return h(
    "div",
    { class: `card kpi${tone}${alert}` },
    h(
      "div",
      { class: "kpi-header" },
      h("div", { class: "label" }, label),
      iconName
        ? h(
          "span",
          { class: `kpi-icon${opts.tone ? ` ${opts.tone}` : ""}` },
          icon(iconName),
        )
        : null,
    ),
    h("div", { class: "value" }, value),
  );
}

export function toolbar(
  {
    searchId = "search",
    searchLabel = "Search",
    onSearch,
    filters = [],
    actions = [],
  },
) {
  return h(
    "div",
    { class: "toolbar" },
    h(
      "div",
      { class: "grow field" },
      h("label", { for: searchId, class: "muted" }, searchLabel),
      searchControl({
        class: "input",
        id: searchId,
        type: "search",
        placeholder: `${searchLabel}…`,
        onInput: (e) => onSearch?.(e.target.value),
      }),
    ),
    filters,
    h("div", { class: "actions" }, actions),
  );
}

const PHP = new Intl.NumberFormat("en-PH", {
  style: "currency",
  currency: "PHP",
});

/**
 * Grid table. `schema.columns` drives the header, the rows, and the skeleton,
 * so all three share one column definition.
 * column: { key, label, align?: "left"|"right"|"center", kind?: "text"|"money", render?(row),
 *   skeleton?: "member"|"badge"|"text"|"date"|"stack"|"badge-stack"|"actions", actionCount?: number }
 *   `skeleton` says what the loading placeholder looks like (default: from key/label); `actionCount` is how many
 *   icon buttons the Action column shows, so the placeholder reserves the same number.
 * schema.actions: array of { label, icon, onClick(row) } rendered icon-only.
 * state: "loading" | "error" | "ready"
 * Search defaults on. Use searchable:false only beside an existing full-list search.
 * searchState: page-owned object retaining query across refresh; searchKey separates nested lists.
 */
export function dataTable(
  {
    schema,
    rows = [],
    state = "ready",
    hasFilters = false,
    onRetry,
    onReset,
    emptyTitle,
    emptyText,
    resetLabel = "Reset Filters",
    ariaLabel,
    searchable = true,
    searchPlaceholder,
    filter,
    searchActions,
    searchState,
    pageSize = DEFAULT_PAGE_SIZE,
    searchKey = ariaLabel ??
      schema.columns.map((column) => column.key).join(":"),
  },
) {
  const cols = schema.columns.map(tableColumn);
  const primaryColumn =
    cols.find((column) =>
      /^(name|member|player|team|event|division|when|change)$/.test(column.key)
    ) ?? cols.find((column) => !column.actions);
  const mobileKind = (column) =>
    column.actions
      ? "actions"
      : column === primaryColumn
      ? "primary"
      : /^(status|state)$/.test(column.key)
      ? "status"
      : "detail";
  const actions = schema.actions ?? [];
  const cls = `tbl cols-${cols.length}${
    actions.length ? ` act-${actions.length}` : ""
  }`;
  const table = h("div", {
    class: cls,
    role: "table",
    "aria-label": ariaLabel ?? "Data Table",
    "aria-busy": state === "loading" ? "true" : "false",
  });

  const head = h("div", { class: "tbl-row tbl-head", role: "row" });
  for (const c of cols) {
    head.append(
      h(
        "div",
        {
          class: `tbl-cell ${c.align}${c.actions ? " tbl-actions" : ""}`,
          role: "columnheader",
          title: c.label,
        },
        c.label,
      ),
    );
  }
  if (actions.length) {
    head.append(
      h(
        "div",
        { class: "tbl-cell center tbl-actions", role: "columnheader" },
        "Action",
      ),
    );
  }
  table.append(head);

  const body = h("div", { class: "tbl-body", role: "rowgroup" });
  const records = [];
  const readText = (node) => {
    const children = [...(node.childNodes ?? node.children ?? [])];
    return children.length
      ? children.map(readText).join(" ")
      : node.textContent ?? "";
  };
  const normalize = (text) =>
    String(text).normalize("NFKD").replace(/\p{M}/gu, "").toLocaleLowerCase();
  if (state === "loading") {
    for (let i = 0; i < 5; i++) {
      const row = h("div", {
        class: "tbl-row",
        role: "row",
        "aria-hidden": "true",
      });
      for (const c of cols) {
        let bar;
        const shape = c.skeleton;
        if (shape === "member") {
          bar = h(
            "div",
            { class: "sk-member-cell" },
            h("span", { class: "sk sk-avatar round" }),
            h(
              "div",
              { class: "sk-meta" },
              h("span", { class: `sk ${i % 2 ? "w-70" : "w-50"}` }),
              h("span", { class: "sk w-30 sk-sub" }),
            ),
          );
        } else if (shape === "stack") {
          bar = h(
            "div",
            { class: "sk-meta" },
            h("span", { class: `sk ${i % 2 ? "w-70" : "w-50"}` }),
            h("span", { class: "sk w-30 sk-sub" }),
          );
        } else if (shape === "badge-stack") {
          bar = h(
            "div",
            { class: "sk-meta" },
            h("span", { class: "sk sk-pill" }),
            h("span", { class: "sk w-30 sk-sub" }),
          );
        } else if (shape === "badge") {
          bar = h("span", { class: "sk sk-pill" });
        } else if (shape === "actions") {
          bar = h(
            "div",
            { class: "row-actions" },
            ...Array.from(
              { length: c.actionCount ?? 2 },
              () => h("span", { class: "sk sk-action" }),
            ),
          );
        } else if (shape === "date") {
          bar = h("span", { class: "sk w-50" });
        } else {
          bar = h("span", {
            class: `sk ${
              c.kind === "money" || c.align === "right"
                ? "r w-30"
                : i % 2
                ? "w-50"
                : "w-70"
            }`,
          });
        }
        row.append(
          h("div", {
            class: `tbl-cell ${c.align}${c.actions ? " tbl-actions" : ""}`,
            "data-label": c.label,
            "data-mobile-kind": mobileKind(c),
          }, bar),
        );
      }
      if (actions.length) {
        row.append(h(
          "div",
          { class: "tbl-cell center tbl-actions" },
          actions.map(() => h("span", { class: "sk sk-action" })),
        ));
      }
      body.append(row);
    }
  } else if (state === "error") {
    body.append(
      h(
        "div",
        { class: "tbl-state error", role: "alert" },
        h("span", { class: "badge-icon" }, icon("alert")),
        h("h2", {}, "Could not load data"),
        h(
          "p",
          { class: "muted" },
          "Something went wrong. Your data is safe. Try again.",
        ),
        onRetry
          ? button({ label: "Retry", icon: "refresh", onClick: onRetry })
          : null,
      ),
    );
  } else if (rows.length === 0) {
    body.append(
      h(
        "div",
        { class: "tbl-state" },
        h("span", { class: "badge-icon" }, icon("inbox")),
        h("h2", {}, emptyTitle ?? "No records found"),
        h(
          "p",
          { class: "muted" },
          hasFilters
            ? "No records match the current filters."
            : (emptyText ?? "No records exist yet."),
        ),
        hasFilters && onReset
          ? button({ label: resetLabel, icon: "refresh", onClick: onReset })
          : null,
      ),
    );
  } else {
    for (const r of rows) {
      const searchableValues = [];
      const row = h("div", { class: "tbl-row", role: "row" });
      for (const c of cols) {
        let content;
        if (c.render) content = c.render(r);
        else if (c.kind === "money") content = PHP.format(r[c.key]);
        else content = r[c.key];
        if (
          c === primaryColumn &&
          !content?.querySelector?.(".member-avatar, .avatar-lg")
        ) {
          const symbol = /rank|leaderboard/i.test(ariaLabel ?? "")
            ? "medal"
            : /event|division|match|bracket/i.test(ariaLabel ?? "")
            ? "trophy"
            : "clock";
          content = h(
            "div",
            { class: "mobile-record-identity" },
            h("span", {
              class: "member-avatar is-icon mobile-record-icon",
              "aria-hidden": "true",
            }, icon(symbol)),
            h("div", { class: "mobile-record-summary" }, content),
          );
        }
        if (c.actions) {
          const group = h("div", { class: "row-actions" }, content);
          const buttons = group.querySelectorAll("button, a.btn");
          c.actionCount = Math.max(c.actionCount, buttons.length);
          content = group;
        }
        const cell = h("div", {
          class: `tbl-cell ${c.align}${c.actions ? " tbl-actions" : ""}`,
          role: "cell",
          "data-label": c.label,
          "data-mobile-kind": mobileKind(c),
        }, content);
        if (!c.actions) searchableValues.push(readText(cell));
        row.append(cell);
      }
      if (actions.length) {
        row.append(
          h(
            "div",
            {
              class: "tbl-cell center tbl-actions",
              role: "cell",
              "data-label": "Action",
            },
            actions.map((a) =>
              iconButton({
                label: a.label,
                icon: a.icon,
                variant: a.variant ?? "secondary",
                onClick: () => a.onClick(r),
              })
            ),
          ),
        );
      }
      records.push({ node: row, text: normalize(searchableValues.join(" ")) });
      body.append(row);
    }
  }
  table.append(body);
  const layout = [
    ...cols,
    ...(actions.length
      ? [tableColumn({ key: "actions", actionCount: actions.length })]
      : []),
  ];
  table.style.setProperty("--tbl-grid", tableTracks(layout).join(" "));
  table.style.setProperty("--tbl-min", `${tableMinWidth(layout)}px`);
  const scroll = h("div", {
    class: "table-scroll",
    role: "region",
    "aria-label": ariaLabel ?? "Data Table",
    tabindex: "0",
  }, table);
  if (!searchable && pageSize <= 0) {
    return h("div", { class: "data-grid" }, scroll);
  }

  let saved = searchState ? tableSearches.get(searchState) : null;
  if (searchState && !saved) {
    saved = new Map();
    tableSearches.set(searchState, saved);
  }
  let savedPages = searchState ? tablePages.get(searchState) : null;
  if (searchState && !savedPages) {
    savedPages = new Map();
    tablePages.set(searchState, savedPages);
  }
  let currentPage = savedPages?.get(searchKey) ?? 1;
  const pagerHost = pageSize > 0 ? h("div", { class: "grid-pager" }) : null;
  const search = searchControl({
    class: "input",
    placeholder: searchPlaceholder ??
      `Search ${(ariaLabel ?? "records").toLocaleLowerCase()}\u2026`,
    "aria-label": `Search ${ariaLabel ?? "records"}`,
    value: saved?.get(searchKey) ?? "",
    disabled: state === "loading" || state === "error",
    onInput: () => {
      currentPage = 1;
      applySearch();
    },
  });
  const empty = h(
    "div",
    { class: "tbl-state tbl-search-empty", role: "status", hidden: true },
    h("span", { class: "badge-icon" }, icon("search")),
    h("h2", {}, "No matching records"),
    h("p", { class: "muted" }, "Try another search or clear the search box."),
    button({
      label: "Clear Search",
      icon: "x",
      onClick: () => {
        search.value = "";
        currentPage = 1;
        applySearch();
        search.focus();
      },
    }),
  );
  body.append(empty);
  function applySearch() {
    const mobile = globalThis.matchMedia?.("(max-width: 720px)").matches ??
      false;
    const visiblePageSize = mobile ? 0 : pageSize;
    const terms = normalize(search.value).trim().split(/\s+/).filter(Boolean);
    const matches = records.filter((record) =>
      terms.every((term) => record.text.includes(term))
    );
    if (state !== "loading" && state !== "error") {
      currentPage = Math.min(
        Math.max(1, currentPage),
        Math.max(
          1,
          Math.ceil(matches.length / (visiblePageSize || matches.length || 1)),
        ),
      );
      savedPages?.set(searchKey, currentPage);
    }
    for (const record of records) record.node.hidden = true;
    const visible = visiblePageSize > 0
      ? matches.slice(
        (currentPage - 1) * visiblePageSize,
        currentPage * visiblePageSize,
      )
      : matches;
    for (const record of visible) record.node.hidden = false;
    saved?.set(searchKey, search.value);
    empty.hidden = !records.length || matches.length > 0;
    if (pagerHost) {
      pagerHost.hidden = mobile;
      pagerHost.replaceChildren(
        ...(mobile || state === "loading" || state === "error"
          ? []
          : [pagination({
            page: currentPage,
            pageSize,
            total: matches.length,
            onPage: (next) => {
              currentPage = next;
              applySearch();
            },
          })]),
      );
    }
  }
  applySearch();
  if (typeof ResizeObserver === "function") {
    let mobile = globalThis.matchMedia?.("(max-width: 720px)").matches ?? false;
    const observer = new ResizeObserver(() => {
      if (!scroll.isConnected) {
        observer.disconnect();
        return;
      }
      const nextMobile =
        globalThis.matchMedia?.("(max-width: 720px)").matches ?? false;
      if (nextMobile !== mobile) {
        mobile = nextMobile;
        applySearch();
      }
    });
    observer.observe(scroll);
  }
  if (!searchable) return h("div", { class: "data-grid" }, scroll, pagerHost);
  return h(
    "div",
    { class: "data-grid-layout" },
    h(
      "div",
      {
        class:
          "toolbar admin-members-toolbar data-grid-toolbar has-status-badges",
      },
      search,
      searchActions,
      filter,
    ),
    h("div", { class: "data-grid" }, scroll, pagerHost),
  );
}

/** Footer with the visible range and total; never shows "1–0". */
export function pagination(
  {
    page = 1,
    pageSize = DEFAULT_PAGE_SIZE,
    total,
    onPage,
    compactMobile = false,
  },
) {
  if (total <= 0) return h("div", { class: "pager", hidden: true });
  const pages = Math.max(1, Math.ceil(total / pageSize));
  const current = Math.min(Math.max(page, 1), pages);
  const from = total === 0 ? 0 : (current - 1) * pageSize + 1;
  const to = Math.min(current * pageSize, total);
  const nav = h("div", {
    class: "pages",
    role: "navigation",
    "aria-label": "Pagination",
  });
  nav.append(
    h("button", {
      class: "btn btn-icon",
      type: "button",
      "aria-label": "Previous Page",
      disabled: current === 1,
      onClick: () => onPage(current - 1),
    }, icon("chevl")),
  );
  const first = Math.max(1, Math.min(current - 2, pages - 4));
  const mobileFirst = Math.max(1, Math.min(current - 1, pages - 2));
  for (let p = first; p <= Math.min(pages, first + 4); p++) {
    nav.append(
      h("button", {
        class: `btn btn-icon${
          compactMobile && (p < mobileFirst || p > mobileFirst + 2)
            ? " pager-extra-page"
            : ""
        }`,
        type: "button",
        "aria-label": `Page ${p}`,
        "aria-current": p === current ? "page" : null,
        onClick: () => onPage(p),
      }, String(p)),
    );
  }
  nav.append(
    h("button", {
      class: "btn btn-icon",
      type: "button",
      "aria-label": "Next Page",
      disabled: current === pages,
      onClick: () => onPage(current + 1),
    }, icon("chevr")),
  );
  return h(
    "div",
    { class: `pager${compactMobile ? " is-mobile-compact" : ""}` },
    h(
      "span",
      { class: "pager-summary", role: "status", "aria-live": "polite" },
      h(
        "span",
        { class: "pager-range" },
        h("strong", {}, `${from}\u2013${to}`),
        h("span", {}, "of"),
        h("strong", {}, String(total)),
        h("span", {}, total === 1 ? "record" : "records"),
      ),
      h("span", { class: "pager-size" }, `${pageSize} records per page`),
    ),
    nav,
  );
}

/** Native <dialog>: focus is contained, Escape closes, focus returns to the opener. */
export function openModal(
  {
    title,
    eyebrow,
    description,
    icon: iconName = "info",
    body,
    size = "md",
    confirmLabel = "Save",
    cancelLabel = "Cancel",
    destructive = false,
    tone,
    onConfirm,
  },
) {
  const opener = document.activeElement;
  const titleId = `modal-title-${Math.random().toString(36).slice(2, 8)}`;
  const effectiveTone = tone || (destructive ? "danger" : "neutral");
  const dialog = h("dialog", {
    class: `modal modal-${size} modal-tone-${effectiveTone}`,
    "aria-labelledby": titleId,
  });

  const confirmBtnClass = buttonClasses({
    variant: destructive || effectiveTone === "danger"
      ? "danger"
      : ["warning", "archive", "success"].includes(effectiveTone)
      ? effectiveTone
      : "primary",
  });

  const isDuplicateClose = Boolean(
    confirmLabel &&
      cancelLabel &&
      String(confirmLabel).trim().toLowerCase() ===
        String(cancelLabel).trim().toLowerCase(),
  );

  const confirm = confirmLabel
    ? h("button", {
      class: confirmBtnClass,
      type: "submit",
    }, confirmLabel)
    : null;

  const close = () => dialog.close();

  const cancelBtn = (cancelLabel && !isDuplicateClose)
    ? h(
      "button",
      {
        class: buttonClasses({ variant: "outline" }),
        type: "button",
        onClick: close,
      },
      cancelLabel,
    )
    : null;

  const form = h(
    "form",
    { class: "modal-form", method: "dialog" },
    h(
      "div",
      { class: "modal-head" },
      h(
        "span",
        { class: `badge-icon is-${effectiveTone}` },
        icon(iconName, { solid: true }),
      ),
      h(
        "div",
        { class: "grow" },
        eyebrow ? h("div", { class: "eyebrow" }, eyebrow) : null,
        h("h2", { id: titleId }, title),
        description ? h("p", { class: "muted" }, description) : null,
      ),
      h("button", {
        class: "modal-close-btn",
        type: "button",
        "aria-label": "Close Modal",
        title: "Close",
        onClick: close,
      }, icon("x")),
    ),
    h("div", { class: "modal-body" }, body),
    h(
      "div",
      { class: "modal-foot" },
      cancelBtn,
      confirm,
    ),
  );
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!confirm) {
      dialog.close();
      return;
    }
    if (confirm.dataset?.pending === "true") return;
    if (confirm.dataset) confirm.dataset.pending = "true";
    confirm.setAttribute("aria-busy", "true");
    confirm.disabled = true;
    try {
      let formData;
      try {
        formData = typeof HTMLFormElement !== "undefined" &&
            form instanceof HTMLFormElement
          ? new FormData(form)
          : new FormData();
      } catch {
        formData = new FormData();
      }
      const keepOpen = await onConfirm?.(formData);
      if (keepOpen !== false) dialog.close();
    } finally {
      if (confirm.dataset) delete confirm.dataset.pending;
      confirm.removeAttribute("aria-busy");
      confirm.disabled = false;
    }
  });
  dialog.addEventListener("click", (e) => {
    if (e.target === dialog) close();
  });
  dialog.addEventListener("close", () => {
    dialog.remove();
    opener?.focus?.();
  });
  dialog.append(form);
  document.body.append(dialog);
  dialog.showModal();
  const firstControl = dialog.querySelector(
    ".modal-body input:not([type=hidden]):not(:disabled):not([readonly]), .modal-body textarea:not(:disabled):not([readonly]), .modal-body .searchable-select-trigger:not(:disabled)",
  );
  firstControl?.focus?.();
  return dialog;
}

export function confirmModal(
  {
    title = "Are you sure?",
    eyebrow,
    message,
    icon: iconName = "alert",
    confirmLabel = "Confirm",
    cancelLabel = "Cancel",
    destructive = false,
    onConfirm,
  },
) {
  const body = h("p", { class: "modal-confirm-msg" }, message);
  return openModal({
    title,
    eyebrow,
    description: null,
    icon: iconName,
    body,
    size: "sm",
    confirmLabel,
    cancelLabel,
    destructive,
    onConfirm,
  });
}

export function openDrawer(
  {
    title,
    eyebrow,
    description,
    icon: iconName = "info",
    body,
    position = "right",
    onClose,
  },
) {
  const opener = document.activeElement;
  const titleId = `drawer-title-${Math.random().toString(36).slice(2, 8)}`;
  const dialog = h("dialog", {
    class: `drawer drawer-${position}`,
    "aria-labelledby": titleId,
  });
  const close = () => dialog.close();
  const content = h(
    "div",
    { class: "drawer-content" },
    h(
      "div",
      { class: "modal-head" },
      iconName ? h("span", { class: "badge-icon" }, icon(iconName)) : null,
      h(
        "div",
        { class: "grow" },
        eyebrow ? h("div", { class: "eyebrow" }, eyebrow) : null,
        h("h2", { id: titleId }, title),
        description ? h("p", { class: "muted" }, description) : null,
      ),
      h("button", {
        class: "btn btn-icon",
        type: "button",
        "aria-label": "Close Drawer",
        title: "Close",
        onClick: close,
      }, icon("x")),
    ),
    h("div", { class: "modal-body" }, body),
  );
  dialog.addEventListener("click", (e) => {
    if (e.target === dialog) close();
  });
  dialog.addEventListener("close", () => {
    dialog.remove();
    onClose?.();
    opener?.focus?.();
  });
  dialog.append(content);
  document.body.append(dialog);
  dialog.showModal();
  return dialog;
}

export function tooltip({ text, element }) {
  if (!element || !text) return element;
  element.setAttribute("title", text);
  element.setAttribute("aria-label", text);
  return element;
}

export function popover({ trigger, content, placement = "bottom" }) {
  const popoverEl = h(
    "div",
    {
      class: `popover-content popover-${placement}`,
      role: "region",
      hidden: true,
    },
    content,
  );
  const wrapper = h("div", { class: "popover-wrap" }, trigger, popoverEl);
  const toggle = () => {
    const isHidden = popoverEl.hasAttribute("hidden");
    if (isHidden) {
      popoverEl.removeAttribute("hidden");
      trigger.setAttribute("aria-expanded", "true");
    } else {
      popoverEl.setAttribute("hidden", "");
      trigger.setAttribute("aria-expanded", "false");
    }
  };
  trigger.addEventListener("click", (e) => {
    e.stopPropagation();
    toggle();
  });
  document.addEventListener("click", (e) => {
    if (!wrapper.contains(e.target) && !popoverEl.hasAttribute("hidden")) {
      popoverEl.setAttribute("hidden", "");
      trigger.setAttribute("aria-expanded", "false");
    }
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && !popoverEl.hasAttribute("hidden")) {
      popoverEl.setAttribute("hidden", "");
      trigger.setAttribute("aria-expanded", "false");
      trigger.focus();
    }
  });
  return wrapper;
}

export function dropdownMenu({ trigger, items = [] }) {
  const menuEl = h("div", {
    class: "dropdown-menu-list",
    role: "menu",
    hidden: true,
  });
  const position = dropdownPosition(trigger, menuEl);
  for (const item of items) {
    if (item.divider) {
      menuEl.append(h("div", { class: "dropdown-divider", role: "separator" }));
      continue;
    }
    const btn = h(
      "button",
      {
        class: `dropdown-item${item.danger ? " is-danger" : ""}`,
        role: "menuitem",
        type: "button",
        disabled: item.disabled,
        onClick: (e) => {
          e.stopPropagation();
          menuEl.setAttribute("hidden", "");
          position.stop();
          trigger.setAttribute("aria-expanded", "false");
          item.onClick?.(e);
        },
      },
      item.icon ? icon(item.icon) : null,
      h("span", {}, item.label),
    );
    menuEl.append(btn);
  }
  const wrapper = h("div", { class: "dropdown-wrap" }, trigger, menuEl);
  trigger.addEventListener("click", (e) => {
    e.stopPropagation();
    const isHidden = menuEl.hasAttribute("hidden");
    if (isHidden) {
      menuEl.removeAttribute("hidden");
      position.start();
      trigger.setAttribute("aria-expanded", "true");
    } else {
      menuEl.setAttribute("hidden", "");
      position.stop();
      trigger.setAttribute("aria-expanded", "false");
    }
  });
  document.addEventListener("click", (e) => {
    if (!wrapper.contains(e.target) && !menuEl.hasAttribute("hidden")) {
      menuEl.setAttribute("hidden", "");
      position.stop();
      trigger.setAttribute("aria-expanded", "false");
    }
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && !menuEl.hasAttribute("hidden")) {
      menuEl.setAttribute("hidden", "");
      position.stop();
      trigger.setAttribute("aria-expanded", "false");
      trigger.focus();
    }
  });
  return wrapper;
}

export function dropdownAction(
  {
    label = "Actions",
    icon: iconName,
    variant = "secondary",
    size = "default",
    items = [],
  },
) {
  const btn = button({
    label,
    variant,
    size,
    icon: iconName,
    iconPosition: "left",
    onClick: () => {},
  });
  btn.append(icon("chevronDown"));
  btn.setAttribute("aria-haspopup", "true");
  btn.setAttribute("aria-expanded", "false");
  return dropdownMenu({ trigger: btn, items });
}

export function toast(
  message,
  {
    tone = "info",
    title,
    actionLabel,
    onAction,
    timeout,
  } = {},
) {
  const toastContainer = document.getElementById("toasts");
  const sentenceCase = (text) =>
    typeof text === "string"
      ? text.replace(
        /^(\s*)([a-z])/,
        (_, space, first) => space + first.toUpperCase(),
      )
      : text;
  const iconName = tone === "success"
    ? "checkCircle"
    : tone === "error"
    ? "alertCircle"
    : tone === "warning"
    ? "alertTriangle"
    : "info";

  const el = h(
    "div",
    {
      class: `toast toast-${tone}`,
      role: tone === "error" || tone === "warning" ? "alert" : "status",
      "aria-live": tone === "error" || tone === "warning"
        ? "assertive"
        : "polite",
    },
    h("span", { class: "toast-icon" }, icon(iconName)),
    h(
      "div",
      { class: "toast-body" },
      title ? h("div", { class: "toast-title" }, sentenceCase(title)) : null,
      h("div", { class: "toast-msg" }, sentenceCase(message)),
    ),
  );

  const dismiss = () => {
    if (el.classList.contains("toast-exit")) return;
    el.classList.add("toast-exit");
    setTimeout(() => {
      if (el.parentNode) el.remove();
    }, 220);
  };

  if (actionLabel) {
    el.append(
      button({
        label: actionLabel,
        variant: "primary",
        size: "sm",
        onClick: () => {
          onAction?.();
          dismiss();
        },
      }),
    );
  }

  const closeBtn = h(
    "button",
    {
      class: "toast-close-btn",
      type: "button",
      "aria-label": "Dismiss Notification",
      title: "Dismiss",
      onClick: dismiss,
    },
    icon("x"),
  );
  el.append(closeBtn);

  if (toastContainer) {
    toastContainer.append(el);
  } else {
    document.body.append(el);
  }

  // A toast with an action stays until used or closed, unless the caller sets a timeout.
  const hideAfter = timeout ?? (actionLabel ? 0 : 5000);
  if (hideAfter > 0) {
    setTimeout(() => {
      if (el.parentNode) dismiss();
    }, hideAfter);
  }
  return el;
}

export function alertBox(
  {
    tone = "info",
    title,
    message,
    actions = [],
    dismissible = false,
    onDismiss,
    icon: iconName,
  },
) {
  const defaultIcon = tone === "success"
    ? "checkCircle"
    : tone === "error"
    ? "alertCircle"
    : tone === "warning"
    ? "alertTriangle"
    : "info";

  const el = h(
    "div",
    {
      class: `alert alert-${tone}`,
      role: tone === "error" ? "alert" : "status",
    },
    h("span", { class: "alert-icon" }, icon(iconName ?? defaultIcon)),
    h(
      "div",
      { class: "alert-content" },
      title ? h("div", { class: "alert-title" }, title) : null,
      message ? h("div", { class: "alert-message" }, message) : null,
      actions.length
        ? h("div", { class: "alert-actions actions" }, ...actions)
        : null,
    ),
    dismissible
      ? h("button", {
        class: "btn btn-icon alert-dismiss",
        type: "button",
        "aria-label": "Dismiss Alert",
        title: "Dismiss",
        onClick: () => {
          if (el.classList.contains("alert-exit")) return;
          el.classList.add("alert-exit");
          setTimeout(() => {
            el.remove();
            onDismiss?.();
          }, 200);
        },
      }, icon("x"))
      : null,
  );
  return el;
}

export function banner(
  {
    tone = "info",
    message,
    actionLabel,
    onAction,
    dismissible = true,
    onDismiss,
  },
) {
  const el = h(
    "div",
    {
      class: `banner banner-${tone}`,
      role: "region",
      "aria-label": "Announcement",
    },
    h("span", { class: "banner-text" }, message),
    h(
      "div",
      { class: "banner-actions actions" },
      actionLabel
        ? button({
          label: actionLabel,
          variant: "outline",
          size: "sm",
          onClick: onAction,
        })
        : null,
      dismissible
        ? h("button", {
          class: "btn btn-icon",
          type: "button",
          "aria-label": "Dismiss Announcement",
          title: "Dismiss",
          onClick: () => {
            el.remove();
            onDismiss?.();
          },
        }, icon("x"))
        : null,
    ),
  );
  return el;
}

export function validationSummary(
  {
    title = "Please correct the following errors:",
    errors = [],
  },
) {
  if (!errors.length) return null;
  const list = h(
    "ul",
    { class: "validation-summary-list" },
    ...errors.map((err) => h("li", {}, err)),
  );
  return h(
    "div",
    { class: "validation-summary", role: "alert", "aria-live": "assertive" },
    h("div", { class: "validation-summary-title" }, title),
    list,
  );
}

export function progressBar(
  {
    value = 0,
    max = 100,
    tone = "primary",
    label,
    showPercent = true,
    indeterminate = false,
  },
) {
  const pct = Math.max(0, Math.min(100, Math.round((value / max) * 100)));
  const fill = h("div", { class: "progress-bar-fill" });
  if (!indeterminate) fill.style.width = `${pct}%`;
  return h(
    "div",
    { class: "progress-bar-wrap" },
    label || showPercent
      ? h(
        "div",
        { class: "progress-bar-header" },
        label ? h("span", { class: "progress-bar-label" }, label) : null,
        !indeterminate && showPercent
          ? h("span", { class: "progress-bar-pct" }, `${pct}%`)
          : null,
      )
      : null,
    h(
      "div",
      {
        class: `progress-bar progress-bar-${tone}${
          indeterminate ? " is-indeterminate" : ""
        }`,
        role: "progressbar",
        "aria-valuenow": indeterminate ? null : value,
        "aria-valuemin": 0,
        "aria-valuemax": max,
        "aria-label": label ?? "Progress",
      },
      fill,
    ),
  );
}

export function spinner(
  {
    size = "md",
    label = "Loading...",
    tone = "primary",
  },
) {
  return h(
    "div",
    {
      class: `spinner-wrap spinner-${size} tone-${tone}`,
      role: "status",
      "aria-label": label,
    },
    h("span", { class: "spinner" }),
    label ? h("span", { class: "spinner-label muted" }, label) : null,
  );
}

export function skeleton(
  {
    variant = "text",
    width,
    height,
    count = 1,
    className = "",
  },
) {
  const items = [];
  for (let i = 0; i < count; i++) {
    const item = h("span", {
      class: `sk sk-${variant} ${className}`.trim(),
      "aria-hidden": "true",
    });
    if (width) item.style.width = width;
    if (height) item.style.height = height;
    items.push(item);
  }
  return items.length === 1
    ? items[0]
    : h("div", { class: "sk-group", "aria-hidden": "true" }, ...items);
}

export function emptyState(
  {
    icon: iconName = "inbox",
    title = "No records found",
    description,
    action,
    resetLabel,
    onReset,
  },
) {
  return h(
    "div",
    { class: "empty-state" },
    h("span", { class: "badge-icon" }, icon(iconName)),
    h("h3", {}, title),
    description ? h("p", { class: "muted" }, description) : null,
    action ? action : null,
    resetLabel && onReset
      ? button({ label: resetLabel, icon: "refresh", onClick: onReset })
      : null,
  );
}

export function breadcrumbs({ items = [] }) {
  const nav = h("nav", { class: "breadcrumbs", "aria-label": "Breadcrumb" });
  items.forEach((item, idx) => {
    const isLast = idx === items.length - 1;
    if (idx > 0) {
      nav.append(
        h("span", { class: "breadcrumb-sep", "aria-hidden": "true" }, "/"),
      );
    }
    const content = item.href && !isLast
      ? h("a", { href: item.href }, item.label)
      : h("span", {}, item.label);
    nav.append(
      h(
        "span",
        {
          class: "breadcrumb-item",
          ...(isLast ? { "aria-current": "page" } : {}),
        },
        content,
      ),
    );
  });
  return nav;
}

export function tabs({ tabs: tabList = [], activeId, onChange }) {
  const currentId = activeId ?? tabList[0]?.id;
  const container = h("div", { class: "tabs-nav", role: "tablist" });
  const select = (id) => {
    for (const tab of container.querySelectorAll('[role="tab"]')) {
      const selected = tab.id === `tab-${id}`;
      tab.setAttribute("aria-selected", String(selected));
      tab.tabIndex = selected ? 0 : -1;
      const count = tab.querySelector(".badge");
      if (count) {
        count.className = `badge badge-${selected ? "info" : "neutral"}`;
      }
    }
    onChange?.(id);
  };
  for (const t of tabList) {
    const isSelected = t.id === currentId;
    const btn = h(
      "button",
      {
        class: "tab-btn",
        role: "tab",
        type: "button",
        id: `tab-${t.id}`,
        "aria-selected": isSelected ? "true" : "false",
        "aria-controls": `panel-${t.id}`,
        tabindex: isSelected ? "0" : "-1",
        onClick: () => select(t.id),
        onKeydown: (event) => {
          const index = tabList.indexOf(t);
          const target = event.key === "Home"
            ? 0
            : event.key === "End"
            ? tabList.length - 1
            : event.key === "ArrowRight"
            ? (index + 1) % tabList.length
            : event.key === "ArrowLeft"
            ? (index - 1 + tabList.length) % tabList.length
            : null;
          if (target === null) return;
          event.preventDefault();
          select(tabList[target].id);
          container.querySelectorAll('[role="tab"]')[target].focus();
        },
      },
      t.icon ? icon(t.icon) : null,
      t.label,
      t.badge ? badge(t.badge, isSelected ? "info" : "neutral") : null,
    );
    container.append(btn);
  }
  return container;
}

export function stepper({ steps = [], currentStep = 0, onStepClick }) {
  const nav = h("nav", { class: "stepper", "aria-label": "Progress" });
  steps.forEach((step, idx) => {
    if (idx > 0) {
      const isLineDone = idx <= currentStep;
      nav.append(
        h("div", {
          class: `step-line${isLineDone ? " is-done" : ""}`,
          "aria-hidden": "true",
        }),
      );
    }
    const isDone = idx < currentStep;
    const isActive = idx === currentStep;
    const circleContent = isDone ? icon("check") : String(idx + 1);
    const item = h(
      "button",
      {
        class: `step-item${isActive ? " is-active" : ""}${
          isDone ? " is-done" : ""
        }`,
        type: "button",
        "aria-current": isActive ? "step" : null,
        onClick: () => onStepClick?.(idx),
      },
      h("span", { class: "step-circle" }, circleContent),
      h(
        "div",
        { class: "step-text" },
        h("span", { class: "step-label" }, step.label),
        step.description
          ? h("span", { class: "step-desc muted" }, step.description)
          : null,
      ),
    );
    nav.append(item);
  });
  return nav;
}

export function sidebarNav({ items = [], activePath, onNavigate }) {
  const nav = h("nav", {
    class: "sidebar-nav",
    "aria-label": "Sidebar Navigation",
  });
  for (const item of items) {
    if (item.header) {
      nav.append(h("div", { class: "sidebar-nav-header" }, item.header));
      continue;
    }
    const isActive = item.path === activePath;
    const a = h(
      "button",
      {
        class: `sidebar-nav-item${isActive ? " is-active" : ""}`,
        type: "button",
        "aria-current": isActive ? "page" : null,
        disabled: item.disabled,
        onClick: () => onNavigate?.(item.path),
      },
      item.icon ? icon(item.icon) : null,
      h("span", { class: "sidebar-nav-label" }, item.label),
      item.badge ? badge(item.badge, isActive ? "info" : "neutral") : null,
    );
    nav.append(a);
  }
  return nav;
}

export function card(
  {
    header,
    title,
    subtitle,
    content,
    footer,
    actions = [],
    className = "",
  },
) {
  const el = h("div", { class: `card ${className}`.trim() });
  if (header || title || actions.length) {
    el.append(
      h(
        "div",
        { class: "card-head" },
        h(
          "div",
          { class: "card-head-lead" },
          title ? h("h3", { class: "card-title" }, title) : null,
          subtitle ? h("p", { class: "card-subtitle muted" }, subtitle) : null,
        ),
        actions.length
          ? h("div", { class: "card-actions actions" }, ...actions)
          : null,
      ),
    );
  }
  if (content) {
    el.append(h("div", { class: "card-body" }, content));
  }
  if (footer) {
    el.append(h("div", { class: "card-foot" }, footer));
  }
  return el;
}

export function statCard(
  {
    label,
    value,
    change,
    changeTone = "success",
    icon: iconName,
    subtitle,
  },
) {
  return h(
    "div",
    { class: "card stat-card" },
    h(
      "div",
      { class: "stat-header" },
      h("span", { class: "stat-label" }, label),
      iconName ? h("span", { class: "badge-icon" }, icon(iconName)) : null,
    ),
    h("div", { class: "stat-value" }, value),
    change || subtitle
      ? h(
        "div",
        { class: "stat-footer" },
        change
          ? h(
            "span",
            { class: `stat-trend trend-${changeTone}` },
            changeTone === "success"
              ? "↑ "
              : changeTone === "danger"
              ? "↓ "
              : "",
            change,
          )
          : null,
        subtitle ? h("span", { class: "muted" }, subtitle) : null,
      )
      : null,
  );
}

export function avatar({ name = "", src, size = "md", status }) {
  const initials = name
    .split(" ")
    .map((w) => w[0])
    .filter(Boolean)
    .slice(0, 2)
    .join("")
    .toUpperCase() || "U";

  const el = h("span", {
    class: `avatar avatar-${size}`,
    "aria-label": name || "Avatar",
  });

  if (src) {
    const img = h("img", {
      class: "avatar-img",
      src,
      alt: name || "Avatar",
    });
    img.addEventListener("error", () => {
      img.remove();
      el.textContent = initials;
    });
    el.append(img);
  } else {
    el.textContent = initials;
  }

  if (status) {
    el.append(
      h("span", { class: `avatar-status ${status}`, "aria-hidden": "true" }),
    );
  }
  return el;
}

export function statusIndicator(
  { status = "active", label, tone = "success" },
) {
  return h(
    "span",
    {
      class: `status-indicator status-${tone} is-${status}`,
      role: "status",
      "data-status": status,
    },
    h("span", { class: "status-dot", "aria-hidden": "true" }),
    label ? h("span", { class: "status-label" }, label) : null,
  );
}

export function accordion({ items = [] }) {
  const el = h("div", { class: "accordion" });
  for (const item of items) {
    let isOpen = item.defaultOpen ?? false;
    const content = h(
      "div",
      {
        class: "accordion-content",
        id: `acc-content-${item.id ?? Math.random().toString(36).slice(2, 6)}`,
        hidden: !isOpen,
      },
      item.content,
    );
    const chevronIcon = icon(isOpen ? "chevronUp" : "chevronDown");
    const headerBtn = h(
      "button",
      {
        class: "accordion-header",
        type: "button",
        "aria-expanded": isOpen ? "true" : "false",
        "aria-controls": content.id,
        onClick: () => {
          isOpen = !isOpen;
          content.hidden = !isOpen;
          headerBtn.setAttribute("aria-expanded", isOpen ? "true" : "false");
          chevronIcon.replaceChildren(
            ...icon(isOpen ? "chevronUp" : "chevronDown").childNodes,
          );
        },
      },
      h("span", { class: "accordion-title" }, item.title),
      chevronIcon,
    );
    el.append(h("div", { class: "accordion-item" }, headerBtn, content));
  }
  return el;
}

export function divider({ label, orientation = "horizontal" }) {
  if (orientation === "vertical") {
    return h("div", {
      class: "divider-vertical",
      role: "separator",
      "aria-orientation": "vertical",
    });
  }
  return h(
    "div",
    { class: "divider", role: "separator" },
    label ? h("span", { class: "divider-label" }, label) : null,
  );
}

export function svgEl(tag, props = {}, ...children) {
  const el = document.createElementNS(SVG_NS, tag);
  for (const [key, val] of Object.entries(props)) {
    if (key === "href" || key === "xlink:href") {
      el.setAttributeNS("http://www.w3.org/1999/xlink", "xlink:href", val);
      el.setAttribute("href", val);
    } else {
      el.setAttribute(key, val);
    }
  }
  for (const child of children.flat()) {
    if (child instanceof Node) el.append(child);
  }
  return el;
}

export function createCourtWatermarkSvg(
  customClass = "cpc-hero-court-watermark",
) {
  return svgEl(
    "svg",
    {
      class: customClass,
      viewBox: "0 0 900 420",
      fill: "none",
      "aria-hidden": "true",
    },
    svgEl("rect", {
      x: "30",
      y: "30",
      width: "840",
      height: "360",
      rx: "8",
      stroke: "#163827",
      "stroke-width": "1.5",
      "stroke-opacity": "0.45",
    }),
    svgEl("line", {
      x1: "450",
      y1: "15",
      x2: "450",
      y2: "405",
      stroke: "#DFB756",
      "stroke-width": "1.5",
      "stroke-opacity": "0.35",
      "stroke-dasharray": "6 4",
    }),
    svgEl("line", {
      x1: "316",
      y1: "30",
      x2: "316",
      y2: "390",
      stroke: "#234735",
      "stroke-width": "1.2",
      "stroke-opacity": "0.45",
    }),
    svgEl("line", {
      x1: "584",
      y1: "30",
      x2: "584",
      y2: "390",
      stroke: "#234735",
      "stroke-width": "1.2",
      "stroke-opacity": "0.45",
    }),
    svgEl("line", {
      x1: "30",
      y1: "210",
      x2: "316",
      y2: "210",
      stroke: "#163827",
      "stroke-width": "1.2",
      "stroke-opacity": "0.45",
    }),
    svgEl("line", {
      x1: "584",
      y1: "210",
      x2: "870",
      y2: "210",
      stroke: "#163827",
      "stroke-width": "1.2",
      "stroke-opacity": "0.45",
    }),
    svgEl("circle", {
      cx: "30",
      cy: "30",
      r: "3",
      fill: "#DFB756",
      "fill-opacity": "0.3",
    }),
    svgEl("circle", {
      cx: "870",
      cy: "30",
      r: "3",
      fill: "#DFB756",
      "fill-opacity": "0.3",
    }),
    svgEl("circle", {
      cx: "30",
      cy: "390",
      r: "3",
      fill: "#DFB756",
      "fill-opacity": "0.3",
    }),
    svgEl("circle", {
      cx: "870",
      cy: "390",
      r: "3",
      fill: "#DFB756",
      "fill-opacity": "0.3",
    }),
  );
}

/** Shared animated page background, disposed when its route is removed. */
export function attachPagePattern(page) {
  const canvas = h("canvas", {
    class: "dashboard-pattern",
    "aria-hidden": "true",
  });
  page.prepend(canvas);
  requestAnimationFrame(() => {
    if (!page.isConnected) return;
    const stopPattern = setupConvexPatternCanvas(canvas, page);
    const observer = new MutationObserver(() => {
      if (!page.isConnected) {
        stopPattern();
        observer.disconnect();
      }
    });
    observer.observe(page.parentNode, { childList: true });
  });
}

export function setupConvexPatternCanvas(canvas, containerEl, watermarkEl) {
  const ctx = canvas.getContext("2d");
  if (!ctx) return () => {};
  const reducedMotion = globalThis.matchMedia?.(
    "(prefers-reduced-motion: reduce)",
  );

  const STEP = 60;
  const RADIUS = 180;
  const RADIUS_SQ = RADIUS * RADIUS;
  const EASE = 0.08;

  let width = 0;
  let height = 0;
  let targetX = -9999;
  let targetY = -9999;
  let currentX = -9999;
  let currentY = -9999;
  let targetStrength = 0;
  let currentStrength = 0;
  let animId = null;
  let hasConnected = false;

  function resize() {
    const rect = canvas.getBoundingClientRect();
    width = rect.width;
    height = rect.height;
    if (width === 0 || height === 0) return;
    const dpr = globalThis.devicePixelRatio || 1;
    canvas.width = Math.round(width * dpr);
    canvas.height = Math.round(height * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    draw();
  }

  function warp(x, y) {
    const dx = x - currentX;
    const dy = y - currentY;
    const distSq = dx * dx + dy * dy;
    if (distSq >= RADIUS_SQ || currentStrength <= 0.0005) {
      return [x, y];
    }
    const dist = Math.sqrt(distSq);
    if (dist < 0.0001) return [x, y];
    const r = dist / RADIUS;
    const factor = 0.44 * (1 - r * r) * (1 - r * r) * currentStrength;
    return [x + dx * factor, y + dy * factor];
  }

  function draw() {
    if (width === 0 || height === 0) return;
    ctx.clearRect(0, 0, width, height);

    const hasConvex = currentStrength > 0.0005;
    const xMin = hasConvex ? currentX - RADIUS : -9999;
    const xMax = hasConvex ? currentX + RADIUS : -9999;
    const yMin = hasConvex ? currentY - RADIUS : -9999;
    const yMax = hasConvex ? currentY + RADIUS : -9999;

    // 1. Diagonal Court Net Pattern (dashed)
    ctx.beginPath();
    ctx.setLineDash([3, 5]);
    ctx.strokeStyle = "rgba(17, 41, 28, 0.35)";
    ctx.lineWidth = 0.75;
    for (let gx = 0; gx < width + STEP; gx += STEP) {
      for (let gy = 0; gy < height + STEP; gy += STEP) {
        const x1 = gx;
        const y1 = gy + STEP;
        const x2 = gx + STEP;
        const y2 = gy;
        const inLens = hasConvex &&
          x2 >= xMin && x1 <= xMax &&
          y1 >= yMin && y2 <= yMax;
        if (!inLens) {
          ctx.moveTo(x1, y1);
          ctx.lineTo(x2, y2);
        } else {
          const [wx1, wy1] = warp(x1, y1);
          ctx.moveTo(wx1, wy1);
          for (let t = 0.15; t <= 1; t += 0.15) {
            const [wx, wy] = warp(
              x1 + (x2 - x1) * t,
              y1 + (y2 - y1) * t,
            );
            ctx.lineTo(wx, wy);
          }
        }
      }
    }
    ctx.stroke();
    ctx.setLineDash([]);

    // 2. Regulation Court Grid Lines (vertical & horizontal)
    ctx.beginPath();
    ctx.strokeStyle = "rgba(22, 56, 39, 0.45)";
    ctx.lineWidth = 1;

    for (let gx = 0; gx <= width + STEP; gx += STEP) {
      if (!hasConvex || gx < xMin || gx > xMax) {
        ctx.moveTo(gx, 0);
        ctx.lineTo(gx, height);
      } else {
        ctx.moveTo(gx, 0);
        const yEnter = Math.max(0, yMin);
        const yExit = Math.min(height, yMax);
        if (yEnter > 0) ctx.lineTo(gx, yEnter);
        for (let gy = yEnter; gy <= yExit; gy += 6) {
          const [wx, wy] = warp(gx, gy);
          ctx.lineTo(wx, wy);
        }
        if (yExit < height) ctx.lineTo(gx, height);
      }
    }

    for (let gy = 0; gy <= height + STEP; gy += STEP) {
      if (!hasConvex || gy < yMin || gy > yMax) {
        ctx.moveTo(0, gy);
        ctx.lineTo(width, gy);
      } else {
        ctx.moveTo(0, gy);
        const xEnter = Math.max(0, xMin);
        const xExit = Math.min(width, xMax);
        if (xEnter > 0) ctx.lineTo(xEnter, gy);
        for (let gx = xEnter; gx <= xExit; gx += 6) {
          const [wx, wy] = warp(gx, gy);
          ctx.lineTo(wx, wy);
        }
        if (xExit < width) ctx.lineTo(width, gy);
      }
    }
    ctx.stroke();

    // 3. Regulation Center Crosses
    ctx.beginPath();
    ctx.strokeStyle = "rgba(35, 71, 53, 0.65)";
    ctx.lineWidth = 1.2;
    ctx.lineCap = "round";
    for (let gx = 0; gx < width + STEP; gx += STEP) {
      for (let gy = 0; gy < height + STEP; gy += STEP) {
        const cx = gx + STEP / 2;
        const cy = gy + STEP / 2;
        const inLens = hasConvex &&
          cx >= xMin && cx <= xMax &&
          cy >= yMin && cy <= yMax;
        const [wcx, wcy] = inLens ? warp(cx, cy) : [cx, cy];
        const crossSize = inLens ? 6.5 : 5.5;
        ctx.moveTo(wcx, wcy - crossSize);
        ctx.lineTo(wcx, wcy + crossSize);
        ctx.moveTo(wcx - crossSize, wcy);
        ctx.lineTo(wcx + crossSize, wcy);
      }
    }
    ctx.stroke();
    ctx.lineCap = "butt";

    // 4. Pickleball Perforation Accents (Gold corner dots, Emerald center dots)
    ctx.fillStyle = "rgba(223, 183, 86, 0.16)";
    for (let gx = 0; gx <= width + STEP; gx += STEP) {
      for (let gy = 0; gy <= height + STEP; gy += STEP) {
        const inLens = hasConvex &&
          gx >= xMin && gx <= xMax &&
          gy >= yMin && gy <= yMax;
        const [wgx, wgy] = inLens ? warp(gx, gy) : [gx, gy];
        const dotR = inLens ? 2.2 : 1.8;
        ctx.beginPath();
        ctx.arc(wgx, wgy, dotR, 0, Math.PI * 2);
        ctx.fill();
      }
    }

    ctx.fillStyle = "rgba(74, 222, 128, 0.18)";
    for (let gx = 0; gx < width + STEP; gx += STEP) {
      for (let gy = 0; gy < height + STEP; gy += STEP) {
        const cx = gx + STEP / 2;
        const cy = gy + STEP / 2;
        const inLens = hasConvex &&
          cx >= xMin && cx <= xMax &&
          cy >= yMin && cy <= yMax;
        const [wcx, wcy] = inLens ? warp(cx, cy) : [cx, cy];
        const dotR = inLens ? 2.2 : 1.8;
        ctx.beginPath();
        ctx.arc(wcx, wcy, dotR, 0, Math.PI * 2);
        ctx.fill();
      }
    }
  }

  function cleanup() {
    if (animId) {
      cancelAnimationFrame(animId);
      animId = null;
    }
    globalThis.removeEventListener("mousemove", handleMouseMove);
    globalThis.removeEventListener("mouseleave", handleMouseLeave);
    globalThis.removeEventListener("touchstart", handleTouch);
    globalThis.removeEventListener("touchmove", handleTouch);
    globalThis.removeEventListener("touchend", handleTouchEnd);
    globalThis.removeEventListener("touchcancel", handleTouchEnd);
    globalThis.removeEventListener("resize", resize);
    sizeWatcher?.disconnect();
  }

  function step() {
    if (reducedMotion?.matches) {
      currentStrength = 0;
      draw();
      animId = null;
      return;
    }
    if (containerEl && containerEl.isConnected) {
      hasConnected = true;
      if (width === 0 || height === 0) resize();
    } else if (hasConnected) {
      cleanup();
      return;
    }

    currentX += (targetX - currentX) * EASE;
    currentY += (targetY - currentY) * EASE;
    currentStrength += (targetStrength - currentStrength) * EASE;

    draw();

    if (watermarkEl) {
      const halfW = width / 2 || 1;
      const halfH = height / 2 || 1;
      const normX = ((currentX - halfW) / halfW) * -16 * currentStrength;
      const normY = ((currentY - halfH) / halfH) * -12 * currentStrength;
      watermarkEl.style.transform = `translate(calc(-50% + ${
        normX.toFixed(2)
      }px), calc(-50% + ${normY.toFixed(2)}px)) rotate(${
        (-4 + normX * 0.04).toFixed(2)
      }deg)`;
    }

    if (
      targetStrength === 0 &&
      currentStrength <= 0.0005 &&
      Math.abs(targetX - currentX) < 0.1 &&
      Math.abs(targetY - currentY) < 0.1
    ) {
      currentStrength = 0;
      draw();
      animId = null;
      return;
    }

    animId = requestAnimationFrame(step);
  }

  function handleMouseMove(e) {
    if (reducedMotion?.matches) return;
    if (width === 0 || height === 0) resize();
    const rect = canvas.getBoundingClientRect();
    targetX = e.clientX - rect.left;
    targetY = e.clientY - rect.top;
    if (currentX === -9999) {
      currentX = targetX;
      currentY = targetY;
    }
    targetStrength = 1;
    if (!animId) animId = requestAnimationFrame(step);
  }

  function handleTouch(e) {
    if (reducedMotion?.matches) return;
    if (!e.touches || !e.touches[0]) return;
    if (width === 0 || height === 0) resize();
    const t = e.touches[0];
    const rect = canvas.getBoundingClientRect();
    targetX = t.clientX - rect.left;
    targetY = t.clientY - rect.top;
    if (currentX === -9999) {
      currentX = targetX;
      currentY = targetY;
    }
    targetStrength = 1;
    if (!animId) animId = requestAnimationFrame(step);
  }

  function handleTouchEnd() {
    targetStrength = 0;
    if (!animId) animId = requestAnimationFrame(step);
  }

  function handleMouseLeave() {
    targetStrength = 0;
    if (!animId) animId = requestAnimationFrame(step);
  }

  globalThis.addEventListener("mousemove", handleMouseMove, { passive: true });
  globalThis.addEventListener("mouseleave", handleMouseLeave, {
    passive: true,
  });
  globalThis.addEventListener("touchstart", handleTouch, { passive: true });
  globalThis.addEventListener("touchmove", handleTouch, { passive: true });
  globalThis.addEventListener("touchend", handleTouchEnd, { passive: true });
  globalThis.addEventListener("touchcancel", handleTouchEnd, { passive: true });
  globalThis.addEventListener("resize", resize, { passive: true });
  // the page can grow after the first draw (fonts, CAPTCHA); redraw so the pattern covers all of it
  const sizeWatcher = typeof ResizeObserver === "function"
    ? new ResizeObserver(() => resize())
    : null;
  sizeWatcher?.observe(canvas);

  requestAnimationFrame(() => {
    resize();
  });

  return cleanup;
}
