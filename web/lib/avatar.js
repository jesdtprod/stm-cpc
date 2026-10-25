// Profile photos (Supabase Storage bucket "avatars", private).
//   * resizeToJpeg: the picture is cropped to a square and shrunk in the browser before upload, so a phone photo of several
//     megabytes becomes a small file and no camera data (location, device) is kept.
//   * signedAvatarUrls: a private photo is shown through a short-lived signed link, never a public address.

export const AVATAR_TYPES = ["image/jpeg", "image/png", "image/webp"];
export const AVATAR_MAX_PICK_BYTES = 12 * 1024 * 1024;

/** Crops to the centre square and returns a JPEG blob of edge x edge pixels. */
export async function resizeToJpeg(file, edge = 320, quality = 0.85) {
  const bitmap = await createImageBitmap(file);
  const side = Math.min(bitmap.width, bitmap.height);
  const canvas = document.createElement("canvas");
  canvas.width = edge;
  canvas.height = edge;
  const ctx = canvas.getContext("2d");
  ctx.drawImage(
    bitmap,
    (bitmap.width - side) / 2,
    (bitmap.height - side) / 2,
    side,
    side,
    0,
    0,
    edge,
    edge,
  );
  bitmap.close?.();
  return await new Promise((resolve, reject) =>
    canvas.toBlob(
      (blob) => blob ? resolve(blob) : reject(new Error("resize")),
      "image/jpeg",
      quality,
    )
  );
}

/** Map of storage path -> signed URL for the paths that exist. Missing or failed ones are simply left out. */
export async function signedAvatarUrls(client, paths, seconds = 3600) {
  const unique = [...new Set((paths ?? []).filter(Boolean))];
  const urls = new Map();
  if (!unique.length) return urls;
  try {
    const { data } = await client.storage.from("avatars").createSignedUrls(
      unique,
      seconds,
    );
    for (const item of data ?? []) {
      if (item.signedUrl && !item.error) urls.set(item.path, item.signedUrl);
    }
  } catch {
    // The page works without photos.
  }
  return urls;
}

export const initialsOf = (name) =>
  String(name ?? "")
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((w) => w[0].toUpperCase())
    .join("") || "M";
