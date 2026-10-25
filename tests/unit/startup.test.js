import { restoreSession } from "../../web/lib/startup.js";

Deno.test("startup: waits for the saved session before routing and clears its timer", async () => {
  let finish;
  let cleared = false;
  let ready = false;
  const pending = restoreSession(
    () => new Promise((resolve) => finish = resolve),
    {
      setTimer: () => 1,
      clearTimer: (id) => cleared = id === 1,
    },
  ).then((state) => {
    ready = true;
    return state;
  });
  await Promise.resolve();
  if (ready) throw new Error("Routed before restoration finished");
  finish({ status: "signed_in" });
  const state = await pending;
  if (state.status !== "signed_in" || !cleared) {
    throw new Error("Restoration failed");
  }
});

Deno.test("startup: restoration errors reach recovery instead of sign-in routing", async () => {
  const failure = new Error("Network unavailable");
  try {
    await restoreSession(() => Promise.reject(failure));
  } catch (error) {
    if (error === failure) return;
    throw error;
  }
  throw new Error("Restoration failure was swallowed");
});

Deno.test("startup: a stalled session reaches recovery without continuing to routing", async () => {
  let expire;
  const pending = restoreSession(() => new Promise(() => {}), {
    setTimer: (fn) => {
      expire = fn;
      return 1;
    },
    clearTimer: () => {},
  });
  expire();
  try {
    await pending;
  } catch (error) {
    if (error.message === "Session restoration timed out") return;
    throw error;
  }
  throw new Error("Timed-out restoration continued to routing");
});
