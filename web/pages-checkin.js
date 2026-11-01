// Court check-in by QR (staff with bookings.checkin). A scanned QR opens "#/checkin?b=<booking id>", which checks the
// booking in at once; scan_check_in refuses it outside the booking's own time range. The page can also scan with the
// camera (where supported) or enter a booking code.
import {
  attachPagePattern,
  button,
  h,
  icon,
  iconButton,
  inputWithIcon,
  toast,
} from "./ui.js";
import { formatDateTime } from "./lib/dates.js";
import { bookingIdFromScan, createScanGate } from "./lib/qr.js";
import { bookingMessage } from "./pages-booking.js";
import { createCheckinCourtBoard } from "./lib/checkin-court-board.js";
import { buttonClasses } from "./lib/buttons.js";

export function createCheckinPages({ api }) {
  function checkinPage() {
    let stream = null;
    let busy = false;
    let facingMode = "environment";
    const courtBoard = createCheckinCourtBoard({ api });

    // Result panel container
    const resultPanel = h("div", {
      class: "checkin-result-slot",
      role: "status",
      "aria-live": "polite",
    });

    function showResult(content) {
      resultPanel.hidden = false;
      resultPanel.replaceChildren(content);
    }

    function renderLoading() {
      const tile = (wide = false) =>
        h(
          "div",
          { class: `checkin-data-tile${wide ? " is-wide" : ""}` },
          h("span", { class: "sk checkin-sk-label" }),
          h("span", { class: "sk checkin-sk-value" }),
        );
      return h(
        "div",
        {
          class: "checkin-status-card is-loading",
          "aria-busy": "true",
          "aria-label": "Verifying booking",
        },
        h(
          "div",
          { class: "checkin-status-top", "aria-hidden": "true" },
          h("span", { class: "sk checkin-sk-confirmation" }),
          h("span", { class: "sk checkin-sk-time" }),
        ),
        h(
          "div",
          { class: "checkin-member-hero", "aria-hidden": "true" },
          h("span", { class: "sk checkin-member-avatar" }),
          h(
            "div",
            { class: "checkin-member-meta" },
            h("span", { class: "sk checkin-sk-name" }),
            h("span", { class: "sk checkin-sk-status" }),
          ),
        ),
        h(
          "div",
          { class: "checkin-data-grid", "aria-hidden": "true" },
          tile(),
          tile(),
          tile(true),
        ),
      );
    }

    function renderSuccess(r) {
      return h(
        "div",
        { class: "checkin-status-card is-success" },
        h(
          "div",
          { class: "checkin-status-top" },
          h(
            "span",
            { class: "checkin-status-badge is-success" },
            icon("checkCircle"),
            "CHECK-IN CONFIRMED",
          ),
          h("span", { class: "checkin-time-tag" }, "Just now"),
        ),
        h(
          "div",
          { class: "checkin-member-hero" },
          h(
            "div",
            { class: "checkin-member-avatar", "aria-hidden": "true" },
            icon("user"),
          ),
          h(
            "div",
            { class: "checkin-member-meta" },
            h(
              "h3",
              { class: "checkin-member-name" },
              r.member_name || "Club Member",
            ),
            r.member_no
              ? h("span", { class: "badge is-neutral" }, r.member_no)
              : null,
          ),
        ),
        h(
          "div",
          { class: "checkin-data-grid" },
          h(
            "div",
            { class: "checkin-data-tile" },
            h("span", { class: "checkin-tile-label" }, "COURT"),
            h("strong", { class: "checkin-tile-value" }, r.court || "Court"),
          ),
          h(
            "div",
            { class: "checkin-data-tile" },
            h("span", { class: "checkin-tile-label" }, "BOOKING REF"),
            h("strong", { class: "checkin-tile-value mono" }, r.doc_no || ""),
          ),
          h(
            "div",
            { class: "checkin-data-tile is-wide" },
            h("span", { class: "checkin-tile-label" }, "SCHEDULE"),
            h(
              "div",
              { class: "checkin-tile-time" },
              icon("clock"),
              h(
                "span",
                {},
                `${formatDateTime(new Date(r.starts_at))} – ${
                  formatDateTime(new Date(r.ends_at))
                }`,
              ),
            ),
          ),
        ),
      );
    }

    function clearResult() {
      resultPanel.replaceChildren();
      resultPanel.hidden = true;
    }

    function showCheckinError(title, lines = []) {
      clearResult();
      toast(lines.join(" "), { title, tone: "error", timeout: 5000 });
    }

    // Keep the result area hidden until a scan or manual check-in.
    resultPanel.hidden = true;

    // Video & Camera Elements
    const video = h("video", {
      class: "checkin-video",
      playsinline: "",
      muted: "",
      hidden: true,
    });
    const cameraHudState = h("span", { id: "camera-hud-state" }, "Standby");
    const standbyOverlay = h(
      "div",
      { class: "checkin-standby-overlay", hidden: true },
      h("span", { class: "badge-icon", "aria-hidden": "true" }, icon("qrScan")),
      h("p", { class: "standby-title" }, "Camera Paused"),
      h("p", { class: "sub" }, "Use the camera icon above to resume scanning."),
    );

    const cameraLoading = h("div", {
      class: "checkin-camera-loading",
      "aria-hidden": "true",
    }, h("span", { class: "sk" }));
    const frame = h(
      "div",
      {
        class: "checkin-scan-frame",
        "aria-label": "Scanner viewfinder",
        "aria-busy": "true",
      },
      video,
      cameraLoading,
      h(
        "div",
        { class: "checkin-camera-hud" },
        h(
          "span",
          { class: "checkin-hud-pill" },
          icon("qrScan"),
          "SCANNER",
        ),
        h(
          "span",
          { class: "checkin-hud-pill is-live" },
          h("span", { class: "checkin-live-dot" }),
          cameraHudState,
        ),
      ),
      h(
        "div",
        { class: "checkin-reticle-box" },
        h("span", { class: "checkin-corner top-left" }),
        h("span", { class: "checkin-corner top-right" }),
        h("span", { class: "checkin-corner bottom-left" }),
        h("span", { class: "checkin-corner bottom-right" }),
        h("span", { class: "checkin-scan-line" }),
      ),
      h(
        "div",
        { class: "checkin-camera-guide" },
        "Position QR code inside frame",
      ),
      standbyOverlay,
    );

    function setCameraLoading(loading) {
      cameraLoading.hidden = !loading;
      frame.setAttribute("aria-busy", String(loading));
    }

    // Camera action buttons
    const cameraToggleBtn = iconButton({
      label: "Resume Camera",
      icon: "play",
      variant: "secondary",
      size: "sm",
      onClick: () => {
        if (stream) {
          stopCamera();
          standbyOverlay.hidden = false;
        } else {
          startCamera();
        }
      },
    });

    const cameraFlipBtn = iconButton({
      label: "Flip Camera",
      icon: "refresh",
      variant: "secondary",
      size: "sm",
      onClick: () => {
        facingMode = facingMode === "environment" ? "user" : "environment";
        stopCamera();
        startCamera();
      },
    });

    function setCameraToggle(running) {
      const label = running ? "Pause Camera" : "Resume Camera";
      cameraToggleBtn.replaceChildren(icon(running ? "pause" : "play"));
      cameraToggleBtn.setAttribute("aria-label", label);
      cameraToggleBtn.setAttribute("title", label);
    }

    function stopCamera() {
      stream?.getTracks().forEach((t) => t.stop());
      stream = null;
      setCameraLoading(false);
      video.hidden = true;
      frame.classList.remove("is-live");
      cameraHudState.textContent = "Standby";
      setCameraToggle(false);
    }

    async function checkIn(raw) {
      const id = bookingIdFromScan(raw);
      if (!id) {
        showCheckinError("Not a booking code", [
          "Enter a valid booking code, such as BK-2026-00001, or scan the booking QR.",
        ]);
        return;
      }
      if (busy) return;
      busy = true;
      manualSubmitBtn.disabled = true;
      showResult(renderLoading());

      try {
        const r = await api.rpc("scan_check_in", {
          p_booking_id: id,
          p_key: api.newKey(),
        });
        showResult(renderSuccess(r));
        courtBoard.refresh();
        toast(`Checked in · ${r.member_name ?? ""}`, { tone: "success" });
        if (navigator.vibrate) {
          try {
            navigator.vibrate([40, 60, 80]);
          } catch {
            /* vibration optional */
          }
        }
        return true;
      } catch (e) {
        showCheckinError("Cannot check in", [bookingMessage(e)]);
      } finally {
        if (resultPanel.querySelector(".is-loading")) clearResult();
        busy = false;
        manualSubmitBtn.disabled = false;
      }
    }

    async function startCamera() {
      if (stream) return; // already active
      setCameraLoading(true);
      if (!navigator.mediaDevices?.getUserMedia) {
        setCameraLoading(false);
        showCheckinError("Camera unavailable", [
          "Allow camera access, or use Manual Check-In below.",
        ]);
        standbyOverlay.hidden = false;
        return;
      }
      try {
        standbyOverlay.hidden = true;
        try {
          stream = await navigator.mediaDevices.getUserMedia({
            video: { facingMode },
          });
        } catch (e) {
          // Fallback if rear/front constraint fails
          if (!["OverconstrainedError", "NotFoundError"].includes(e?.name)) {
            throw e;
          }
          stream = await navigator.mediaDevices.getUserMedia({ video: true });
        }
        video.muted = true;
        video.srcObject = stream;
        video.hidden = false;
        await video.play();
        setCameraLoading(false);
        frame.classList.add("is-live");
        cameraHudState.textContent = "Live";
        setCameraToggle(true);

        const detector = "BarcodeDetector" in globalThis
          ? new globalThis.BarcodeDetector({ formats: ["qr_code"] })
          : null;
        const canvas = document.createElement("canvas");
        const ctx = canvas.getContext("2d", { willReadFrequently: true });
        const read = async () => {
          if (detector) return (await detector.detect(video))[0]?.rawValue;
          if (!video.videoWidth) return null;
          canvas.width = video.videoWidth;
          canvas.height = video.videoHeight;
          ctx.drawImage(video, 0, 0);
          const img = ctx.getImageData(0, 0, canvas.width, canvas.height);
          return globalThis.jsQR(img.data, img.width, img.height)?.data;
        };

        const acceptScan = createScanGate();
        const tick = async () => {
          if (!stream) return;
          try {
            const value = await read();
            if (!busy && acceptScan(value)) checkIn(value);
          } catch {
            /* keep scanning */
          }
          setTimeout(() => requestAnimationFrame(tick), 120);
        };
        tick();
      } catch (e) {
        stopCamera();
        standbyOverlay.hidden = false;
        const why = {
          NotAllowedError:
            "Camera access was blocked. Please grant camera permission in your browser settings.",
          SecurityError:
            "Camera access was blocked. Please check your browser permissions.",
          NotFoundError: "No camera was detected on this device.",
          NotReadableError:
            "Camera is in use by another application. Please close other camera apps.",
        }[e?.name] ?? `Unable to open camera (${e?.name ?? "unknown"}).`;
        showCheckinError("Camera unavailable", [
          why,
          "You can use Manual Check-In below while the camera is unavailable.",
        ]);
      }
    }

    const manualInput = h("input", {
      class: "input",
      id: "checkin-manual-code",
      name: "booking_code",
      required: true,
      autocomplete: "off",
      autocapitalize: "characters",
      spellcheck: "false",
      placeholder: "e.g. BK-2026-00001",
      "aria-describedby": "checkin-manual-hint",
    });
    const manualSubmitBtn = button({
      label: "Check In",
      icon: "checkCircle",
      variant: "primary",
      type: "submit",
    });
    const manualPanel = h(
      "section",
      {
        class: "checkin-manual-panel",
        "aria-labelledby": "checkin-manual-title",
      },
      h(
        "div",
        { class: "checkin-head-lead" },
        h(
          "span",
          { class: "badge-icon", "aria-hidden": "true" },
          icon("keyRound"),
        ),
        h(
          "div",
          {},
          h("div", { class: "eyebrow" }, "Booking verification"),
          h("h2", { id: "checkin-manual-title" }, "Manual Check-In"),
        ),
      ),
      h(
        "p",
        { class: "sub", id: "checkin-manual-hint" },
        "Enter the booking code from the member's pass. Check-in opens during the reserved time slot.",
      ),
      h(
        "form",
        {
          class: "checkin-manual-form",
          onSubmit: async (event) => {
            event.preventDefault();
            if (busy) return;
            if (await checkIn(manualInput.value.trim())) manualInput.value = "";
          },
        },
        h(
          "div",
          { class: "field" },
          h("label", { for: "checkin-manual-code" }, "Booking code"),
          inputWithIcon(manualInput, "qrScan"),
        ),
        manualSubmitBtn,
      ),
    );

    // Hash parameter check: "#/checkin?b=..."
    const hash = location.hash.split("?")[1] ?? "";
    const fromLink = new URLSearchParams(hash).get("b");
    if (fromLink) {
      history.replaceState(null, "", "#/checkin");
      queueMicrotask(() => checkIn(fromLink));
    }

    addEventListener("hashchange", stopCamera, { once: true });
    queueMicrotask(startCamera);

    const workspaceGrid = h("div", { class: "checkin-grid" });

    const accountLink = h("a", {
      class: buttonClasses({
        variant: "secondary",
        size: "sm",
        iconOnly: true,
      }),
      href: "#/profile",
      "aria-label": "My Account",
      title: "My Account",
    }, icon("userCircle"));
    const scannerActions = h(
      "div",
      {
        class: "checkin-scanner-actions",
        role: "group",
        "aria-label": "Scanner controls",
      },
      accountLink,
      cameraToggleBtn,
      cameraFlipBtn,
    );
    const root = h(
      "div",
      { class: "page admin-dashboard checkin-page" },
      h("div", { class: "checkin-workspace" }, workspaceGrid),
    );

    // Left column: Camera Scanner Panel
    const scannerPanel = h(
      "section",
      { class: "checkin-scanner-panel", "aria-label": "QR Scanner Viewport" },
      h(
        "div",
        { class: "checkin-card-head" },
        h(
          "div",
          { class: "checkin-head-lead" },
          h(
            "span",
            { class: "badge-icon", "aria-hidden": "true" },
            icon("qrScan"),
          ),
          h(
            "div",
            {},
            h("div", { class: "eyebrow" }, "Visual Scanner"),
            h("h1", {}, "Scan Booking Pass"),
          ),
        ),
        scannerActions,
      ),
      h(
        "p",
        { class: "sub" },
        "Position the member's booking QR pass in front of the camera to verify access.",
      ),
      frame,
    );

    scannerPanel.append(manualPanel, resultPanel);
    const consolePanel = h(
      "section",
      {
        class: "checkin-console-panel",
        "aria-label": "Court status",
      },
      courtBoard.element,
    );

    workspaceGrid.append(scannerPanel, consolePanel);
    attachPagePattern(root);
    return root;
  }
  return { checkinPage };
}
