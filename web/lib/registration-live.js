// Refresh registration screens after live changes, reconnects and returning to the page.
// Database RLS decides which rows may generate an event for this signed-in client.
export function watchRegistrationChanges({ client, page, refresh }) {
  if (!client?.channel) return () => {};
  let timer;
  let stopped = false;
  let running = false;
  let queued = false;
  const channel = client.channel(`registration-live-${Math.random().toString(36).slice(2, 10)}`);
  const stop = () => {
    if (stopped) return;
    stopped = true;
    clearTimeout(timer);
    globalThis.removeEventListener?.("hashchange", onLeave);
    globalThis.removeEventListener?.("focus", onReturn);
    globalThis.document?.removeEventListener?.("visibilitychange", onReturn);
    client.removeChannel(channel);
  };
  async function reload() {
    if (stopped) return;
    if (page.isConnected === false) return stop();
    if (running) { queued = true; return; }
    running = true;
    try { await refresh(); } finally {
      running = false;
      if (queued && !stopped) { queued = false; schedule(); }
    }
  }
  function schedule() {
    if (stopped) return;
    if (page.isConnected === false) return stop();
    clearTimeout(timer);
    timer = setTimeout(reload, 300);
  }
  const onLeave = () => {
    clearTimeout(timer);
    timer = setTimeout(() => { if (page.isConnected === false) stop(); }, 0);
  };
  const onReturn = () => {
    if (globalThis.document?.visibilityState !== "hidden") schedule();
  };
  for (const table of ["registrations", "events", "divisions"]) {
    channel.on("postgres_changes", { event: "*", schema: "public", table }, schedule);
  }
  channel.subscribe((status) => {
    if (status === "SUBSCRIBED") schedule();
  });
  globalThis.addEventListener?.("hashchange", onLeave);
  globalThis.addEventListener?.("focus", onReturn);
  globalThis.document?.addEventListener?.("visibilitychange", onReturn);
  return stop;
}
