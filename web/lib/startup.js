/** A failed or timed-out restoration must not route a saved session to sign-in. */
export async function restoreSession(startSession, {
  timeoutMs = 15_000,
  setTimer = setTimeout,
  clearTimer = clearTimeout,
} = {}) {
  let timer;
  try {
    return await Promise.race([
      Promise.resolve().then(startSession),
      new Promise((_, reject) => {
        timer = setTimer(
          () => reject(new Error("Session restoration timed out")),
          timeoutMs,
        );
      }),
    ]);
  } finally {
    clearTimer(timer);
  }
}
