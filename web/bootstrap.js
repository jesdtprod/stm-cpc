// Clickjacking guard: GitHub Pages cannot send frame-ancestors or X-Frame-Options, so the app refuses to run inside
// another page's frame and asks the top window to open it directly. Local development may still be framed (editor
// previews).
const LOCAL = ["localhost", "127.0.0.1", "[::1]"].includes(location.hostname);
if (globalThis.top !== globalThis.self && !LOCAL) {
  const link = document.createElement("a");
  link.href = location.href;
  link.target = "_top";
  link.rel = "noopener";
  link.textContent = "Open Capitol Pickleball Club";
  document.body.replaceChildren(link);
  try {
    globalThis.top.location.href = location.href;
  } catch {
    // a sandboxed frame may block this; the link above still works
  }
  throw new Error("The app does not run inside a frame.");
}

// Keep a visible recovery screen even when an application module cannot load.
const startup = document.getElementById("startup");
let stopPattern = () => {};

try {
  const { setupConvexPatternCanvas } = await import(
    "./ui.js"
  );
  const canvas = document.getElementById("startup-pattern");
  const court = document.getElementById("startup-court");
  if (canvas.getContext("2d")) {
    stopPattern = setupConvexPatternCanvas(canvas, startup, court);
    startup.dataset.patternReady = "true";
  }
  await import("./app.js");
  stopPattern();
  startup.remove();
  delete document.body.dataset.booting;
} catch {
  stopPattern();
  startup.setAttribute("role", "alert");
  startup.querySelector("h1").textContent = "Unable to load your account";
  startup.querySelector("p").textContent =
    "Check your connection, then try again.";
  startup.querySelector(".startup-progress").hidden = true;
  const retry = document.createElement("button");
  retry.type = "button";
  retry.className = "btn btn-primary";
  retry.textContent = "Try Again";
  retry.addEventListener("click", () => location.reload());
  startup.querySelector(".startup-card").append(retry);
}
