// Wires the member-password handler to the real Supabase clients (URL and keys are injected by the project).
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
const service = createClient(
  url,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  options,
);

async function rpc<T>(name: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await service.rpc(name, args);
  if (error) throw new Error(`${name}: ${error.code ?? "error"}`);
  return data as T;
}

/** The access token's issue time. The signature was already verified by Auth (getUser) before this is trusted. */
function issuedAt(jwt: string): number {
  try {
    const payload = JSON.parse(
      atob(jwt.split(".")[1].replaceAll("-", "+").replaceAll("_", "/")),
    );
    return typeof payload.iat === "number" ? payload.iat : 0;
  } catch {
    return 0;
  }
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
  caller: async (req) => {
    const jwt = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
    if (!jwt) return null;
    const { data, error } = await service.auth.getUser(jwt);
    if (error || !data.user) return null;
    return { userId: data.user.id, issuedAt: issuedAt(jwt) };
  },
  context: async (userId) => {
    const rows = await rpc<
      {
        member_id: string;
        member_no: string;
        status: string;
        date_of_birth: string | null;
      }[]
    >(
      "member_password_context",
      { p_auth_user_id: userId },
    );
    return rows?.[0] ?? null;
  },
  isLocked: (keys) => rpc<boolean>("login_is_locked", { p_keys: keys }),
  recordFailure: (key, max, windowSeconds, lockSeconds) =>
    rpc<boolean>("login_record_failure", {
      p_key: key,
      p_max: max,
      p_window_seconds: windowSeconds,
      p_lock_seconds: lockSeconds,
    }),
  setPassword: async (userId, password) => {
    const { error } = await service.auth.admin.updateUserById(userId, {
      password,
    });
    return !error;
  },
  passwordChanged: async (memberId) => {
    await rpc("member_password_changed", { p_member_id: memberId });
  },
  signOutOthers: async (req) => {
    const jwt = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
    if (jwt) await service.auth.admin.signOut(jwt, "others");
  },
  // Events carry no member ID, no password and no address.
  log: (event, fields) => console.log(JSON.stringify({ event, ...fields })),
};

Deno.serve((req) => handle(req, deps));
