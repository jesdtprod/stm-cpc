// Generates the PWA icons (flat navy with a cyan ball). Run: deno run --allow-write=web/icons scripts/make-icons.mjs
import { deflateSync } from "node:zlib";

const crcTable = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
const crc32 = (buf) => {
  let c = 0xffffffff;
  for (const b of buf) c = crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
};
const chunk = (type, data) => {
  const out = new Uint8Array(12 + data.length);
  const view = new DataView(out.buffer);
  view.setUint32(0, data.length);
  out.set(new TextEncoder().encode(type), 4);
  out.set(data, 8);
  view.setUint32(8 + data.length, crc32(out.subarray(4, 8 + data.length)));
  return out;
};

function png(size, ballRatio) {
  const bg = [11, 18, 32];
  const fg = [34, 211, 238];
  const raw = new Uint8Array(size * (size * 3 + 1));
  const c = size / 2;
  const r = size * ballRatio;
  for (let y = 0; y < size; y++) {
    raw[y * (size * 3 + 1)] = 0;
    for (let x = 0; x < size; x++) {
      const inside = (x - c) ** 2 + (y - c) ** 2 <= r * r;
      const px = inside ? fg : bg;
      raw.set(px, y * (size * 3 + 1) + 1 + x * 3);
    }
  }
  const ihdr = new Uint8Array(13);
  const v = new DataView(ihdr.buffer);
  v.setUint32(0, size);
  v.setUint32(4, size);
  ihdr.set([8, 2, 0, 0, 0], 8);
  const parts = [
    new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw)),
    chunk("IEND", new Uint8Array()),
  ];
  return Uint8Array.from(parts.flatMap((p) => [...p]));
}

await Deno.mkdir("web/icons", { recursive: true });
await Deno.writeFile("web/icons/icon-192.png", png(192, 0.32));
await Deno.writeFile("web/icons/icon-512.png", png(512, 0.32));
await Deno.writeFile("web/icons/icon-maskable-512.png", png(512, 0.26));
console.log("icons written");
