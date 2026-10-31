// Wires the staff-create handler to the real Supabase clients (URL and keys are injected by the project).
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

const deps: Deps = {
  allowedOrigins:
    Deno.env.get("ALLOWED_ORIGINS")?.split(",").map((s) => s.trim()).filter(
      Boolean,
    ) ?? DEFAULT_ORIGINS,
  token: (req) =>
    req.headers.get("authorization")?.replace(/^Bearer\s+/i, "") || null,
  prepare: async (token, role, name): Promise<Prepared> => {
    const { data, error } = await asCaller(token).rpc("staff_account_prepare", {
      p_role_code: role,
      p_display_name: name,
    });
    if (error) {
      if (error.code === "PGRST301" || /jwt/i.test(error.message ?? "")) {
        return { ok: false, status: 401, message: "Please sign in again." };
      }
      const code = error.code ?? "";
      const status = code === "42501" ? 403 : code === "22023" ? 422 : 503;
      // Only the database's own sentences (errors it raised on purpose) are passed on.
      return {
        ok: false,
        status,
        message: status === 503
          ? "The staff account could not be added. Please try again."
          : (error.message ?? "That is not allowed."),
      };
    }
    const d = data as { member_no: string; actor: string };
    return { ok: true, memberNo: d.member_no, actor: d.actor };
  },
  createAuthUser: async (email, password) => {
    const { data, error } = await service.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
    });
    if (error || !data.user) {
      return {
        ok: false,
        reason: error?.code === "email_exists" ? "exists" : "failed",
      };
    }
    return { ok: true, id: data.user.id };
  },
  deleteAuthUser: async (id) => {
    await service.auth.admin.deleteUser(id);
  },
  createRecords: async (memberNo, name, role, authUserId, actor) => {
    const { error } = await service.rpc("create_staff_member", {
      p_member_no: memberNo,
      p_display_name: name,
      p_role_code: role,
      p_auth_user_id: authUserId,
      p_actor: actor,
    });
    if (error) throw new Error("create_staff_member failed");
  },
  // Events carry no names, IDs or passwords.
  log: (event, fields) => console.log(JSON.stringify({ event, ...fields })),
};

Deno.serve((req) => handle(req, deps));
