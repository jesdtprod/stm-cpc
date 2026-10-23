// Wires the member-signup handler to the real Supabase clients (URL and keys are injected by the project).
// Edge Functions import by URL; the version is pinned.
// deno-lint-ignore no-import-prefix
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.118.0";
import { type Deps, handle } from "./handler.ts";

const DEFAULT_ORIGINS = [
  "https://jesdtprod.github.io",
  "http://localhost:8099",
  "http://127.0.0.1:8099",
];

const url = Deno.env.get("SUPABASE_URL")!;
const options = { auth: { persistSession: false, autoRefreshToken: false } };
const anon = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, options);
const service = createClient(
  url,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  options,
);

async function rpc<T>(
  name: string,
  args: Record<string, unknown> = {},
): Promise<T> {
  const { data, error } = await service.rpc(name, args);
  if (error) throw new Error(`${name}: ${error.code ?? "error"}`);
  return data as T;
}

const deps: Deps = {
  allowedOrigins:
    Deno.env.get("ALLOWED_ORIGINS")?.split(",").map((s) => s.trim()).filter(
      Boolean,
    ) ?? DEFAULT_ORIGINS,
  now: () => Date.now(),
  sha256: async (text) => {
    const digest = await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(text),
    );
    return [...new Uint8Array(digest)].map((b) =>
      b.toString(16).padStart(2, "0")
    ).join("");
  },
  isLocked: (keys) => rpc<boolean>("login_is_locked", { p_keys: keys }),
  recordFailure: (key, max, windowSeconds, lockSeconds) =>
    rpc<boolean>("login_record_failure", {
      p_key: key,
      p_max: max,
      p_window_seconds: windowSeconds,
      p_lock_seconds: lockSeconds,
    }),
  signupEnabled: () => rpc<boolean>("signup_enabled"),
  // The Turnstile secret lives only in Supabase Auth, so Auth is asked to check the token: a sign-in with an
  // address that cannot exist fails with "invalid_credentials" when the token is good and "captcha_failed" when it is not.
  checkCaptcha: async (token) => {
    const { error } = await anon.auth.signInWithPassword({
      email: "captcha-check@members.cpc.app",
      password: crypto.randomUUID(),
      options: { captchaToken: token },
    });
    const code = error?.code ?? "";
    if (code.startsWith("captcha")) return "failed";
    if (code === "invalid_credentials" || error?.status === 400) return "ok";
    return "unavailable";
  },
  allocateMemberNo: () => rpc<string>("signup_allocate_member_no"),
  createAuthUser: async (email, password) => {
    const { data, error } = await service.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
    });
    return error || !data.user ? { ok: false } : { ok: true, id: data.user.id };
  },
  deleteAuthUser: async (id) => {
    await service.auth.admin.deleteUser(id);
  },
  createMember: async (memberNo, d, authUserId) => {
    await rpc("signup_create", {
      p_member_no: memberNo,
      p_first_name: d.first_name,
      p_middle_name: d.middle_name,
      p_last_name: d.last_name,
      p_suffix: d.suffix,
      p_display_name: d.display_name,
      p_gender: d.gender,
      p_dob: d.date_of_birth,
      p_mobile: d.mobile,
      p_email: d.email,
      p_auth_user_id: authUserId,
    });
  },
  // Events carry no names, IDs, dates, numbers or passwords.
  log: (event, fields) => console.log(JSON.stringify({ event, ...fields })),
};

Deno.serve((req) => handle(req, deps));
