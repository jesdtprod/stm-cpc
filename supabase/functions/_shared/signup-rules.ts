// Validation for the public new-member sign-up (PLAN 3.3; docs/FEATURES.md section 4.4). Pure and unit-tested.
// Every field is checked here, on the server, whatever the form already checked in the browser.
import { normalizeEmail, validIsoDate } from "./member-import-rules.ts";

export const SUFFIXES = ["Jr.", "Sr.", "II", "III", "IV", "V"];
const NAME_PART = /^[\p{L}][\p{L}\p{M} .'\-]{0,59}$/u;
/** Keys that would mean the caller is trying to claim an existing member: refused outright. */
const ID_KEYS = ["member_id", "member_no", "id_no", "memberid", "id"];

export interface SignupData {
  first_name: string;
  middle_name: string | null;
  last_name: string;
  suffix: string | null;
  display_name: string;
  gender: string | null;
  date_of_birth: string;
  mobile: string;
  email: string | null;
  password: string;
  captcha_token: string;
}

export type SignupResult =
  | { ok: true; data: SignupData }
  | { ok: false; code: "existing_member_claim" }
  | { ok: false; code: "invalid"; errors: Record<string, string> };

const clean = (
  v: unknown,
): string => (typeof v === "string" ? v.trim().replace(/\s+/g, " ") : "");

/** 09XXXXXXXXX from the ways people write a Philippine mobile number; null when it cannot be read. */
export function signupMobile(raw: string): string | null {
  const digits = raw.replace(/\D/g, "");
  if (/^09\d{9}$/.test(digits)) return digits;
  if (/^9\d{9}$/.test(digits)) return `0${digits}`;
  if (/^639\d{9}$/.test(digits)) return `0${digits.slice(2)}`;
  return null;
}

export function validateSignup(
  body: Record<string, unknown>,
  today = new Date(),
): SignupResult {
  if (ID_KEYS.some((k) => k in body)) {
    return { ok: false, code: "existing_member_claim" };
  }
  const errors: Record<string, string> = {};

  const first = clean(body.first_name);
  const last = clean(body.last_name);
  const middle = clean(body.middle_name);
  if (!first) errors.first_name = "required";
  else if (!NAME_PART.test(first)) errors.first_name = "invalid";
  if (!last) errors.last_name = "required";
  else if (!NAME_PART.test(last)) errors.last_name = "invalid";
  if (middle && !NAME_PART.test(middle)) errors.middle_name = "invalid";

  const suffix = clean(body.suffix);
  if (suffix && !SUFFIXES.includes(suffix)) errors.suffix = "invalid";
  const gender = clean(body.gender).toLowerCase();
  if (gender && gender !== "male" && gender !== "female") {
    errors.gender = "invalid";
  }

  const dobRaw = clean(body.date_of_birth);
  const dob = dobRaw ? validIsoDate(dobRaw, today) : null;
  if (!dobRaw) errors.date_of_birth = "required";
  else if (!dob) errors.date_of_birth = "invalid";

  const mobileRaw = clean(body.mobile);
  const mobile = mobileRaw ? signupMobile(mobileRaw) : null;
  if (!mobileRaw) errors.mobile = "required";
  else if (!mobile) errors.mobile = "invalid";

  const emailRaw = clean(body.email);
  const email = emailRaw ? normalizeEmail(emailRaw) : null;
  if (!emailRaw) errors.email = "required";
  else if (!email) errors.email = "invalid";

  const password = typeof body.password === "string" ? body.password : "";
  if (!password) errors.password = "required";
  else if (password.length > 200) errors.password = "too_long";

  if (body.consent_waiver !== true) errors.consent_waiver = "not_accepted";
  if (body.consent_privacy !== true) errors.consent_privacy = "not_accepted";

  const token = typeof body.captcha_token === "string"
    ? body.captcha_token
    : "";
  if (!token || token.length > 4096) errors.captcha_token = "required";

  if (Object.keys(errors).length) return { ok: false, code: "invalid", errors };
  return {
    ok: true,
    data: {
      first_name: first,
      middle_name: middle || null,
      last_name: last,
      suffix: suffix || null,
      display_name: `${first} ${last}`,
      gender: gender || null,
      date_of_birth: dob!,
      mobile: mobile!,
      email,
      password,
      captcha_token: token,
    },
  };
}
