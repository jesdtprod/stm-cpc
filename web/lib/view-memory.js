// Remembers which tab (or opened item) a page was showing, so a browser refresh puts the person back where they were
// instead of on the page's first view. Kept per browser tab in sessionStorage; it only holds short ids, never data.
const key = (page) => `cpc.view.${page}`;

function read(page) {
  try {
    const raw = globalThis.sessionStorage?.getItem(key(page));
    const value = raw ? JSON.parse(raw) : null;
    return value && typeof value === "object" ? value : {};
  } catch {
    return {};
  }
}

function write(page, values) {
  try {
    globalThis.sessionStorage?.setItem(key(page), JSON.stringify(values));
  } catch {
    // Private windows may refuse storage; the page still works without memory.
  }
}

/**
 * Makes the listed string fields of a page's state restore from, and save to, session storage.
 * Call once right after the state object is created.
 */
export function rememberView(state, page, fields = ["tab"]) {
  const saved = read(page);
  for (const field of fields) {
    let current = typeof saved[field] === "string" ? saved[field] : state[field];
    Object.defineProperty(state, field, {
      enumerable: true,
      configurable: true,
      get: () => current,
      set: (value) => {
        current = value;
        write(page, { ...read(page), [field]: value });
      },
    });
  }
  return state;
}

/** Saved id for a field that holds an object (for example the opened event); null when none. */
export function savedViewId(page, field) {
  const value = read(page)[field];
  return typeof value === "string" ? value : null;
}

export function saveViewId(page, field, id) {
  write(page, { ...read(page), [field]: id ?? null });
}
