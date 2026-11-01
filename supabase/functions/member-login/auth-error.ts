/** Normalize Auth credential failures without turning outages into password errors. */
export function loginFailureReason(
  error:
    | { code?: string; status?: number; message?: string }
    | null
    | undefined,
): "captcha" | "invalid" | "unavailable" {
  const code = error?.code?.toLowerCase() ?? "";
  if (code.startsWith("captcha")) return "captcha";
  if (
    ["invalid_credentials", "invalid_login_credentials", "invalid_grant"]
      .includes(code)
  ) return "invalid";
  if (error?.status === 400 || error?.status === 401) return "invalid";
  if (
    error?.status === 422 &&
    /invalid (login credentials|credentials|username|password)|incorrect (username|password)/i
      .test(error.message ?? "")
  ) return "invalid";
  return "unavailable";
}
