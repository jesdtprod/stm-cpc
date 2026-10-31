// Court check-in by QR (staff with bookings.checkin). A scanned QR opens "#/checkin?b=<booking id>", which checks the
// booking in at once; scan_check_in refuses it outside the booking's own time range. The page can also scan with the
// camera (where the browser supports it) or take a pasted code.
import { adminHero, attachPagePattern, button, card, h, toast } from "./ui.js";
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
    let stream = null;
    let busy = false;

    function show(tone, title, lines = []) {
      result.hidden = false;
      result.className = `checkin-result is-${tone}`;
      result.replaceChildren(
        h("strong", {}, title),
        ...lines.map((l) => h("p", { class: "sub" }, l)),
      );
    }

    function stopCamera() {
      stream?.getTracks().forEach((t) => t.stop());
      stream = null;
      video.hidden = true;
    }

    async function checkIn(raw) {
      const id = bookingIdFromScan(raw);
      if (!id) {
        return show("danger", "Not a booking QR code", [
          "Scan the QR shown on the member's booking.",
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
        stream = await navigator.mediaDevices.getUserMedia({
          video: { facingMode: "environment" },
        });
        video.srcObject = stream;
        video.hidden = false;
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
      } catch {
        stopCamera();
        show("danger", "The camera could not be opened", [
          "Allow camera access, or paste the code below.",
        ]);
      }
    }

    const input = h("input", {
      class: "input",
      id: "checkin-code",
      type: "text",
      placeholder: "Paste the scanned code",
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
        h("label", { for: "checkin-code" }, "Booking QR code"),
        input,
        h(
          "p",
          { class: "field-hint" },
          "Paste the booking link or code from the member's QR.",
        ),
      ),
      button({ label: "Check In", icon: "qrScan", type: "submit" }),
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
        actions: [
          button({
            label: "Scan with camera",
            icon: "qrScan",
            onClick: startCamera,
          }),
        ],
      }),
      card({
        title: "Booking Check-in",
        subtitle: "Scan with your camera or enter a booking code below.",
        content: h("div", { class: "checkin-content" }, video, form, result),
      }),
    );
    attachPagePattern(root);
    return root;
  }
  return { checkinPage };
}
