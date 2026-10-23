// Wires the member-import handler to the real Supabase clients (URL and keys are injected by the project).
// Two ways in: a signed-in user who holds members.import, or the temporary bootstrap token in the secret
// IMPORT_BOOTSTRAP_TOKEN (header x-import-token), used for the first import and removed afterwards.
// Edge Functions import by URL; the version is pinned.
// deno-lint-ignore no-import-prefix
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.118.0";
import { type Deps, handle } from "./handler.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const options = { auth: { persistSession: false, autoRefreshToken: false } };
const service = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, options);

async function rpc<T>(name: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await service.rpc(name, args);
  if (error) throw new Error(`${name}: ${error.code ?? "error"}`);
  return data as T;
}

const sha = async (text: string) =>
  new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));

/** Compares two secrets without leaking where they differ. */
async function sameSecret(a: string, b: string): Promise<boolean> {
  const [x, y] = await Promise.all([sha(a), sha(b)]);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

const UPPER = "ABCDEFGHJKMNPQRSTUVWXYZ";
const LOWER = "abcdefghjkmnpqrstuvwxyz";
const DIGITS = "23456789";
const ALL = UPPER + LOWER + DIGITS;
/** 24 characters, always with an upper-case letter, a lower-case letter and a digit. */
function randomPassword(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(24));
  const chars = [...bytes].map((b) => ALL[b % ALL.length]);
  const pick = (set: string) => set[crypto.getRandomValues(new Uint8Array(1))[0] % set.length];
  chars[0] = pick(UPPER);
  chars[1] = pick(LOWER);
  chars[2] = pick(DIGITS);
  // Shuffle so the guaranteed characters are not always first.
  for (let i = chars.length - 1; i > 0; i--) {
    const j = crypto.getRandomValues(new Uint8Array(1))[0] % (i + 1);
    [chars[i], chars[j]] = [chars[j], chars[i]];
  }
  return chars.join("");
}

const deps: Deps = {
  authorize: async (req) => {
    const bootstrap = Deno.env.get("IMPORT_BOOTSTRAP_TOKEN");
    const presented = req.headers.get("x-import-token");
    if (bootstrap && bootstrap.length >= 32 && presented && await sameSecret(presented, bootstrap)) {
      return "token";
    }
    const bearer = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
    if (bearer) {
      const { data } = await service.auth.getUser(bearer);
      if (data.user && await rpc<boolean>("import_authorized", { p_auth_user_id: data.user.id })) return "admin";
    }
    return null;
  },
  now: () => Date.now(),
  passwordDays: 30,
  existing: async (memberNos) => {
    const rows = await rpc<string[]>("import_existing", { p_member_nos: memberNos });
    return new Set(rows ?? []);
  },
  createAuthUser: async (email, password) => {
    const { data, error } = await service.auth.admin.createUser({ email, password, email_confirm: true });
    if (error || !data.user) {
      return { ok: false, reason: error?.code === "email_exists" ? "exists" : "failed" };
    }
    return { ok: true, id: data.user.id };
  },
  deleteAuthUser: async (id) => {
    await service.auth.admin.deleteUser(id);
  },
  importMember: async ({ batchId, row, authUserId, passwordExpiresAt }) =>
    await rpc("import_member", {
      p_batch_id: batchId,
      p_source_row: row.source_row,
      p_member_no: row.member_no,
      p_display_name: row.display_name,
      p_dob: row.dob,
      p_mobile: row.mobile,
      p_email: row.email,
      p_rfid: row.rfid,
      p_auth_user_id: authUserId,
      p_password_expires_at: passwordExpiresAt,
    }),
  begin: (sha256, rowCount) => rpc<string>("import_begin", { p_file_sha256: sha256, p_row_count: rowCount }),
  finish: async (batchId, c) => {
    await rpc("import_finish", {
      p_batch_id: batchId,
      p_created: c.created,
      p_skipped: c.skipped,
      p_held_back: c.held_back,
      p_failed: c.failed,
    });
  },
  issue: async (batchId, row, memberNo, code) => {
    await rpc("import_issue", { p_batch_id: batchId, p_source_row: row, p_member_no: memberNo, p_code: code });
  },
  createAdmin: (memberNo, displayName, authUserId) =>
    rpc<string>("create_admin_member", { p_member_no: memberNo, p_display_name: displayName, p_auth_user_id: authUserId }),
  randomPassword,
  // Events carry no names, IDs, dates or passwords.
  log: (event, fields) => console.log(JSON.stringify({ event, ...fields })),
};

Deno.serve((req) => handle(req, deps));
