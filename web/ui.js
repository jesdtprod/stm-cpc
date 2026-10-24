// Shared UI components. Every dynamic value goes through textContent / text nodes,
// never innerHTML, so output is escaped by construction.

const SVG_NS = "http://www.w3.org/2000/svg";

const ICONS = {
  home: "M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z",
  grid: "M3 3h7v7H3zM14 3h7v7h-7zM14 14h7v7h-7zM3 14h7v7H3z",
  search: "M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14zM21 21l-4.3-4.3",
  x: "M6 6l12 12M18 6 6 18",
  plus: "M12 5v14M5 12h14",
  edit: "M12 20h9M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z",
  trash: "M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14M10 11v5M14 11v5",
  check: "M5 12.5l4.5 4.5L19 7.5",
  alert: "M12 3 2 20h20zM12 10v4M12 17.5v.01",
  inbox: "M3 13l3-8h12l3 8v6H3zM3 13h5l1 3h6l1-3h5",
  refresh: "M20 11a8 8 0 0 0-14.5-4M4 4v4h4M4 13a8 8 0 0 0 14.5 4M20 20v-4h-4",
  chevl: "M15 6l-6 6 6 6",
  chevr: "M9 6l6 6-6 6",
  chevronLeft: "M15 6l-6 6 6 6",
  chevronRight: "M9 6l6 6-6 6",
  chevronDown: "M6 9l6 6 6-6",
  chevronUp: "M18 15l-6-6-6 6",
  info: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 11v5M12 8v.01",
  eye:
    "M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8zM12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6z",
  eyeOff:
    "M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19m-6.72-1.07a3 3 0 1 1-4.24-4.24M1 1l22 22",
  calendar:
    "M19 4H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V6a2 2 0 0 0-2-2zM16 2v4M8 2v4M3 10h18",
  clock: "M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zM12 6v6l4 2",
  upload: "M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4M17 8l-5-5-5 5M12 3v12",
  download: "M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4M7 10l5 5 5-5M12 15V3",
  copy:
    "M8 4v12a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2V7.242a2 2 0 0 0-.602-1.43L16.083 2.57A2 2 0 0 0 14.653 2H10a2 2 0 0 0-2 2zM4 16H3a1 1 0 0 1-1-1V5a2 2 0 0 1 2-2h7a1 1 0 0 1 1 1v1",
  user:
    "M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2M12 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8z",
  mail:
    "M4 4h16c1.1 0 2 .9 2 2v12c0 1.1-.9 2-2 2H4c-1.1 0-2-.9-2-2V6c0-1.1.9-2 2-2zM22 6l-10 7L2 6",
  phone:
    "M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z",
  link:
    "M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71",
  checkCircle: "M22 11.08V12a10 10 0 1 1-5.93-9.14M22 4L12 14.01l-3-3",
  alertCircle: "M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zM12 8v4M12 16h.01",
  alertTriangle:
    "M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0zM12 9v4M12 17h.01",
  sun:
    "M12 1v2M12 21v2M4.22 4.22l1.42 1.42M18.36 18.36l1.42 1.42M1 12h2M21 12h2M4.22 19.78l1.42-1.42M18.36 5.64l1.42-1.42M12 17a5 5 0 1 0 0-10 5 5 0 0 0 0 10z",
  moon: "M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z",
  filter: "M22 3H2l8 9.46V19l4 2v-8.54L22 3z",
  layers: "M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5",
  file: "M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8zM14 2v6h6",
  qrScan:
    "M3 7V5a2 2 0 0 1 2-2h2m10 0h2a2 2 0 0 1 2 2v2m0 10v2a2 2 0 0 1-2 2h-2m-10 0H5a2 2 0 0 1-2-2v-2M7 12h10M12 7v10",
  trophy:
    "M6 9H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h2m12 6h2a2 2 0 0 0 2-2V5a2 2 0 0 0-2-2h-2M6 3h12v7a6 6 0 0 1-12 0V3zm3 14h6m-3-3v7m-4 0h8",
  lock:
    "M19 11H5a2 2 0 0 0-2 2v7a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7a2 2 0 0 0-2-2zm-12 0V7a5 5 0 0 1 10 0v4",
  arrowLeft: "M19 12H5m7 7-7-7 7-7",
};

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
      child instanceof Node ? child : document.createTextNode(String(child)),
    );
  }
  return el;
}

export function icon(name) {
  const svg = document.createElementNS(SVG_NS, "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("class", "icon");
  svg.setAttribute("aria-hidden", "true");
  const path = document.createElementNS(SVG_NS, "path");
  path.setAttribute("d", ICONS[name] ?? ICONS.info);
  svg.append(path);
  return svg;
}

export function toProperCase(text) {
  if (typeof text !== "string" || !text) return text;
  if (text.startsWith("--")) return text;
  return text
    .replace(/_/g, " ")
    .replace(/\b[a-z]/g, (c) => c.toUpperCase());
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
  },
) {
  const variantClass = variant === "primary"
    ? "btn-primary"
    : variant === "danger" || variant === "destructive"
    ? "btn-danger"
    : variant === "outline"
    ? "btn-outline"
    : variant === "ghost"
    ? "btn-ghost"
    : variant === "link"
    ? "btn-link"
    : "btn-secondary";

  const sizeClass = size === "sm" ? "btn-sm" : size === "lg" ? "btn-lg" : "";
  const cls = ["btn", variantClass, sizeClass].filter(Boolean).join(" ");

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
    size = "default",
    disabled = false,
    title,
  },
) {
  if (!label) throw new Error("iconButton needs a label");
  const variantClass = variant === "primary"
    ? "btn-primary"
    : variant === "danger" || variant === "destructive"
    ? "btn-danger"
    : variant === "outline"
    ? "btn-outline"
    : variant === "ghost"
    ? "btn-ghost"
    : "";
  const sizeClass = size === "sm" ? "btn-sm" : size === "lg" ? "btn-lg" : "";
  const cls = ["btn btn-icon", variantClass, sizeClass].filter(Boolean).join(
    " ",
  );
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
      "aria-label": "Show password",
      title: "Show password",
      tabindex: "-1",
      onClick: (e) => {
        e.preventDefault();
        isPasswordToggled = !isPasswordToggled;
        inputEl.type = isPasswordToggled ? "text" : "password";
        toggleBtn.replaceChildren(icon(isPasswordToggled ? "eyeOff" : "eye"));
        const lbl = isPasswordToggled ? "Hide password" : "Show password";
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

export function selectField(
  {
    id,
    label,
    options = [],
    value = "",
    error,
    hint,
    required,
    disabled,
    onChange,
  },
) {
  const describedBy = [error ? `${id}-err` : null, hint ? `${id}-hint` : null]
    .filter(Boolean).join(" ");
  const selectEl = h(
    "select",
    {
      class: "input select-input",
      id,
      name: id,
      required,
      disabled,
      "aria-invalid": error ? "true" : null,
      "aria-describedby": describedBy || null,
      onChange,
    },
    ...options.map((opt) => {
      const optVal = typeof opt === "object" ? opt.value : opt;
      const optLbl = typeof opt === "object" ? opt.label : opt;
      const isSelected = String(optVal) === String(value);
      const isOptDisabled = typeof opt === "object" ? opt.disabled : false;
      return h(
        "option",
        { value: optVal, selected: isSelected, disabled: isOptDisabled },
        optLbl,
      );
    }),
  );

  return h(
    "div",
    { class: `field${error ? " field-error-state" : ""}` },
    label ? h("label", { for: id }, label, required ? " *" : "") : null,
    h("div", { class: "select-wrap" }, selectEl, icon("chevronDown")),
    hint ? h("span", { class: "field-hint", id: `${id}-hint` }, hint) : null,
    error ? h("span", { class: "field-error", id: `${id}-err` }, error) : null,
  );
}

export function searchableSelect(
  {
    id,
    label,
    options = [],
    value = "",
    placeholder = "Select option...",
    error,
    hint,
    required,
    disabled,
    onSelect,
  },
) {
  let selected =
    options.find((o) => (typeof o === "object" ? o.value : o) === value) ??
      null;
  let isOpen = false;
  let filtered = [...options];

  const triggerText = h(
    "span",
    { class: "searchable-select-text" },
    selected
      ? (typeof selected === "object" ? selected.label : selected)
      : placeholder,
  );
  const searchInput = h("input", {
    type: "search",
    class: "input input-sm",
    placeholder: "Search...",
    onInput: (e) => {
      const q = e.target.value.toLowerCase();
      filtered = options.filter((o) => {
        const text = (typeof o === "object" ? o.label : o).toLowerCase();
        return text.includes(q);
      });
      renderList();
    },
  });

  const listEl = h("div", {
    class: "searchable-select-options",
    role: "listbox",
  });
  const dropdown = h(
    "div",
    { class: "searchable-select-dropdown", hidden: true },
    searchInput,
    listEl,
  );

  const renderList = () => {
    listEl.replaceChildren();
    if (filtered.length === 0) {
      listEl.append(
        h(
          "div",
          { class: "searchable-select-empty muted" },
          "No options match",
        ),
      );
      return;
    }
    filtered.forEach((opt) => {
      const val = typeof opt === "object" ? opt.value : opt;
      const lbl = typeof opt === "object" ? opt.label : opt;
      const isSelected = selected &&
        (typeof selected === "object" ? selected.value : selected) === val;
      const itemBtn = h(
        "button",
        {
          class: `searchable-select-item${isSelected ? " is-selected" : ""}`,
          type: "button",
          role: "option",
          "aria-selected": isSelected ? "true" : "false",
          onClick: (e) => {
            e.stopPropagation();
            selected = opt;
            triggerText.textContent = lbl;
            toggle(false);
            onSelect?.(val, opt);
          },
        },
        h("span", {}, lbl),
        isSelected ? icon("check") : null,
      );
      listEl.append(itemBtn);
    });
  };

  const toggle = (force) => {
    if (disabled) return;
    isOpen = force ?? !isOpen;
    dropdown.hidden = !isOpen;
    triggerBtn.setAttribute("aria-expanded", isOpen ? "true" : "false");
    if (isOpen) {
      renderList();
      setTimeout(() => searchInput.focus(), 10);
    }
  };

  const triggerBtn = h(
    "button",
    {
      class: "input searchable-select-trigger",
      type: "button",
      id,
      disabled,
      "aria-haspopup": "listbox",
      "aria-expanded": "false",
      onClick: () => toggle(),
    },
    triggerText,
    icon("chevronDown"),
  );

  const wrap = h(
    "div",
    { class: "searchable-select-wrap" },
    triggerBtn,
    dropdown,
  );

  document.addEventListener("click", (e) => {
    if (!wrap.contains(e.target) && isOpen) toggle(false);
  });

  return h(
    "div",
    { class: `field${error ? " field-error-state" : ""}` },
    label ? h("label", { for: id }, label, required ? " *" : "") : null,
    wrap,
    hint ? h("span", { class: "field-hint", id: `${id}-hint` }, hint) : null,
    error ? h("span", { class: "field-error", id: `${id}-err` }, error) : null,
  );
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
    name: id,
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

export function dateField(
  {
    id,
    label,
    value = "",
    min,
    max,
    error,
    hint,
    required,
    disabled,
    onChange,
  },
) {
  return calendarDropdown({
    id,
    label,
    value,
    range: false,
    min,
    max,
    error,
    hint,
    required,
    disabled,
    onChange,
  });
}

export function timeField(
  {
    id,
    label,
    value = "",
    min,
    max,
    error,
    hint,
    required,
    disabled,
    onChange,
  },
) {
  return field({
    id,
    label,
    type: "time",
    value,
    min,
    max,
    error,
    hint,
    required,
    disabled,
    iconTrailing: "clock",
    onChange,
  });
}

export function dateTimeField(
  {
    id,
    label,
    value = "",
    min,
    max,
    error,
    hint,
    required,
    disabled,
    onChange,
  },
) {
  return field({
    id,
    label,
    type: "datetime-local",
    value,
    min,
    max,
    error,
    hint,
    required,
    disabled,
    iconTrailing: "calendar",
    onChange,
  });
}

export function calendarDropdown(
  {
    id = "calendar-drop",
    label,
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
  },
) {
  let selectedStart = range ? startValue : value;
  let selectedEnd = range ? endValue : "";
  let isOpen = false;

  const initialDate = selectedStart ? new Date(selectedStart) : new Date();
  let viewYear = isNaN(initialDate.getTime())
    ? new Date().getFullYear()
    : initialDate.getFullYear();
  let viewMonth = isNaN(initialDate.getTime())
    ? new Date().getMonth()
    : initialDate.getMonth();

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

  const formatDisplay = () => {
    if (range) {
      if (selectedStart && selectedEnd) {
        return `${selectedStart} → ${selectedEnd}`;
      }
      if (selectedStart) return `${selectedStart} → Select end date`;
      return "Select date range";
    }
    return selectedStart || "Select date";
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
      icon("calendar"),
      displayText,
    ),
    icon("chevronDown"),
  );

  const popover = h("div", {
    id: `${id}-calendar`,
    class: "calendar-popover",
    role: "dialog",
    "aria-label": label || "Choose date",
    hidden: true,
  });

  const hiddenInput = h("input", {
    type: "hidden",
    id,
    name: id,
    value: selectedStart || "",
  });

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
        "span",
        { class: "calendar-month-label" },
        `${MONTH_NAMES[viewMonth]} ${viewYear}`,
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
      const isStart = dStr === selectedStart;
      const isEnd = dStr === selectedEnd;
      const inRange = range && selectedStart && selectedEnd &&
        dStr > selectedStart && dStr < selectedEnd;
      const isDateDisabled = Boolean(
        disabled ||
          (min && dStr < min) ||
          (max && dStr > max),
      );

      const classes = [
        "calendar-day",
        isToday ? "is-today" : "",
        isStart ? "is-selected is-range-start" : "",
        isEnd ? "is-selected is-range-end" : "",
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
            if (range) {
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
            if (range) {
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
            const now = new Date();
            viewYear = now.getFullYear();
            viewMonth = now.getMonth();
            const first = new Date(viewYear, viewMonth, 1).toISOString().slice(
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
          },
        },
        "This Month",
      ),
      h(
        "button",
        {
          type: "button",
          class: "preset-chip",
          onClick: (e) => {
            e.stopPropagation();
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
          },
        },
        "Clear",
      ),
    );

    popover.append(header, weekdaysRow, daysGrid, presetsBar);
  };

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
      renderMonth();
      popover.hidden = false;
      requestAnimationFrame(() => popover.classList.add("is-open"));
      document.addEventListener("pointerdown", closeOutside);
      document.addEventListener("keydown", closeOnEscape);
    } else {
      document.removeEventListener("pointerdown", closeOutside);
      document.removeEventListener("keydown", closeOnEscape);
      popover.classList.remove("is-open");
      popover.hidden = true;
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

  wrapper.inputEl = hiddenInput;
  Object.defineProperty(wrapper, "value", {
    get: () => selectedStart,
    set: (v) => {
      selectedStart = v;
      hiddenInput.value = v;
      displayText.textContent = formatDisplay();
      renderMonth();
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
    "aria-label": "Start date",
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
    "aria-label": "End date",
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
            label: "Ready to upload",
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

export function kpiCard(label, value) {
  return h(
    "div",
    { class: "card kpi" },
    h("div", { class: "label" }, label),
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
      h("input", {
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
 * column: { key, label, align?: "left"|"right"|"center", kind?: "text"|"money", render?(row) }
 * schema.actions: array of { label, icon, onClick(row) } rendered icon-only.
 * state: "loading" | "error" | "ready"
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
  },
) {
  const cols = schema.columns;
  const actions = schema.actions ?? [];
  const cls = `tbl cols-${cols.length}${
    actions.length ? ` act-${actions.length}` : ""
  }`;
  const table = h("div", {
    class: cls,
    role: "table",
    "aria-label": ariaLabel ?? "Data table",
    "aria-busy": state === "loading" ? "true" : "false",
  });

  const head = h("div", { class: "tbl-row tbl-head", role: "row" });
  for (const c of cols) {
    head.append(
      h(
        "div",
        { class: `tbl-cell ${c.align ?? ""}`, role: "columnheader" },
        c.label,
      ),
    );
  }
  if (actions.length) {
    head.append(
      h("div", { class: "tbl-cell center", role: "columnheader" }, "Action"),
    );
  }
  table.append(head);

  const body = h("div", { class: "tbl-body", role: "rowgroup" });
  if (state === "loading") {
    for (let i = 0; i < 5; i++) {
      const row = h("div", {
        class: "tbl-row",
        role: "row",
        "aria-hidden": "true",
      });
      for (const c of cols) {
        const bar = h("span", {
          class: `sk ${
            c.kind === "money" || c.align === "right"
              ? "r w-30"
              : i % 2
              ? "w-50"
              : "w-70"
          }`,
        });
        row.append(
          h("div", {
            class: `tbl-cell ${c.align ?? ""}`,
            "data-label": c.label,
          }, bar),
        );
      }
      if (actions.length) {
        row.append(h(
          "div",
          { class: "tbl-cell center" },
          actions.map(() => h("span", { class: "sk round" })),
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
      const row = h("div", { class: "tbl-row", role: "row" });
      for (const c of cols) {
        let content;
        if (c.render) content = c.render(r);
        else if (c.kind === "money") content = PHP.format(r[c.key]);
        else content = r[c.key];
        row.append(
          h("div", {
            class: `tbl-cell ${c.kind === "money" ? "right" : (c.align ?? "")}`,
            role: "cell",
            "data-label": c.label,
          }, content),
        );
      }
      if (actions.length) {
        row.append(
          h(
            "div",
            { class: "tbl-cell center", role: "cell", "data-label": "Action" },
            actions.map((a) =>
              iconButton({
                label: a.label,
                icon: a.icon,
                onClick: () => a.onClick(r),
              })
            ),
          ),
        );
      }
      body.append(row);
    }
  }
  table.append(body);
  return table;
}

/** Footer with the visible range and total; never shows "1–0". */
export function pagination({ page, pageSize, total, onPage }) {
  const pages = Math.max(1, Math.ceil(total / pageSize));
  const current = Math.min(Math.max(page, 1), pages);
  const from = total === 0 ? 0 : (current - 1) * pageSize + 1;
  const to = Math.min(current * pageSize, total);
  const nav = h("div", { class: "pages" });
  nav.append(
    h("button", {
      class: "btn btn-icon",
      type: "button",
      "aria-label": "Previous page",
      disabled: current === 1,
      onClick: () => onPage(current - 1),
    }, icon("chevl")),
  );
  const first = Math.max(1, Math.min(current - 2, pages - 4));
  for (let p = first; p <= Math.min(pages, first + 4); p++) {
    nav.append(
      h("button", {
        class: "btn btn-icon",
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
      "aria-label": "Next page",
      disabled: current === pages,
      onClick: () => onPage(current + 1),
    }, icon("chevr")),
  );
  return h(
    "div",
    { class: "pager" },
    h(
      "span",
      { class: "muted" },
      total === 0 ? "No records" : `Showing ${from}–${to} of ${total}`,
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
    onConfirm,
  },
) {
  const opener = document.activeElement;
  const titleId = `modal-title-${Math.random().toString(36).slice(2, 8)}`;
  const dialog = h("dialog", {
    class: `modal modal-${size}`,
    "aria-labelledby": titleId,
  });
  const confirm = h("button", {
    class: destructive ? "btn btn-danger" : "btn btn-primary",
    type: "submit",
  }, confirmLabel);
  const close = () => dialog.close();
  const form = h(
    "form",
    { class: "modal-form", method: "dialog" },
    h(
      "div",
      { class: "modal-head" },
      h("span", { class: "badge-icon" }, icon(iconName)),
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
        "aria-label": "Close modal",
        title: "Close",
        onClick: close,
      }, icon("x")),
    ),
    h("div", { class: "modal-body" }, body),
    h(
      "div",
      { class: "modal-foot" },
      h(
        "button",
        { class: "btn btn-outline", type: "button", onClick: close },
        cancelLabel,
      ),
      confirm,
    ),
  );
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (confirm.dataset.pending === "true") return;
    confirm.dataset.pending = "true";
    confirm.setAttribute("aria-busy", "true");
    try {
      const keepOpen = await onConfirm?.(new FormData(form));
      if (keepOpen !== false) dialog.close();
    } finally {
      delete confirm.dataset.pending;
      confirm.removeAttribute("aria-busy");
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
        "aria-label": "Close drawer",
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
      trigger.setAttribute("aria-expanded", "true");
    } else {
      menuEl.setAttribute("hidden", "");
      trigger.setAttribute("aria-expanded", "false");
    }
  });
  document.addEventListener("click", (e) => {
    if (!wrapper.contains(e.target) && !menuEl.hasAttribute("hidden")) {
      menuEl.setAttribute("hidden", "");
      trigger.setAttribute("aria-expanded", "false");
    }
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && !menuEl.hasAttribute("hidden")) {
      menuEl.setAttribute("hidden", "");
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
    timeout = 5000,
  } = {},
) {
  const toastContainer = document.getElementById("toasts");
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
      title ? h("div", { class: "toast-title" }, title) : null,
      h("div", { class: "toast-msg" }, message),
    ),
  );

  if (actionLabel) {
    el.append(
      button({
        label: actionLabel,
        variant: "primary",
        size: "sm",
        onClick: () => {
          onAction?.();
          el.remove();
        },
      }),
    );
  }

  const closeBtn = h(
    "button",
    {
      class: "toast-close-btn",
      type: "button",
      "aria-label": "Dismiss notification",
      title: "Dismiss",
      onClick: () => el.remove(),
    },
    icon("x"),
  );
  el.append(closeBtn);

  if (toastContainer) {
    toastContainer.append(el);
  } else {
    document.body.append(el);
  }

  if (timeout > 0 && !actionLabel) {
    setTimeout(() => {
      if (el.parentNode) el.remove();
    }, timeout);
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
        "aria-label": "Dismiss alert",
        title: "Dismiss",
        onClick: () => {
          el.remove();
          onDismiss?.();
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
          "aria-label": "Dismiss announcement",
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
    "aria-label": "Sidebar navigation",
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

export function setupConvexPatternCanvas(canvas, containerEl, watermarkEl) {
  const ctx = canvas.getContext("2d");
  if (!ctx) return () => {};

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
  }

  function step() {
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

  requestAnimationFrame(() => {
    resize();
  });

  return cleanup;
}
