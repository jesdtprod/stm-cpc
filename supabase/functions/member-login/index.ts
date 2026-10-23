// Wires the member-login handler to the real Supabase clients. The project injects SUPABASE_URL,
// SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY into every Edge Function; nothing is configured here.
// Only the page origins allowed to call this function are set in code (override with ALLOWED_ORIGINS).
// Edge Functions import by URL; the version is pinned.
// deno-lint-ignore no-import-prefix
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.118.0";
import { type Deps, handle, type MemberState } from "./handler.ts";

const DEFAULT_ORIGINS = [
  "https://jesdtprod.github.io",
  "http://localhost:8099",
  "http://127.0.0.1:8099",
];

const url = Deno.env.get("SUPABASE_URL")!;
const options = { auth: { persistSession: false, autoRefreshToken: false } };
const anon = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, options);
const service = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, options);

async function rpc<T>(name: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await service.rpc(name, args);
  if (error) throw new Error(`${name}: ${error.code ?? "error"}`);
  return data as T;
}

const deps: Deps = {
  allowedOrigins: (Deno.env.get("ALLOWED_ORIGINS")?.split(",").map((s) => s.trim()).filter(Boolean)) ??
    DEFAULT_ORIGINS,
  now: () => Date.now(),
  sha256: async (text) => {
    const bytes = new TextEncoder().encode(text);
    const digest = await crypto.subtle.digest("SHA-256", bytes);
    return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
  },
  isLocked: (keys) => rpc<boolean>("login_is_locked", { p_keys: keys }),
  recordFailure: (key, max, windowSeconds, lockSeconds) =>
    rpc<boolean>("login_record_failure", {
      p_key: key,
      p_max: max,
      p_window_seconds: windowSeconds,
      p_lock_seconds: lockSeconds,
    }),
  clearFailures: async (key) => {
    await rpc("login_clear", { p_key: key });
  },
  signIn: async (email, password, captchaToken) => {
    const { data, error } = await anon.auth.signInWithPassword({
      email,
      password,
      options: { captchaToken },
    });
    if (!error && data.session && data.user) {
      return { ok: true, session: data.session, userId: data.user.id };
    }
    const code = error?.code ?? "";
    if (code.startsWith("captcha")) return { ok: false, reason: "captcha" };
    if (code === "invalid_credentials" || error?.status === 400) {
      return { ok: false, reason: "invalid" };
    }
    return { ok: false, reason: "unavailable" };
  },
  revoke: async (accessToken) => {
    await service.auth.admin.signOut(accessToken, "global").catch(() => {});
  },
  memberState: async (userId) => {
    const rows = await rpc<MemberState[]>("member_login_state", { p_auth_user_id: userId });
    return rows?.[0] ?? null;
  },
  loginSucceeded: async (memberId) => {
    await rpc("member_login_succeeded", { p_member_id: memberId });
  },
  // Events carry no member ID, no address and no password.
  log: (event, fields) => console.log(JSON.stringify({ event, ...fields })),
};

Deno.serve((req) => handle(req, deps));
