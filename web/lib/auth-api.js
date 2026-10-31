// Calls to the member-login and member-password Edge Functions. `fetchFn` is injectable for tests.
// Nothing here stores or logs a password; errors carry a code and a message that is safe to show.
import { SUPABASE_ANON_KEY, SUPABASE_URL } from "../supabase-config.js";

const FUNCTIONS = `${SUPABASE_URL}/functions/v1`;
// Run the functions in the same region as the database (this project: Sydney). Otherwise every database call inside
// a function crosses regions, which made sign-in take 2 to 3 seconds instead of under one.
const FUNCTION_REGION = "ap-southeast-2";

export class AuthFlowError extends Error {
  constructor(code, message, extra = {}) {
    super(message);
    this.name = "AuthFlowError";
    this.code = code;
    Object.assign(this, extra);
  }
}

const MESSAGES = {
  invalid_credentials:
    "Incorrect member ID, email, or password. Please try again.",
  captcha_failed: "Please complete the security check and try again.",
  account_disabled: "This account cannot sign in. Please contact the club.",
  password_expired:
    "Your first password has expired. Please ask the club to reset it.",
  unavailable: "Sign-in is unavailable right now. Please try again shortly.",
  sign_in_again:
    "For your security, please sign in again, then change your password.",
  too_many_attempts: "Too many attempts. Please try again in a few minutes.",
  closed: "New sign-ups are closed right now. Please ask the club.",
  email_taken:
    "That email is already used by another member. Sign in with it, or use a different email.",
  mobile_taken:
    "That mobile number is already used by a member. Please sign in or contact the club.",
  imported_member:
    "A member with that name already exists in the imported records. Please sign in with your member ID or contact the club.",
  existing_member_claim:
    "Sign-up is for new members only. If you are already a member, sign in with your member ID.",
};

async function post(path, body, headers, fetchFn) {
  let res;
  try {
    res = await fetchFn(
      `${FUNCTIONS}/${path}?forceFunctionRegion=${FUNCTION_REGION}`,
      {
        method: "POST",
        // text/plain with no custom headers is a "simple" request: the browser skips the extra preflight round trip.
        // The functions read the body as text and parse the JSON themselves, and still check the Origin.
        headers: { "content-type": "text/plain;charset=UTF-8", ...headers },
        body: JSON.stringify(body),
      },
    );
  } catch {
    throw new AuthFlowError(
      "network",
      "Could not reach the server. Check your connection and try again.",
    );
  }
  const json = await res.json().catch(() => ({}));
  if (res.ok && json.ok) return json;
  const code = json.code ?? "unavailable";
  throw new AuthFlowError(
    code,
    json.message ?? MESSAGES[code] ??
      "Something went wrong. Please try again.",
    {
      status: res.status,
      problems: json.problems ?? [],
      errors: json.errors ?? {},
    },
  );
}

/** Signs in with a member ID or the email on the profile, plus the password. Resolves to { access_token, refresh_token, must_change_password }. */
export async function memberLogin(
  { memberId, password },
  captchaToken,
  fetchFn = fetch,
) {
  const json = await post(
    "member-login",
    {
      identifier: memberId,
      password,
      captcha_token: captchaToken,
    },
    {},
    fetchFn,
  );
  return { ...json.session, must_change_password: json.must_change_password };
}

/** Sets a new password for the signed-in member. Rejects with AuthFlowError (code weak_password has .problems). */
export async function changePassword(
  newPassword,
  accessToken,
  fetchFn = fetch,
) {
  await post("member-password", { new_password: newPassword }, {
    authorization: `Bearer ${accessToken}`,
  }, fetchFn);
}

/** An administrator resets a member's password to the first-password rule. Rejects with AuthFlowError (.message is plain). */
export async function adminResetPassword(
  memberId,
  accessToken,
  fetchFn = fetch,
) {
  await post("member-reset", { member_id: memberId }, {
    authorization: `Bearer ${accessToken}`,
  }, fetchFn);
}

/** An administrator adds a staff account for someone who is not a member. Resolves to { member_no }. */
export async function createStaffAccount(fields, accessToken, fetchFn = fetch) {
  const json = await post("staff-create", fields, {
    authorization: `Bearer ${accessToken}`,
  }, fetchFn);
  return { member_no: json.member_no };
}

/** Public sign-up for new members. Resolves to { member_no }. Rejects with AuthFlowError (.errors, .problems). */
export async function memberSignup(fields, captchaToken, fetchFn = fetch) {
  const json = await post(
    "member-signup",
    { ...fields, captcha_token: captchaToken },
    {},
    fetchFn,
  );
  return { member_no: json.member_no ?? null, queued: Boolean(json.queued) };
}

/** Public availability must not depend on a saved or expired member session. */
export async function membershipApplicationsOpen(fetchFn = fetch) {
  try {
    const response = await fetchFn(
      `${SUPABASE_URL}/rest/v1/rpc/membership_applications_open`,
      {
        method: "POST",
        cache: "no-store",
        headers: {
          apikey: SUPABASE_ANON_KEY,
          authorization: `Bearer ${SUPABASE_ANON_KEY}`,
          "content-type": "application/json",
        },
        body: "{}",
      },
    );
    if (!response.ok) throw new Error("unavailable");
    const open = await response.json();
    if (typeof open !== "boolean") throw new Error("invalid availability");
    return open;
  } catch {
    throw new AuthFlowError(
      "unavailable",
      "We couldn?t check membership availability. Please try again.",
    );
  }
}
