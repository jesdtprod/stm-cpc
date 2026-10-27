// Messages for the password page. The server decides what is acceptable (supabase/functions/_shared/
// password-policy.ts); this file only turns its problem codes into words, and checks the two things the
// browser can know without the member's details: length and that the two entries match.
export const MIN_PASSWORD_LENGTH = 12;
export const MAX_PASSWORD_LENGTH = 128;

export const PROBLEM_MESSAGES = {
  too_short: `Use at least ${MIN_PASSWORD_LENGTH} characters.`,
  too_long: `Use at most ${MAX_PASSWORD_LENGTH} characters.`,
  first_password: "Choose a new password, not the one you were given.",
  contains_member_id: "Do not use your member ID in your password.",
  contains_birth_date: "Do not use your birth date in your password.",
  too_common: "That is a very common password. Try a few unrelated words.",
  no_variety: "Use a mix of characters, not a repeated or sequential pattern.",
};

/** Returns a list of messages (empty when the browser-side checks pass). */
export function localPasswordProblems(password, confirm) {
  const out = [];
  if (password.length < MIN_PASSWORD_LENGTH) {
    out.push(PROBLEM_MESSAGES.too_short);
  }
  if (password.length > MAX_PASSWORD_LENGTH) {
    out.push(PROBLEM_MESSAGES.too_long);
  }
  if (confirm !== undefined && password !== confirm) {
    out.push("The two passwords do not match.");
  }
  return out;
}

export const problemMessages = (codes = []) =>
  codes.map((c) => PROBLEM_MESSAGES[c] ?? "Choose a different password.");

/**
 * Evaluates real-time password strength and criteria.
 * @param {string} password
 * @returns {{ score: number, label: string, tone: string, hasLength: boolean, hasVariety: boolean }}
 */
export function evaluatePasswordStrength(password = "") {
  if (!password) {
    return {
      score: 0,
      label: "",
      tone: "",
      hasLength: false,
      hasVariety: false,
    };
  }

  const hasLength = password.length >= MIN_PASSWORD_LENGTH;
  const hasUpper = /[A-Z]/.test(password);
  const hasLower = /[a-z]/.test(password);
  const hasDigit = /[0-9]/.test(password);
  const hasSymbol = /[^A-Za-z0-9]/.test(password);

  let varietyCount = 0;
  if (hasUpper) varietyCount++;
  if (hasLower) varietyCount++;
  if (hasDigit) varietyCount++;
  if (hasSymbol) varietyCount++;

  const distinct = new Set(password).size;
  const hasVariety = (varietyCount >= 2 && distinct >= 4) || (password.length >= 16 && distinct >= 5);

  let score = 1;
  if (hasLength) {
    score = 2; // Fair (meets 12+ chars)
    if (hasVariety && (varietyCount >= 3 || password.length >= 16)) {
      score = 3; // Good
    }
    if ((hasVariety && varietyCount >= 3 && password.length >= 14) || password.length >= 18) {
      score = 4; // Strong
    }
  }

  const labels = ["", "Weak", "Fair", "Good", "Strong"];
  const tones = ["", "danger", "warning", "info", "success"];

  return {
    score,
    label: labels[score],
    tone: tones[score],
    hasLength,
    hasVariety,
  };
}
