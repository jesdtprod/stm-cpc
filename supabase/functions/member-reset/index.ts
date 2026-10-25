// Wires the member-reset handler to the real Supabase clients (URL and keys are injected by the project).
// Edge Functions import by URL; the version is pinned.
// deno-lint-ignore no-import-prefix
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.118.0";
import { type Deps, handle, type Prepared } from "./handler.ts";

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

/** A client that acts as the caller, so the database sees auth.uid() and checks their permission. */
function asCaller(token: string) {
  return createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    ...options,
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
}

function refusal(error: { code?: string; message?: string }) {
  const code = error.code ?? "";
  const status = code === "42501" ? 403 : code === "22023" ? 422 : 503;
  // Only the database's own sentences (errors it raised on purpose) are passed on.
  const message = status === 503
    ? "The password could not be reset. Please try again."
    : (error.message ?? "That is not allowed.");
  return { ok: false as const, status, message };
}

const deps: Deps = {
  allowedOrigins:
    Deno.env.get("ALLOWED_ORIGINS")?.split(",").map((s) => s.trim()).filter(
      Boolean,
    ) ?? DEFAULT_ORIGINS,
  token: (req) =>
    req.headers.get("authorization")?.replace(/^Bearer\s+/i, "") || null,
  prepare: async (token, memberId): Promise<Prepared> => {
    const { data, error } = await asCaller(token).rpc(
      "admin_prepare_member_reset",
      { p_member_id: memberId },
    );
    if (error) {
      if (error.code === "PGRST301" || /jwt/i.test(error.message ?? "")) {
        return { ok: false, status: 401, message: "Please sign in again." };
      }
      return refusal(error);
    }
    const d = data as {
      auth_user_id: string;
      member_no: string;
      date_of_birth: string;
    };
    return {
      ok: true,
      authUserId: d.auth_user_id,
      memberNo: d.member_no,
      dob: d.date_of_birth,
    };
  },
  finish: async (token, memberId) => {
    const { error } = await asCaller(token).rpc("admin_finish_member_reset", {
      p_member_id: memberId,
    });
    return error ? refusal(error) : { ok: true };
  },
  setPassword: async (authUserId, password) => {
    const { error } = await service.auth.admin.updateUserById(authUserId, {
      password,
    });
    return !error;
  },
  // Events carry no names, IDs, dates or passwords.
  log: (event, fields) => console.log(JSON.stringify({ event, ...fields })),
};

Deno.serve((req) => handle(req, deps));
