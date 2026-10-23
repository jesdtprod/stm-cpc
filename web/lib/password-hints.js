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
