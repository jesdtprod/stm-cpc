// Court check-in by QR (staff with bookings.checkin). A scanned QR opens "#/checkin?b=<booking id>", which checks the
// booking in at once; scan_check_in refuses it outside the booking's own time range. The page can also scan with the
// camera (where the browser supports it) or take a pasted code.
import {
  adminHero,
  attachPagePattern,
  button,
  card,
  h,
  icon,
  toast,
} from "./ui.js";
import { formatDateTime } from "./lib/dates.js";
import { bookingIdFromScan } from "./lib/qr.js";
import { bookingMessage } from "./pages-booking.js";

export function createCheckinPages({ api }) {
  function checkinPage() {
    const result = h("div", {
      class: "checkin-result",
      hidden: true,
      role: "status",
      "aria-live": "polite",
    });
    const video = h("video", {
      class: "checkin-video",
      playsinline: "",
      muted: "",
      hidden: true,
    });
    // The dashed square at the top: shows the scan icon, and the live camera while scanning.
    const frame = h(
      "div",
      { class: "checkin-scan-frame", "aria-hidden": "true" },
      icon("qrScan"),
      video,
    );
    let stream = null;
    let busy = false;

    function show(tone, title, lines = []) {
      result.hidden = false;
      result.className = `checkin-result is-${tone}`;
      result.replaceChildren(
        h(
          "span",
          { class: "checkin-result-icon", "aria-hidden": "true" },
          icon(
            tone === "success"
              ? "checkCircle"
              : tone === "danger"
              ? "alertCircle"
              : "info",
          ),
        ),
        h(
          "div",
          { class: "checkin-result-copy" },
          h("strong", {}, title),
          ...lines.map((l) => h("p", { class: "sub" }, l)),
        ),
      );
    }

    function stopCamera() {
      stream?.getTracks().forEach((t) => t.stop());
      stream = null;
      video.hidden = true;
      frame.classList.remove("is-live");
    }

    async function checkIn(raw) {
      const id = bookingIdFromScan(raw);
      if (!id) {
        return show("danger", "Not a booking code", [
          "Scan the member's QR or type the booking code, like BK-2026-00001.",
        ]);
      }
      if (busy) return;
      busy = true;
      show("neutral", "Checking…");
      try {
        const r = await api.rpc("scan_check_in", {
          p_booking_id: id,
          p_key: api.newKey(),
        });
        show("success", `Checked in · ${r.member_name ?? ""}`, [
          `${r.court} · ${r.doc_no}`,
          `${formatDateTime(new Date(r.starts_at))} – ${
            formatDateTime(new Date(r.ends_at))
          }`,
        ]);
        toast("Checked in.", { tone: "success" });
      } catch (e) {
        show("danger", "Cannot check in", [bookingMessage(e)]);
      } finally {
        busy = false;
      }
    }

    async function startCamera() {
      if (!navigator.mediaDevices?.getUserMedia) {
        return show("neutral", "Camera scanning is not available here", [
          "Use HTTPS, scan with the phone camera app, or paste the code below.",
        ]);
      }
      try {
        try {
          stream = await navigator.mediaDevices.getUserMedia({
            video: { facingMode: "environment" },
          });
        } catch (e) {
          // No rear camera (a laptop, say): take whichever camera there is.
          if (!["OverconstrainedError", "NotFoundError"].includes(e?.name)) {
            throw e;
          }
          stream = await navigator.mediaDevices.getUserMedia({ video: true });
        }
        video.muted = true;
        video.srcObject = stream;
        video.hidden = false;
        frame.classList.add("is-live");
        await video.play();
        // The browser's detector where it exists; otherwise the bundled jsQR reads each video frame.
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
        const tick = async () => {
          if (!stream) return;
          try {
            const value = await read();
            if (value) {
              stopCamera();
              return checkIn(value);
            }
          } catch { /* keep scanning */ }
          setTimeout(() => requestAnimationFrame(tick), 120);
        };
        tick();
      } catch (e) {
        stopCamera();
        const why = {
          NotAllowedError:
            "Camera access is blocked. Click the camera icon in the address bar, allow it, then try again.",
          SecurityError:
            "Camera access is blocked. Click the camera icon in the address bar, allow it, then try again.",
          NotFoundError: "No camera was found on this device.",
          NotReadableError:
            "The camera is being used by another app. Close it and try again.",
        }[e?.name] ?? `The camera failed (${e?.name ?? "unknown"}).`;
        show("danger", "The camera could not be opened", [
          why,
          "You can still type the booking code.",
        ]);
      }
    }

    const input = h("input", {
      class: "input",
      id: "checkin-code",
      type: "text",
      placeholder: "Booking code, e.g. BK-2026-00001",
      "aria-label": "Scanned code",
      autocomplete: "off",
    });
    const form = h(
      "form",
      {
        class: "checkin-manual",
        onSubmit: (e) => {
          e.preventDefault();
          checkIn(input.value);
          input.value = "";
        },
      },
      h(
        "div",
        { class: "field" },
        h("label", { for: "checkin-code" }, "Booking code or QR link"),
        input,
        h(
          "p",
          { class: "field-hint" },
          "Paste the booking link or code from the member's QR.",
        ),
      ),
      button({
        label: "Check In",
        icon: "checkCircle",
        variant: "primary",
        type: "submit",
      }),
    );

    const hash = location.hash.split("?")[1] ?? "";
    const fromLink = new URLSearchParams(hash).get("b");
    if (fromLink) {
      history.replaceState(null, "", "#/checkin");
      queueMicrotask(() => checkIn(fromLink));
    }

    addEventListener("hashchange", stopCamera, { once: true });
    const root = h(
      "div",
      { class: "page admin-dashboard checkin-page" },
      adminHero({
        chip: "Court Operations",
        title: "Check-in",
        description:
          "Scan a booking QR. It works only between the start and end of the booking.",
      }),
      card({
        className: "checkin-workspace",
        content: h(
          "div",
          { class: "checkin-layout" },
          h(
            "section",
            { class: "checkin-scanner", "aria-label": "Scan a booking QR" },
            h(
              "div",
              { class: "checkin-entry-head" },
              h(
                "span",
                { class: "badge-icon", "aria-hidden": "true" },
                icon("qrScan"),
              ),
              h(
                "div",
                {},
                h("div", { class: "eyebrow" }, "Camera check-in"),
                h("h2", {}, "Scan booking QR"),
              ),
            ),
            h(
              "p",
              { class: "sub" },
              "Point your camera at the member's booking QR to check them in.",
            ),
            frame,
            button({
              label: "Scan with camera",
              icon: "qrScan",
              onClick: startCamera,
            }),
          ),
          h(
            "section",
            {
              class: "checkin-entry",
              "aria-labelledby": "checkin-entry-title",
            },
            h(
              "div",
              { class: "checkin-entry-head" },
              h(
                "span",
                { class: "badge-icon", "aria-hidden": "true" },
                icon("qrScan"),
              ),
              h(
                "div",
                {},
                h("div", { class: "eyebrow" }, "Manual check-in"),
                h("h2", { id: "checkin-entry-title" }, "Enter booking code"),
              ),
            ),
            h(
              "p",
              { class: "sub" },
              "Have a booking code? Enter it below to confirm arrival.",
            ),
            form,
            result,
            h(
              "p",
              { class: "checkin-note sub" },
              icon("info"),
              "Check-in is available only during the booked time slot.",
            ),
          ),
        ),
      }),
    );
    attachPagePattern(root);
    return root;
  }
  return { checkinPage };
}
