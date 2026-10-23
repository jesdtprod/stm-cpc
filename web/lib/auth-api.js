// Calls to the member-login and member-password Edge Functions. `fetchFn` is injectable for tests.
// Nothing here stores or logs a password; errors carry a code and a message that is safe to show.
import { SUPABASE_URL } from "../supabase-config.js";

const FUNCTIONS = `${SUPABASE_URL}/functions/v1`;

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
    "Sign-in failed. Check your member ID and password, or try again later.",
  captcha_failed: "Please complete the security check and try again.",
  account_disabled: "This account cannot sign in. Please contact the club.",
  password_expired:
    "Your first password has expired. Please ask the club to reset it.",
  unavailable: "Sign-in is unavailable right now. Please try again shortly.",
  sign_in_again:
    "For your security, please sign in again, then change your password.",
  too_many_attempts: "Too many attempts. Please try again in a few minutes.",
};

async function post(path, body, headers, fetchFn) {
  let res;
  try {
    res = await fetchFn(`${FUNCTIONS}/${path}`, {
      method: "POST",
      headers: { "content-type": "application/json", ...headers },
      body: JSON.stringify(body),
    });
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
    { status: res.status, problems: json.problems ?? [] },
  );
}

/** Signs in with member ID + password. Resolves to { access_token, refresh_token, must_change_password }. */
export async function memberLogin(
  { memberId, password },
  captchaToken,
  fetchFn = fetch,
) {
  const json = await post(
    "member-login",
    {
      member_id: memberId,
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
