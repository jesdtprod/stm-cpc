import assert from "node:assert/strict";
import {
  AVATAR_MAX_PICK_BYTES,
  avatarFileError,
  avatarImage,
  signedAvatarUrls,
} from "../../web/lib/avatar.js";

Deno.test("photos: 3 MB is accepted and larger files are rejected before resizing", () => {
  assert.equal(AVATAR_MAX_PICK_BYTES, 3 * 1024 * 1024);
  for (const type of ["image/jpeg", "image/png", "image/webp"]) {
    assert.equal(avatarFileError({ type, size: AVATAR_MAX_PICK_BYTES }), null);
    assert.match(
      avatarFileError({ type, size: AVATAR_MAX_PICK_BYTES + 1 }),
      /3 MB/,
    );
  }
  assert.match(
    avatarFileError({ type: "image/svg+xml", size: 100 }),
    /JPG, PNG or WebP/,
  );
  assert.match(avatarFileError({ type: "image/jpeg", size: 0 }), /empty/);
});

Deno.test("photos: broken signed images fall back to initials", () => {
  const previous = globalThis.document;
  let fail;
  let replacement;
  globalThis.document = {
    createTextNode: (textContent) => ({ textContent }),
    createElement: () => ({
      addEventListener: (type, handler) => {
        if (type === "error") fail = handler;
      },
      replaceWith: (node) => replacement = node,
    }),
  };
  try {
    const image = avatarImage(
      "https://example.invalid/signed-photo",
      "Sample Member",
    );
    assert.equal(image.alt, "");
    fail();
    assert.equal(replacement.textContent, "SM");
    assert.equal(avatarImage(null, "Sample Member").textContent, "SM");
  } finally {
    if (previous === undefined) delete globalThis.document;
    else globalThis.document = previous;
  }
});

Deno.test("photos: missing or unauthorized storage objects do not expose broken links", async () => {
  const client = {
    storage: {
      from: (bucket) => {
        assert.equal(bucket, "avatars");
        return {
          createSignedUrls: (paths) => {
            assert.deepEqual(paths, ["sample/photo.jpg", "sample/missing.jpg"]);
            return {
              data: [
                {
                  path: paths[0],
                  signedUrl: "https://example.invalid/signed-photo",
                },
                { path: paths[1], error: "Object not found", signedUrl: "" },
              ],
            };
          },
        };
      },
    },
  };
  const urls = await signedAvatarUrls(client, [
    null,
    "sample/photo.jpg",
    "sample/photo.jpg",
    "sample/missing.jpg",
  ]);
  assert.equal(urls.size, 1);
  assert.equal(urls.has("sample/missing.jpg"), false);
});
