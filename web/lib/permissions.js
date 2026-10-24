// can('code') and route access (PLAN 1B.3). This only decides what the UI shows.
// The database checks every permission again; hiding a button is convenience, not security.
let grants = []; // rows from my_permissions(): { org_id, unit_id, code }
let signedIn = false;
let gate = null; // null | "pending" | "password_change" | "suspended"
const listeners = new Set();

export function setAuth({ signedIn: s, grants: g = [], gate: gt = null }) {
  signedIn = !!s;
  grants = Array.isArray(g) ? g : [];
  gate = gt;
  for (const fn of listeners) fn();
}

export function clearAuth() {
  setAuth({ signedIn: false, grants: [], gate: null });
}

export function onAuthChange(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

export const isSignedIn = () => signedIn;
export const currentGate = () => gate;

/** True when the caller holds `code` (in the given unit, when one is passed). */
export function can(code, { unitId = null } = {}) {
  if (!signedIn || gate) return false;
  return grants.some((g) =>
    g.code === code &&
    (unitId === null || g.unit_id === null || g.unit_id === unitId)
  );
}

/** The club administrator account: it works in the admin console only (roles.manage is held by the admin role alone). */
export const isAdminAccount = () => can("roles.manage");

export const canAny = (codes, options) => codes.some((c) => can(c, options));

/**
 * Route access rules:
 *   "public"                      anyone
 *   "signedIn"                    any signed-in user not held at a gate
 *   "gated"                       signed in, including users held at a gate (password change, pending page)
 *   { permission: "code" }        needs that permission
 *   { any: ["a.b", "c.d"] }       needs at least one
 * Returns { allow: true } | { redirect: "#/signin" } | { forbidden: true } | { redirect: "#/<gate page>" }.
 */
export function checkAccess(access = "public", gatePages = {}) {
  if (access === "public") return { allow: true };
  if (!signedIn) return { redirect: "#/signin" };
  if (access === "gated") return { allow: true };
  if (gate) return { redirect: gatePages[gate] ?? "#/" };
  if (access === "signedIn") return { allow: true };
  if (access?.permission) {
    return can(access.permission) ? { allow: true } : { forbidden: true };
  }
  if (access?.any) {
    return canAny(access.any) ? { allow: true } : { forbidden: true };
  }
  return { forbidden: true };
}
