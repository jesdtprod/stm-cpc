// The one session module for the whole app (PLAN 1B.2).
// Everything it touches is injected, so idle timeout and cross-tab sign-out are unit-testable.
//
// Sign-in goes through the `member-login` Edge Function (step 3.1): login(credentials, captchaToken)
// must resolve to { access_token, refresh_token }. loadAccess() resolves to { grants, profile }. Gates other than "pending" (forced password
// change, suspended) are decided by resolveGate once the member data exists (stage 3).
const CHANNEL = "cpc-session";

export function createSession({
  auth,
  login,
  loadAccess,
  resolveGate = (grants) => (grants.length === 0 ? "pending" : null),
  channel = null,
  storage = null,
  cacheStorage = null,
  idleMs = 15 * 60_000,
  warnMs = 60_000,
  reauthMs = 5 * 60_000,
  now = () => Date.now(),
  setTimer = (fn, ms) => setTimeout(fn, ms),
  clearTimer = (t) => clearTimeout(t),
  onChange = () => {},
  onIdleWarning = () => {},
}) {
  let state = {
    status: "signed_out",
    gate: null,
    grants: [],
    profile: null,
    reason: null,
  };
  let lastAuthAt = -Infinity;
  let warnTimer = null;
  let idleTimer = null;
  let lastActivity = 0;
  let lastBroadcast = 0;

  const emit = (patch) => {
    state = { ...state, ...patch };
    onChange(state);
  };

  function stopIdle() {
    if (warnTimer) clearTimer(warnTimer);
    if (idleTimer) clearTimer(idleTimer);
    warnTimer = idleTimer = null;
  }

  function startIdle() {
    stopIdle();
    if (state.status !== "signed_in") return;
    warnTimer = setTimer(
      () => onIdleWarning(Math.round(warnMs / 1000)),
      Math.max(idleMs - warnMs, 0),
    );
    idleTimer = setTimer(() => signOut("idle"), idleMs);
  }

  async function clearLocalData() {
    if (cacheStorage) {
      // The app shell holds no user data and stays; everything else is removed.
      for (const name of await cacheStorage.keys()) {
        if (!name.startsWith("cpc-shell")) await cacheStorage.delete(name);
      }
    }
    if (storage) {
      const keys = [];
      for (let i = 0; i < storage.length; i++) keys.push(storage.key(i));
      for (const k of keys) if (k?.startsWith("cpc.")) storage.removeItem(k);
    }
  }

  async function localSignOut(reason) {
    stopIdle();
    await clearLocalData();
    lastAuthAt = -Infinity;
    emit({
      status: "signed_out",
      gate: null,
      grants: [],
      profile: null,
      reason,
    });
  }

  async function establish(session) {
    const { error } = await auth.setSession(session);
    if (error) throw error;
    const { grants, profile } = await loadAccess();
    lastAuthAt = now();
    lastActivity = now();
    emit({
      status: "signed_in",
      grants,
      profile,
      gate: resolveGate(grants),
      reason: null,
    });
    startIdle();
  }

  async function signIn(credentials, captchaToken) {
    const session = await login(credentials, captchaToken);
    await establish(session);
  }

  async function signOut(reason = "manual") {
    if (state.status === "signed_out") return;
    channel?.postMessage({ type: "signout", reason });
    try {
      await auth.signOut();
    } finally {
      await localSignOut(reason);
    }
  }

  /** Call on user input. Resets the idle timers; tells other tabs at most every 30 seconds. */
  function activity() {
    if (state.status !== "signed_in") return;
    const t = now();
    if (t - lastActivity < 5_000) return;
    lastActivity = t;
    startIdle();
    if (t - lastBroadcast >= 30_000) {
      lastBroadcast = t;
      channel?.postMessage({ type: "activity" });
    }
  }

  /**
   * Sensitive actions (password change, role changes, exports, payment verification) call this first.
   * promptReauth() asks the user for their password and resolves to credentials, or null if cancelled.
   */
  async function ensureFreshAuth(promptReauth, captchaToken) {
    if (state.status !== "signed_in") return false;
    if (now() - lastAuthAt <= reauthMs) return true;
    const credentials = await promptReauth();
    if (!credentials) return false;
    await establish(await login(credentials, captchaToken));
    return true;
  }

  async function start() {
    channel?.addEventListener("message", (e) => {
      if (e.data?.type === "signout" && state.status === "signed_in") {
        localSignOut(e.data.reason ?? "other_tab");
      } else if (e.data?.type === "activity" && state.status === "signed_in") {
        lastActivity = now();
        startIdle();
      }
    });
    auth.onAuthStateChange((event) => {
      if (event === "SIGNED_OUT" && state.status === "signed_in") {
        localSignOut("remote");
      }
    });
    const { data } = await auth.getSession();
    if (data?.session) {
      const { grants, profile } = await loadAccess();
      lastAuthAt = -Infinity; // a restored session is not "fresh": sensitive actions ask for the password again
      lastActivity = now();
      emit({
        status: "signed_in",
        grants,
        profile,
        gate: resolveGate(grants),
        reason: null,
      });
      startIdle();
    }
    return state;
  }

  return {
    start,
    signIn,
    signOut,
    activity,
    ensureFreshAuth,
    getState: () => state,
    CHANNEL,
  };
}

export { CHANNEL };
