import assert from "node:assert/strict";
import { loginFailureReason } from "../../supabase/functions/member-login/auth-error.ts";
Deno.test("login errors: invalid credentials variants stay separate from service failures", () => {
  for (
    const code of [
      "invalid_credentials",
      "invalid_login_credentials",
      "invalid_grant",
    ]
  ) assert.equal(loginFailureReason({ code, status: 422 }), "invalid");
  assert.equal(
    loginFailureReason({ status: 422, message: "Invalid login credentials" }),
    "invalid",
  );
  assert.equal(loginFailureReason({ status: 401 }), "invalid");
  assert.equal(
    loginFailureReason({ code: "captcha_failed", status: 400 }),
    "captcha",
  );
  assert.equal(
    loginFailureReason({ status: 503, message: "Service unavailable" }),
    "unavailable",
  );
  assert.equal(
    loginFailureReason({ status: 422, message: "Unexpected validation error" }),
    "unavailable",
  );
  assert.equal(loginFailureReason(null), "unavailable");
});
