// QR code as an SVG node. Uses the vendored qrcode-generator (global `qrcode`, loaded by index.html); no data leaves the browser.
const SVG_NS = "http://www.w3.org/2000/svg";

export function qrSvg(text, { label = "QR code", quiet = 2 } = {}) {
  const qr = globalThis.qrcode(0, "M");
  qr.addData(text);
  qr.make();
  const n = qr.getModuleCount();
  const size = n + quiet * 2;
  let d = "";
  for (let y = 0; y < n; y++) {
    for (let x = 0; x < n; x++) {
      if (qr.isDark(y, x)) d += `M${x + quiet} ${y + quiet}h1v1h-1z`;
    }
  }
  const svg = document.createElementNS(SVG_NS, "svg");
  svg.setAttribute("viewBox", `0 0 ${size} ${size}`);
  svg.setAttribute("role", "img");
  svg.setAttribute("aria-label", label);
  svg.setAttribute("shape-rendering", "crispEdges");
  svg.setAttribute("class", "qr-svg");
  const bg = document.createElementNS(SVG_NS, "rect");
  bg.setAttribute("width", size);
  bg.setAttribute("height", size);
  bg.setAttribute("fill", "#fff");
  const path = document.createElementNS(SVG_NS, "path");
  path.setAttribute("d", d);
  path.setAttribute("fill", "#000");
  svg.append(bg, path);
  return svg;
}

/** The booking id out of a scanned value: the QR link "...#/checkin?b=<id>" or a bare id. */
export function bookingIdFromScan(value) {
  const text = String(value ?? "").trim();
  const m = text.match(/[?&]b=([0-9A-Za-z]{10,40})/);
  const id = m ? m[1] : text;
  return /^[0-9A-Za-z]{10,40}$/.test(id) ? id : null;
}

export function checkinLink(bookingId) {
  return `${location.origin}${location.pathname}#/checkin?b=${bookingId}`;
}
