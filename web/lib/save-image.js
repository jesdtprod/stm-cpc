import { h, openModal, toast } from "../ui.js";
import { downloadBlob } from "./qr.js";

/** iOS shares the PNG so the member can choose Save Image in the Photos action. */
export async function saveImage(blob, filename) {
  const ios = /iPad|iPhone|iPod/.test(navigator.userAgent) ||
    (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  const file = new File([blob], filename, { type: blob.type || "image/png" });
  const data = { files: [file] };
  if (!ios || !navigator.share || !navigator.canShare?.(data)) {
    downloadBlob(blob, filename);
    return "downloaded";
  }
  try {
    await navigator.share(data);
    return "shared";
  } catch (error) {
    if (error.name === "AbortError") return "cancelled";
    if (error.name !== "NotAllowedError") throw error;
    // Rendering can outlast Safari's user activation. A fresh tap shares the ready PNG.
    openModal({
      title: "Save to Photos", icon: "download", size: "sm",
      body: h("p", {}, "Your image is ready. Tap Save to Photos, then choose Save Image."),
      confirmLabel: "Save to Photos", cancelLabel: "Close",
      onConfirm: async () => {
        try {
          await navigator.share(data);
        } catch (retryError) {
          if (retryError.name !== "AbortError") {
            toast("Could not open sharing. Please try again.", { tone: "error" });
            return false;
          }
        }
      },
    });
    return "ready";
  }
}
