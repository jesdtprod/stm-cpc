// Suggests first / last name and extension from a single display name, to pre-fill the profile form for members
// who were imported with only a display name. It is a suggestion shown to the member to check, never stored
// automatically: Filipino names (particles like "dela", compound first names) cannot be split reliably.
const SUFFIXES = {
  jr: "Jr.",
  sr: "Sr.",
  ii: "II",
  iii: "III",
  iv: "IV",
  v: "V",
};
const PARTICLES = new Set([
  "de",
  "del",
  "dela",
  "delos",
  "della",
  "di",
  "da",
  "van",
  "von",
  "san",
  "santa",
  "la",
  "le",
]);

function properName(text) {
  return String(text ?? "").trim().replace(/\s+/gu, " ").toLowerCase().replace(
    /(^|[\s\-'’.,])(\p{L})/gu,
    (_match, separator, letter) => separator + letter.toUpperCase(),
  );
}

/** Directory name from saved parts; display-only, without guessing missing parts. */
export function formatMemberName(person = {}) {
  const first = properName(person.first_name);
  const last = properName(person.last_name);
  if (!first || !last) {
    const display = properName(person.display_name);
    return display.replace(
      /\b(jr|sr|ii|iii|iv|v)\.?$/iu,
      (suffix) => SUFFIXES[suffix.replace(/\.$/u, "").toLowerCase()],
    ) ||
      [last, first].filter(Boolean).join(", ") || "Unknown";
  }
  const middle = String(person.middle_name ?? "").trim().match(/\p{L}/u)?.[0];
  const suffix = String(person.suffix ?? "").trim();
  const extension = SUFFIXES[suffix.replace(/\.$/u, "").toLowerCase()] ??
    properName(suffix);
  return `${last}, ${first}${middle ? ` ${middle.toUpperCase()}.` : ""}${
    extension ? ` ${extension}` : ""
  }`;
}

/** "MARQUEZ" -> "Marquez"; text that already has lower-case letters is left alone. */
function titleIfShouting(text) {
  if (text !== text.toUpperCase() || text === text.toLowerCase()) return text;
  return text.toLowerCase().replace(
    /(^|[\s\-'.])(\p{L})/gu,
    (_m, sep, ch) => sep + ch.toUpperCase(),
  );
}

/** Returns { first, middle, last, suffix } (empty strings when unknown). */
export function suggestNameParts(display) {
  let text = String(display ?? "").trim().replace(/\s+/g, " ");
  let suffix = "";
  const tail = /[,\s]+(jr|sr|ii|iii|iv|v)\.?$/i.exec(text);
  if (tail) {
    suffix = SUFFIXES[tail[1].toLowerCase()];
    text = text.slice(0, tail.index).trim();
  }
  text = titleIfShouting(text.replace(/,\s*$/, ""));
  if (!text) return { first: "", middle: "", last: "", suffix };

  // "Last, First Middle"
  if (text.includes(",")) {
    const [last, ...rest] = text.split(",");
    return {
      first: rest.join(" ").trim(),
      middle: "",
      last: last.trim(),
      suffix,
    };
  }
  const tokens = text.split(" ");
  if (tokens.length === 1) {
    return { first: tokens[0], middle: "", last: "", suffix };
  }
  let lastStart = tokens.length - 1;
  while (lastStart > 1 && PARTICLES.has(tokens[lastStart - 1].toLowerCase())) {
    lastStart--;
  }
  return {
    first: tokens.slice(0, lastStart).join(" "),
    middle: "",
    last: tokens.slice(lastStart).join(" "),
    suffix,
  };
}
