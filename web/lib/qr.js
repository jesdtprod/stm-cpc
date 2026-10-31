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

/** The booking id or code out of a scanned or typed value: the QR link "...#/checkin?b=<id>", a bare id, or "BK-YYYY-NNNNN". */
export function bookingIdFromScan(value) {
  const text = String(value ?? "").trim();
  if (/^BK-\d{4}-\d{5}$/i.test(text)) return text.toUpperCase();
  const m = text.match(/[?&]b=([0-9A-Za-z]{10,40})/);
  const id = m ? m[1] : text;
  return /^[0-9A-Za-z]{10,40}$/.test(id) ? id : null;
}

export function checkinLink(bookingId) {
  return `${location.origin}${location.pathname}#/checkin?b=${bookingId}`;
}

/** Draws the court pass (same look as the on-screen ticket) on a canvas and resolves to a JPEG blob. */
export function ticketJpgBlob({ court, ref, date, time, link }) {
  const qr = globalThis.qrcode(0, "M");
  qr.addData(link);
  qr.make();
  const n = qr.getModuleCount();
  const S = 3; // output scale; everything below is drawn in 1x units
  const M = 16; // margin around the card
  const CW = 376;
  const CH = 450;
  const canvas = document.createElement("canvas");
  canvas.width = (CW + M * 2) * S;
  canvas.height = (CH + M * 2) * S;
  const g = canvas.getContext("2d");
  g.scale(S, S);
  const font = "system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif";
  const gold = "#dfb756";
  g.fillStyle = "#07130d";
  g.fillRect(0, 0, CW + M * 2, CH + M * 2);
  g.translate(M, M);

  const rr = (x, y, w, h, r) => {
    g.beginPath();
    g.roundRect(x, y, w, h, r);
  };
  const text = (
    t,
    x,
    y,
    { size, weight = 600, color, align = "left", spacing = 0, max } = {},
  ) => {
    g.font = `${weight} ${size}px ${font}`;
    g.fillStyle = color;
    g.textAlign = align;
    g.letterSpacing = `${spacing}px`;
    g.fillText(String(t), x, y, max);
    g.letterSpacing = "0px";
  };

  // card
  const bg = g.createLinearGradient(0, 0, CW * 0.4, CH);
  bg.addColorStop(0, "#102a1e");
  bg.addColorStop(1, "#091711");
  g.save();
  rr(0, 0, CW, CH, 16);
  g.fillStyle = bg;
  g.fill();
  g.clip();
  const bar = g.createLinearGradient(0, 0, CW, 0);
  bar.addColorStop(0, "#10b981");
  bar.addColorStop(0.5, gold);
  bar.addColorStop(1, "#10b981");
  g.fillStyle = bar;
  g.fillRect(0, 0, CW, 3);
  // QR bay
  g.fillStyle = "rgba(0,0,0,0.16)";
  g.fillRect(0, 148, CW, CH - 148);
  g.restore();
  rr(0.5, 0.5, CW - 1, CH - 1, 16);
  g.strokeStyle = "rgba(223,183,86,0.28)";
  g.lineWidth = 1;
  g.stroke();

  // header
  text("CAPITOL PICKLEBALL CLUB", 16, 28, {
    size: 10,
    weight: 700,
    color: gold,
    spacing: 1.6,
  });
  rr(CW - 16 - 112, 14, 112, 24, 12);
  g.fillStyle = "rgba(34,197,94,0.12)";
  g.fill();
  g.strokeStyle = "rgba(34,197,94,0.4)";
  g.stroke();
  g.beginPath();
  g.arc(CW - 16 - 112 + 14, 26, 3.5, 0, Math.PI * 2);
  g.fillStyle = "#22c55e";
  g.fill();
  text("Confirmed Pass", CW - 16 - 112 + 24, 30, {
    size: 10.5,
    weight: 700,
    color: "#4ade80",
  });

  text(court, 16, 66, { size: 17, weight: 800, color: "#ffffff", max: 190 });
  g.font = `600 10.5px ${font}`;
  const chipW = Math.max(g.measureText(String(ref)).width + 18, 100);
  rr(CW - 16 - chipW, 50, chipW, 24, 6);
  g.fillStyle = "rgba(255,255,255,0.06)";
  g.fill();
  g.strokeStyle = "rgba(255,255,255,0.14)";
  g.stroke();
  text(ref, CW - 16 - chipW / 2, 66, {
    size: 10.5,
    weight: 600,
    color: gold,
    align: "center",
  });

  // tiles
  const tile = (x, label, value) => {
    rr(x, 84, 164, 44, 8);
    g.fillStyle = "rgba(0,0,0,0.25)";
    g.fill();
    g.strokeStyle = "rgba(255,255,255,0.05)";
    g.stroke();
    text(label.toUpperCase(), x + 12, 100, {
      size: 9.5,
      weight: 700,
      color: "rgba(255,255,255,0.65)",
      spacing: 0.8,
    });
    text(value, x + 12, 118, {
      size: 11.5,
      weight: 700,
      color: "#ffffff",
      max: 142,
    });
  };
  tile(16, "Date", date);
  tile(196, "Time Slot", time);

  // tear line with notches
  g.setLineDash([5, 4]);
  g.strokeStyle = "rgba(223,183,86,0.35)";
  g.lineWidth = 1.5;
  g.beginPath();
  g.moveTo(14, 144);
  g.lineTo(CW - 14, 144);
  g.stroke();
  g.setLineDash([]);
  g.lineWidth = 1;
  g.fillStyle = "#07130d";
  g.beginPath();
  g.arc(0, 144, 7, -Math.PI / 2, Math.PI / 2);
  g.fill();
  g.beginPath();
  g.arc(CW, 144, 7, Math.PI / 2, (Math.PI * 3) / 2);
  g.fill();

  // QR frame
  const fx = (CW - 176) / 2;
  const fy = 168;
  rr(fx, fy, 176, 176, 12);
  g.fillStyle = "#ffffff";
  g.fill();
  const quiet = 1;
  const cell = 160 / (n + quiet * 2);
  g.fillStyle = "#000000";
  for (let y = 0; y < n; y++) {
    for (let x = 0; x < n; x++) {
      if (qr.isDark(y, x)) {
        g.fillRect(
          fx + 8 + (x + quiet) * cell,
          fy + 8 + (y + quiet) * cell,
          cell + 0.4,
          cell + 0.4,
        );
      }
    }
  }
  // gold corner brackets
  g.strokeStyle = gold;
  g.lineWidth = 2;
  g.lineCap = "round";
  const o = 6;
  const L = 14;
  const corner = (cx, cy, dx, dy) => {
    g.beginPath();
    g.moveTo(cx + dx * L, cy);
    g.lineTo(cx, cy);
    g.lineTo(cx, cy + dy * L);
    g.stroke();
  };
  corner(fx - o, fy - o, 1, 1);
  corner(fx + 176 + o, fy - o, -1, 1);
  corner(fx - o, fy + 176 + o, 1, -1);
  corner(fx + 176 + o, fy + 176 + o, -1, -1);

  text("Point at scanner or show to attendant", CW / 2, 376, {
    size: 11,
    weight: 600,
    color: gold,
    align: "center",
  });
  rr(20, 392, CW - 40, 34, 8);
  g.fillStyle = "rgba(255,255,255,0.04)";
  g.fill();
  g.strokeStyle = "rgba(255,255,255,0.1)";
  g.lineWidth = 1;
  g.stroke();
  text("Valid only during your booked time slot", CW / 2, 413, {
    size: 11,
    weight: 600,
    color: "rgba(255,255,255,0.75)",
    align: "center",
  });

  return new Promise((resolve, reject) =>
    canvas.toBlob(
      (b) => b ? resolve(b) : reject(new Error("no image")),
      "image/jpeg",
      0.95,
    )
  );
}

export function downloadBlob(blob, filename) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
