// Password policy for member accounts (docs/SECURITY.md section 2): at least 12 characters, and nothing
// the club or a stranger could guess from the member's own details. Pure and unit-tested; the same list of
// problem codes drives the messages on the password page (web/pages-account.js).

export const MIN_PASSWORD_LENGTH = 12;
export const MAX_PASSWORD_LENGTH = 128;

export type Problem =
  | "too_short"
  | "too_long"
  | "first_password"
  | "contains_member_id"
  | "contains_birth_date"
  | "too_common"
  | "no_variety";

export interface PolicyContext {
  member_no: string;
  /** YYYY-MM-DD, or null when unknown. */
  date_of_birth: string | null;
}

const COMMON = [
  "password",
  "passw0rd",
  "qwerty",
  "letmein",
  "welcome",
  "iloveyou",
  "pickleball",
  "capitolpickleball",
  "capitol",
  "admin",
  "123456",
  "111111",
  "000000",
  "abcdef",
  "asdfgh",
  "zxcvbn",
];

/** Digits of the date in the ways people write them: MMDDYYYY, DDMMYYYY, YYYYMMDD, MMDDYY, DDMMYY. */
function dateForms(iso: string | null): string[] {
  const m = iso ? /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso) : null;
  if (!m) return [];
  const [, y, mo, d] = m;
  return [
    `${mo}${d}${y}`,
    `${d}${mo}${y}`,
    `${y}${mo}${d}`,
    `${mo}${d}${y.slice(2)}`,
    `${d}${mo}${y.slice(2)}`,
  ];
}

/** The password the import gave this member: last 5 digits of the ID followed by MMDDYYYY. */
export function firstPassword(ctx: PolicyContext): string | null {
  const m = ctx.date_of_birth
    ? /^(\d{4})-(\d{2})-(\d{2})$/.exec(ctx.date_of_birth)
    : null;
  if (!m) return null;
  return `${ctx.member_no.replace(/\D/g, "").slice(-5)}${m[2]}${m[3]}${m[1]}`;
}

/** Returns the problems with a proposed password; an empty list means it is acceptable. */
export function checkPasswordPolicy(
  password: string,
  ctx: PolicyContext,
): Problem[] {
  const problems: Problem[] = [];
  if (password.length < MIN_PASSWORD_LENGTH) problems.push("too_short");
  if (password.length > MAX_PASSWORD_LENGTH) problems.push("too_long");
  const lower = password.toLowerCase();
  const digitsOnly = password.replace(/\D/g, "");

  if (firstPassword(ctx) !== null && lower === firstPassword(ctx)) {
    problems.push("first_password");
  }

  const idDigits = ctx.member_no.replace(/\D/g, ""); // CPC-2026-00001 -> 202600001
  const idForms = [
    ctx.member_no.toLowerCase(),
    ctx.member_no.toLowerCase().replaceAll("-", ""),
    idDigits,
    idDigits.slice(-5),
  ];
  if (idForms.some((f) => f.length >= 5 && lower.includes(f))) {
    problems.push("contains_member_id");
  }

  if (
    dateForms(ctx.date_of_birth).some((f) =>
      digitsOnly.includes(f) || lower.includes(f)
    )
  ) {
    problems.push("contains_birth_date");
  }

  const squashed = lower.replace(/[^a-z0-9]/g, "");
  if (COMMON.some((c) => squashed.includes(c))) problems.push("too_common");

  // Not just one repeated character, or a run like 123456789012.
  const distinct = new Set(password).size;
  const run =
    /^(?:0123456789|1234567890|abcdefghij|qwertyuiop)/i.test(squashed) &&
    distinct <= 10;
  if (distinct < 5 || run) problems.push("no_variety");

  return problems;
}

export const PROBLEM_MESSAGES: Record<Problem, string> = {
  too_short: `Use at least ${MIN_PASSWORD_LENGTH} characters.`,
  too_long: `Use at most ${MAX_PASSWORD_LENGTH} characters.`,
  first_password: "Choose a new password, not the one you were given.",
  contains_member_id: "Do not use your member ID in your password.",
  contains_birth_date: "Do not use your birth date in your password.",
  too_common: "That is a very common password. Try a few unrelated words.",
  no_variety: "Use a mix of characters, not a repeated or sequential pattern.",
};
