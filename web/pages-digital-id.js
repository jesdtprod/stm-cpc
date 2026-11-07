// My Digital ID (Members Portal): the signed-in member's club ID card with photo, member ID and a QR of the member ID.
// Read only. The QR carries the member ID only (never a password, token or contact detail).
import { attachPagePattern, badge, h, icon, memberHero } from "./ui.js";
import { avatarImage, signedAvatarUrls } from "./lib/avatar.js";
import { qrSvg } from "./lib/qr.js";

export function createDigitalIdPages({ session, client }) {
  function digitalIdPage() {
    const me = session.getState().access ?? {};
    const page = h("div", { class: "page digital-id-page" });
    attachPagePattern(page);

    const name = me.display_name || "CPC Member";
    const photo = h("div", { class: "digital-id-photo", "aria-hidden": "true" }, avatarImage(null, name));
    if (me.avatar_path && client) {
      signedAvatarUrls(client, [me.avatar_path])
        .then((urls) => photo.replaceChildren(avatarImage(urls.get(me.avatar_path) ?? null, name)))
        .catch(() => {});
    }

    let qr = null;
    if (me.member_no && globalThis.qrcode) {
      try {
        qr = qrSvg(me.member_no, { label: `QR code for member ID ${me.member_no}` });
      } catch {
        qr = null;
      }
    }

    const active = me.status === "active";
    const card = h(
      "section",
      { class: "member-panel digital-id-card", "aria-label": "Digital member ID" },
      h(
        "div",
        { class: "digital-id-head" },
        h("span", { class: "digital-id-club" }, icon("idCard"), "Capitol Pickleball Club"),
        badge(active ? "Active Member" : (me.status || "Pending"), active ? "success" : "warning"),
      ),
      h(
        "div",
        { class: "digital-id-body" },
        photo,
        h(
          "div",
          { class: "digital-id-meta" },
          h("strong", { class: "digital-id-name" }, name),
          h("span", { class: "digital-id-no" }, me.member_no || "Assigned on approval"),
        ),
      ),
      qr
        ? h("div", { class: "digital-id-qr" }, qr)
        : h("p", { class: "sub" }, "Your QR code appears once a member ID is assigned."),
      h("p", { class: "sub digital-id-note" }, "Show this ID at the club when asked. Keep your screen brightness up for scanning."),
    );

    page.append(
      memberHero({
        iconName: "idCard",
        eyebrow: me.member_no ?? "Your Account",
        title: "My Digital ID",
        chip: "Member ID",
        description: "Your club membership card, always with you.",
      }),
      card,
    );
    return page;
  }

  return { digitalIdPage };
}
