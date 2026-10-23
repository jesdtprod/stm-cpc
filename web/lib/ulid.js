// Client ULID generator. Same format as core.ulid() in the database:
// 48-bit millisecond timestamp + 80 random bits, Crockford base32, 26 characters.
const ENC = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const FORMAT = /^[0-7][0-9A-HJKMNP-TV-Z]{25}$/;

export function ulid(
  now = Date.now(),
  getRandomValues = (a) => crypto.getRandomValues(a),
) {
  if (!Number.isInteger(now) || now < 0 || now >= 2 ** 48) {
    throw new RangeError("timestamp out of range");
  }
  let ts = now;
  let time = "";
  for (let i = 0; i < 10; i++) {
    time = ENC[ts % 32] + time;
    ts = Math.floor(ts / 32);
  }
  // 256 is a multiple of 32, so `& 31` on a random byte is unbiased.
  const bytes = getRandomValues(new Uint8Array(16));
  let rand = "";
  for (const b of bytes) rand += ENC[b & 31];
  return time + rand;
}

export function isUlid(value) {
  return typeof value === "string" && FORMAT.test(value);
}

/** Creation time of a ULID as a Date. */
export function ulidTime(value) {
  if (!isUlid(value)) throw new RangeError("invalid ULID");
  let ms = 0;
  for (let i = 0; i < 10; i++) ms = ms * 32 + ENC.indexOf(value[i]);
  return new Date(ms);
}
