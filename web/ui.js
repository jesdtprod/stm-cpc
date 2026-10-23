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
  info: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 11v5M12 8v.01",
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

export function badge(text, tone = "info") {
  return h("span", { class: `badge badge-${tone}` }, text);
}

export function button(
  {
    label,
    variant = "secondary",
    icon: iconName,
    onClick,
    type = "button",
    disabled,
  },
) {
  const cls = variant === "primary"
    ? "btn btn-primary"
    : variant === "danger"
    ? "btn btn-danger"
    : "btn";
  return h(
    "button",
    { class: cls, type, disabled, onClick },
    iconName ? icon(iconName) : null,
    label,
  );
}

/** Row actions are icon-only, so the accessible label and tooltip are required. */
export function iconButton({ label, icon: iconName, onClick }) {
  if (!label) throw new Error("iconButton needs a label");
  return h("button", {
    class: "btn btn-icon",
    type: "button",
    "aria-label": label,
    title: label,
    onClick,
  }, icon(iconName));
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
  { id, label, type = "text", value = "", error, hint, required, placeholder },
) {
  const describedBy = [error ? `${id}-err` : null, hint ? `${id}-hint` : null]
    .filter(Boolean).join(" ");
  return h(
    "div",
    { class: "field" },
    h("label", { for: id }, label, required ? " *" : ""),
    h("input", {
      class: "input",
      id,
      name: id,
      type,
      value,
      placeholder,
      required,
      "aria-invalid": error ? "true" : null,
      "aria-describedby": describedBy || null,
    }),
    hint ? h("span", { class: "field-hint", id: `${id}-hint` }, hint) : null,
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
    confirmLabel = "Save",
    cancelLabel = "Cancel",
    destructive = false,
    onConfirm,
  },
) {
  const opener = document.activeElement;
  const titleId = `modal-title-${Math.random().toString(36).slice(2, 8)}`;
  const dialog = h("dialog", { class: "modal", "aria-labelledby": titleId });
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
        "aria-label": "Close",
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
        { class: "btn", type: "button", onClick: close },
        cancelLabel,
      ),
      confirm,
    ),
  );
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (confirm.dataset.pending === "true") return;
    confirm.dataset.pending = "true";
    try {
      const keepOpen = await onConfirm?.(new FormData(form));
      if (keepOpen !== false) dialog.close();
    } finally {
      delete confirm.dataset.pending;
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

export function toast(message, { actionLabel, onAction, timeout = 6000 } = {}) {
  const el = h("div", { class: "toast" }, h("span", {}, message));
  if (actionLabel) {
    el.append(button({
      label: actionLabel,
      variant: "primary",
      onClick: () => {
        onAction?.();
        el.remove();
      },
    }));
  }
  document.getElementById("toasts").append(el);
  if (!actionLabel) setTimeout(() => el.remove(), timeout);
  return el;
}
