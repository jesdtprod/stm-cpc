// My Digital ID (Members Portal): the club ID card artwork with the member's photo, Player ID, full name, category and a QR
// of the member ID placed on its blank areas. Read only. The QR carries the member ID only (no password, token or contact).
import { attachPagePattern, button, h, icon, memberHero, toast } from "./ui.js";
import { avatarImage, signedAvatarUrls } from "./lib/avatar.js";
import { qrStyledPngBlob, qrStyledSvg } from "./lib/qr.js";
import { saveImage } from "./lib/save-image.js";
import { renderDigitalIdBlob } from "./lib/digital-id-export.js";
import { enableTilt } from "./lib/tilt.js";
import { enableHologramMotion } from "./lib/hologram-motion.js";
import { formatMemberName } from "./lib/names.js";

export function createDigitalIdPages({ session, client, api }) {
  function digitalIdPage() {
    const me = session.getState().access ?? {};
    const page = h("div", { class: "page digital-id-page" });
    attachPagePattern(page);

    const name = me.display_name || me.first_name || me.last_name
      ? formatMemberName(me)
      : "CPC Member";
    const photo = h("div", { class: "digital-id-photo", role: "img", "aria-label": `Photo of ${name}` }, avatarImage(null, name));
    if (me.avatar_path && client) {
      signedAvatarUrls(client, [me.avatar_path])
        .then((urls) => photo.replaceChildren(avatarImage(urls.get(me.avatar_path) ?? null, name)))
        .catch(() => {});
    }

    const category = h("div", { class: "digital-id-field is-category" }, "—");
    const metaCategory = h("span", { class: "sub digital-id-meta-sub" }, "Skill category synced from your member profile");
    api?.rpc("my_dashboard")
      .then((d) => {
        const rank = d?.member?.rank ?? d?.rank;
        const c = rank?.category;
        const level = rank?.name?.replace(/\s*\([^)]*\)\s*$/, "").trim();
        if (c) {
          const text = level ? `${c} - ${level}` : c;
          category.textContent = text;
          metaCategory.textContent = `Category: ${text}`;
        }
      })
      .catch(() => {});

    let qr = null;
    if (me.member_no && globalThis.qrcode) {
      try {
        qr = [
        h("div", { class: "digital-id-qr" },
          h("div", { class: "digital-id-qr-code" },
            qrStyledSvg(me.member_no, { label: `QR code for member ID ${me.member_no}`, quiet: 4 })),
          h("div", { class: "digital-id-qr-label" }, "Scan to verify")),
      ];
      } catch {
        qr = null;
      }
    }

    const holoSticker = h(
      "div",
      { class: "digital-id-holo-sticker", "aria-hidden": "true" },
      h("img", {
        class: "digital-id-holo-sticker-logo",
        src: "icons/cpc-logo-holo.png",
        alt: "",
        width: 512,
        height: 512,
      }),
      h("span", { class: "digital-id-holo-sticker-grating" }),
      h("span", { class: "digital-id-holo-sticker-rainbow" }),
      h("span", { class: "digital-id-holo-sticker-sparkle" }),
      h("span", { class: "digital-id-holo-sticker-glare" }),
    );

    const card = h(
      "section",
      { class: "digital-id-card", "aria-label": "Digital member ID" },
      h("img", { class: "digital-id-art", src: "icons/digital-id-card.png", alt: "", width: 2598, height: 1668 }),
      photo,
      h("div", { class: "digital-id-field is-id" }, me.member_no || "Assigned on approval"),
      h("div", { class: "digital-id-field is-name", title: name }, name),
      category,
      holoSticker,
      ...(qr ?? []),
    );

    // Full screen view: tap the card or the button; tap again or press Escape to close. Portrait phones turn the card sideways.
    const zoomBtn = button({
      label: "View QR Code",
      icon: "qrCode",
      variant: "secondary",
      class: "digital-id-btn-zoom",
      onClick: () => openQrModal(),
    });
    // View QR Code: a modal with a large QR of the member ID (the same QR as on the card).
    function openQrModal() {
      if (!me.member_no || !globalThis.qrcode) {
        toast("Your QR code appears once a member ID is assigned.", { tone: "info" });
        return;
      }
      let code = null;
      try {
        code = qrStyledSvg(me.member_no, { label: `QR code for member ID ${me.member_no}`, quiet: 2, logo: "icons/cpc-logo-256.webp" });
      } catch {
        toast("Could not show your QR code. Please try again.", { tone: "error" });
        return;
      }
      const opener = document.activeElement;
      const overlay = h("dialog", { class: "digital-id-qr-overlay", "aria-label": "Member QR code. Tap to close." });
      const save = button({
        label: "Download QR", icon: "download",
        class: "digital-id-qr-save",
        onClick: async (event) => {
          event.stopPropagation();
          save.disabled = true;
          try {
            const previewWidth = code.getBoundingClientRect().width;
            const blob = await qrStyledPngBlob(me.member_no, {
              logo: "icons/cpc-logo-256.webp", quiet: 2,
              cornerRadius: 14 * 1024 / previewWidth,
            });
            await saveImage(blob, `${me.member_no}-qr.png`);
          } catch {
            toast("Could not download the QR code. Please try again.", { tone: "error" });
          } finally {
            save.disabled = false;
          }
        },
      });
      overlay.append(h("div", { class: "digital-id-qr-only" }, code),
        h("div", { class: "digital-id-qr-actions" }, save));
      overlay.addEventListener("click", (event) => {
        if (!save.contains(event.target)) overlay.close();
      });
      overlay.addEventListener("close", () => {
        overlay.remove();
        opener?.focus?.();
      }, { once: true });
      document.body.append(overlay);
      overlay.showModal();
    }
    // Download: the card as drawn on screen, saved as a PNG named after the member ID.
    const downloadBtn = button({
      label: "Download ID",
      icon: "download",
      variant: "primary",
      class: "digital-id-btn-download",
      onClick: async () => {
        if (card.classList.contains("is-zoom")) return;
        downloadBtn.disabled = true;
        // Lay the card flat first so a tilt in progress cannot shift the measured positions.
        card.style.transition = "none";
        card.style.transform = "none";
        try {
          const blob = await renderDigitalIdBlob(card);
          const result = await saveImage(blob, `${me.member_no || "CPC"}-digital-id.png`);
          if (result === "downloaded") toast("Your Digital ID was downloaded.", { tone: "success" });
        } catch {
          toast("Could not save your Digital ID. Please try again.", { tone: "error" });
        } finally {
          card.style.removeProperty("transition");
          card.style.removeProperty("transform");
          downloadBtn.disabled = false;
        }
      },
    });

    const copyIdBtn = me.member_no
      ? h(
        "button",
        {
          type: "button",
          class: "digital-id-copy-chip",
          title: "Copy Member ID",
          "aria-label": `Copy Member ID ${me.member_no}`,
          onClick: async () => {
            try {
              await navigator.clipboard.writeText(me.member_no);
              toast("Member ID copied to clipboard.", { tone: "success" });
            } catch {
              toast("Could not copy Member ID.", { tone: "error" });
            }
          },
        },
        icon("copy"),
        h("span", { class: "digital-id-copy-value" }, me.member_no),
      )
      : null;

    // The card moves into an overlay attached to the page body, so it is centred on the screen with space on every side
    // whatever wraps the page, then returns to its place when closed.
    const home = document.createComment("digital-id");
    const overlay = h(
      "div",
      {
        class: "digital-id-zoom",
        role: "dialog",
        "aria-modal": "true",
        "aria-label": "Digital member ID full screen view",
      },
    );
    overlay.addEventListener("click", () => setZoom(false));
    function setZoom(on) {
      if (on === card.classList.contains("is-zoom")) return;
      card.classList.toggle("is-zoom", on);
      card.setAttribute("aria-label", on ? "Digital member ID, full screen. Tap to close." : "Digital member ID. Tap to enlarge.");
      document.body.classList.toggle("digital-id-zoomed", on);
      if (on) {
        card.before(home);
        overlay.append(card);
        document.body.append(overlay);
      } else {
        home.replaceWith(card);
        overlay.remove();
      }
    }
    globalThis.addEventListener("hashchange", () => setZoom(false), { once: true });
    card.setAttribute("role", "button");
    card.tabIndex = 0;
    card.setAttribute("aria-label", "Digital member ID. Tap to enlarge.");
    card.addEventListener("click", () => setZoom(!card.classList.contains("is-zoom")));
    card.addEventListener("keydown", (e) => {
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        setZoom(!card.classList.contains("is-zoom"));
      }
    });
    const onKey = (e) => {
      if (e.key === "Escape") setZoom(false);
      if (!page.isConnected) {
        document.removeEventListener("keydown", onKey);
        document.body.classList.remove("digital-id-zoomed");
      }
    };
    document.addEventListener("keydown", onKey);

    const showcase = h(
      "div",
      { class: "digital-id-showcase" },
      h(
        "header",
        { class: "digital-id-showcase-head" },
        h(
          "div",
          { class: "digital-id-showcase-brand" },
          h("span", { class: "digital-id-showcase-icon", "aria-hidden": "true" }, icon("idCard")),
          h(
            "div",
            { class: "digital-id-showcase-titles" },
            h("span", { class: "digital-id-showcase-title" }, "Official Club Membership Pass"),
            metaCategory,
          ),
        ),
        h(
          "div",
          { class: "digital-id-showcase-chips" },
          copyIdBtn,
          h(
            "span",
            { class: "digital-id-verified-pill" },
            h("span", { class: "status-dot-pulse", "aria-hidden": "true" }),
            "Verified QR",
          ),
        ),
      ),
      h(
        "div",
        { class: "digital-id-stage" },
        card,
        h(
          "div",
          { class: "digital-id-stage-hint", "aria-hidden": "true" },
          icon("eye"),
          h("span", {}, "Tap card to enlarge"),
        ),
      ),
      h(
        "footer",
        { class: "digital-id-deck" },
        h(
          "div",
          { class: "digital-id-guide" },
          h("span", { class: "digital-id-guide-icon", "aria-hidden": "true" }, icon("qrScan")),
          h(
            "div",
            { class: "digital-id-guide-copy" },
            h("p", { class: "digital-id-guide-title" }, "Ready for Court & Event Check-In"),
            h("p", { class: "sub digital-id-note" }, "Show this ID at the club when asked. Tap the card to enlarge it."),
          ),
        ),
        h("div", { class: "digital-id-actions" }, downloadBtn, zoomBtn),
      ),
    );

    enableTilt(page, ".digital-id-card", { max: 8 });
    page.append(
      memberHero({
        iconName: "idCard",
        eyebrow: me.member_no ?? "Your Account",
        title: "My Digital ID",
        chip: "Member ID",
        description: "Your club membership card, always with you.",
      }),
      showcase,
    );
    enableHologramMotion(holoSticker);
    return page;
  }

  return { digitalIdPage };
}
