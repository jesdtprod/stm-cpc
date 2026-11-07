// Draws the on-screen Digital ID card onto a canvas and returns it as a PNG blob with rounded, transparent corners. Positions, fonts, colours and borders are
// read from the live card, so the download always matches what the member sees. Nothing leaves the browser.
const MASK_URL = "icons/digital-id-photo-mask.svg";
const ART_SCALE = 1.015; // the same slight oversize the screen uses to hide the artwork's edge

const loadImage = (src) =>
  new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error("image failed"));
    img.src = src;
  });

export async function renderDigitalIdBlob(card) {
  await document.fonts?.ready;
  const art = card.querySelector(".digital-id-art");
  const W = art.naturalWidth || 2598;
  const H = art.naturalHeight || 1668;
  const box = card.getBoundingClientRect();
  const s = W / box.width;
  const rect = (el) => {
    const r = el.getBoundingClientRect();
    return { x: (r.left - box.left) * s, y: (r.top - box.top) * s, w: r.width * s, h: r.height * s };
  };
  const px = (v) => (parseFloat(v) || 0) * s;

  const canvas = document.createElement("canvas");
  canvas.width = W;
  canvas.height = H;
  const ctx = canvas.getContext("2d");
  // Everything is clipped to the card's rounded corners; the corners stay transparent (PNG), as on screen.
  ctx.beginPath();
  ctx.roundRect(0, 0, W, H, px(getComputedStyle(card).borderTopLeftRadius));
  ctx.clip();
  ctx.fillStyle = "#0b2a17";
  ctx.fillRect(0, 0, W, H);

  // 1. Photo, under the artwork (the artwork has a window cut out for it).
  const photo = card.querySelector(".digital-id-photo");
  const pr = rect(photo);
  const radius = px(getComputedStyle(photo).borderTopLeftRadius);
  ctx.save();
  ctx.beginPath();
  ctx.roundRect(pr.x, pr.y, pr.w, pr.h, radius);
  ctx.clip();
  ctx.fillStyle = "#fff";
  ctx.fillRect(pr.x, pr.y, pr.w, pr.h);
  const photoImg = photo.querySelector("img");
  let drawn = false;
  if (photoImg?.src) {
    try {
      // Fetched as a blob so the signed picture never taints the canvas.
      const bitmap = await createImageBitmap(await (await fetch(photoImg.src)).blob());
      const k = Math.max(pr.w / bitmap.width, pr.h / bitmap.height);
      const dw = bitmap.width * k;
      const dh = bitmap.height * k;
      ctx.drawImage(bitmap, pr.x + (pr.w - dw) / 2, pr.y + (pr.h - dh) / 2, dw, dh);
      drawn = true;
    } catch {
      drawn = false;
    }
  }
  if (!drawn) {
    const cs = getComputedStyle(photo);
    ctx.fillStyle = "#0c3a1f";
    ctx.font = `${cs.fontWeight} ${px(cs.fontSize)}px ${cs.fontFamily}`;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(photo.textContent.trim().slice(0, 2).toUpperCase(), pr.x + pr.w / 2, pr.y + pr.h / 2);
  }
  ctx.restore();

  // 2. Artwork with its photo window, slightly oversized around the centre.
  const layer = document.createElement("canvas");
  layer.width = W;
  layer.height = H;
  const lctx = layer.getContext("2d");
  lctx.drawImage(art, 0, 0, W, H);
  try {
    lctx.globalCompositeOperation = "destination-in";
    lctx.drawImage(await loadImage(MASK_URL), 0, 0, W, H);
  } catch {
    // without the mask the photo window stays covered; the rest of the card is unaffected
  }
  ctx.save();
  ctx.translate(W / 2, H / 2);
  ctx.scale(ART_SCALE, ART_SCALE);
  ctx.translate(-W / 2, -H / 2);
  ctx.drawImage(layer, 0, 0);
  ctx.restore();

  // 2b. Holographic CPC sticker, drawn once: the holographic logo (already prismatic) at 25% opacity,
  // softened at the edge and slightly turned, so it blends into the artwork underneath instead of sitting on top of it.
  const sticker = card.querySelector(".digital-id-holo-sticker");
  const logo = sticker?.querySelector("img");
  if (sticker && logo?.complete && logo.naturalWidth) {
    try {
      const size = Math.round(sticker.offsetWidth * s);
      const sb = rect(sticker);
      const cx = sb.x + sb.w / 2;
      const cy = sb.y + sb.h / 2;
      const make = () => {
        const c = document.createElement("canvas");
        c.width = size;
        c.height = size;
        return [c, c.getContext("2d")];
      };
      const k = Math.min(size / logo.naturalWidth, size / logo.naturalHeight);
      const lw = logo.naturalWidth * k;
      const lh = logo.naturalHeight * k;
      const drawLogo = (c) => c.drawImage(logo, (size - lw) / 2, (size - lh) / 2, lw, lh);
      const [out, o] = make();
      o.filter = "hue-rotate(15deg) saturate(0.6) contrast(1.08)";
      drawLogo(o);
      o.filter = "none";
      // Soft elliptical edge, the same fade as the sticker's mask on screen.
      const fade = o.createRadialGradient(size / 2, size / 2, 0, size / 2, size / 2, (size / 2) * Math.SQRT2);
      fade.addColorStop(0.45, "#000");
      fade.addColorStop(0.75, "rgba(0,0,0,0.65)");
      fade.addColorStop(1, "rgba(0,0,0,0)");
      o.globalCompositeOperation = "destination-in";
      o.fillStyle = fade;
      o.fillRect(0, 0, size, size);
      ctx.save();
      ctx.translate(cx, cy);
      ctx.rotate((-2 * Math.PI) / 180);
      ctx.globalAlpha = 0.25;
      ctx.drawImage(out, -size / 2, -size / 2);
      ctx.restore();
    } catch {
      // the card is saved without the hologram if the browser cannot compose it
    }
  }

  // 3. QR tile: white tile, its border, then the dots and corner squares drawn from the SVG.
  const qrBox = card.querySelector(".digital-id-qr");
  const svg = qrBox?.querySelector("svg");
  if (qrBox && svg) {
    const qb = rect(qrBox);
    const cs = getComputedStyle(qrBox);
    const bw = px(cs.borderTopWidth);
    const rr = px(cs.borderTopLeftRadius);
    ctx.fillStyle = "#fff";
    ctx.beginPath();
    ctx.roundRect(qb.x, qb.y, qb.w, qb.h, rr);
    ctx.fill();
    // The tile clips its content on screen (overflow hidden), so the QR is clipped to the same rounded shape here.
    ctx.save();
    ctx.beginPath();
    ctx.roundRect(qb.x, qb.y, qb.w, qb.h, rr);
    ctx.clip();
    const sr = rect(svg);
    const vb = svg.viewBox.baseVal;
    // The SVG element is not square on screen; its content is fitted (meet) and centred, so do the same here.
    const k = Math.min(sr.w / vb.width, sr.h / vb.height);
    sr.x += (sr.w - vb.width * k) / 2;
    sr.y += (sr.h - vb.height * k) / 2;
    for (const el of svg.children) {
      const n = (a) => parseFloat(el.getAttribute(a)) || 0;
      const fill = el.getAttribute("fill");
      const stroke = el.getAttribute("stroke");
      ctx.beginPath();
      if (el.tagName === "circle") {
        ctx.arc(sr.x + n("cx") * k, sr.y + n("cy") * k, n("r") * k, 0, Math.PI * 2);
      } else {
        ctx.roundRect(sr.x + n("x") * k, sr.y + n("y") * k, n("width") * k, n("height") * k, n("rx") * k);
      }
      if (fill && fill !== "none") {
        ctx.fillStyle = fill;
        ctx.fill();
      }
      if (stroke) {
        ctx.strokeStyle = stroke;
        ctx.lineWidth = n("stroke-width") * k;
        ctx.stroke();
      }
    }
    ctx.restore();
    if (bw > 0) {
      ctx.strokeStyle = cs.borderTopColor;
      ctx.lineWidth = bw;
      ctx.beginPath();
      ctx.roundRect(qb.x + bw / 2, qb.y + bw / 2, qb.w - bw, qb.h - bw, Math.max(0, rr - bw / 2));
      ctx.stroke();
    }
  }

  // 4. Text: Player ID, full name, category and the Scan to verify label.
  for (const el of card.querySelectorAll(".digital-id-field, .digital-id-qr-label")) {
    const cs = getComputedStyle(el);
    const r = rect(el);
    let text = el.textContent.trim();
    if (cs.textTransform === "uppercase") text = text.toUpperCase();
    ctx.font = `${cs.fontStyle} ${cs.fontWeight} ${px(cs.fontSize)}px ${cs.fontFamily}`;
    if ("letterSpacing" in ctx) ctx.letterSpacing = `${px(cs.letterSpacing)}px`;
    ctx.fillStyle = cs.color;
    ctx.textBaseline = "middle";
    const centered = cs.textAlign === "center";
    ctx.textAlign = centered ? "center" : "left";
    while (text.length > 1 && ctx.measureText(text).width > r.w) text = `${text.slice(0, -2)}…`;
    ctx.fillText(text, centered ? r.x + r.w / 2 : r.x, r.y + r.h / 2);
  }

  return await new Promise((resolve, reject) =>
    canvas.toBlob((b) => (b ? resolve(b) : reject(new Error("could not create the image"))), "image/png")
  );
}
