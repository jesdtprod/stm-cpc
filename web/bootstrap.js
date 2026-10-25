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
  retry.textContent = "Try again";
  retry.addEventListener("click", () => location.reload());
  startup.querySelector(".startup-card").append(retry);
}
