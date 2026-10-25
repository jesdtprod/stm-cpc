// member-reset: an administrator resets a member's password to the first-password rule (the last 5 digits of the member ID
// followed by the birth date as MMDDYYYY). The member must then change it and confirm their profile and email at the next sign-in.
//
// The database decides who may do this and for whom (permission members.reset_password; never an administrator account,
// never the caller's own account, never a member with no sign-in or birth date): the caller's own session is used for those
// checks. Only the Auth Admin call needs the service key. The new password is never returned or logged.
import { initialPassword } from "../_shared/member-import-rules.ts";

const MAX_BODY_BYTES = 1024;
const ID_RE = /^[0-9A-HJKMNP-TV-Z]{26}$/;

export type Prepared =
  | { ok: true; authUserId: string; memberNo: string; dob: string }
  | { ok: false; status: number; message: string };

export interface Deps {
  allowedOrigins: string[];
  /** The caller's bearer token, or null. Verified by the database calls below (auth.uid()). */
  token: (req: Request) => string | null;
  /** Asks the database, as the caller, whether and for whom a reset may go ahead. */
  prepare: (token: string, memberId: string) => Promise<Prepared>;
  /** Marks the member as needing a new password and profile confirmation, and audits it (as the caller). */
  finish: (
    token: string,
    memberId: string,
  ) => Promise<{ ok: true } | { ok: false; status: number; message: string }>;
  setPassword: (authUserId: string, password: string) => Promise<boolean>;
  log: (event: string, fields?: Record<string, string | number>) => void;
}

function cors(origin: string | null, deps: Deps): Record<string, string> {
  const h: Record<string, string> = {
    "Vary": "Origin",
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
  };
  if (origin && deps.allowedOrigins.includes(origin)) {
    h["Access-Control-Allow-Origin"] = origin;
    h["Access-Control-Allow-Methods"] = "POST, OPTIONS";
    h["Access-Control-Allow-Headers"] =
      "authorization, apikey, content-type, x-client-info, x-request-id";
    h["Access-Control-Max-Age"] = "600";
  }
  return h;
}
const reply = (
  status: number,
  body: Record<string, unknown>,
  origin: string | null,
  deps: Deps,
) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors(origin, deps), "Content-Type": "application/json" },
  });

export async function handle(req: Request, deps: Deps): Promise<Response> {
  const origin = req.headers.get("origin");
  if (origin && !deps.allowedOrigins.includes(origin)) {
    return new Response(null, { status: 403 });
  }
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: cors(origin, deps) });
  }
  if (req.method !== "POST") {
    return reply(405, { ok: false, code: "method_not_allowed" }, origin, deps);
  }
  const token = deps.token(req);
  if (!token) {
    return reply(401, { ok: false, code: "unauthorized" }, origin, deps);
  }

  let memberId: unknown;
  try {
    const text = await req.text();
    if (text.length > MAX_BODY_BYTES) {
      return reply(413, { ok: false, code: "bad_request" }, origin, deps);
    }
    memberId = (JSON.parse(text) as Record<string, unknown>)?.member_id;
  } catch {
    return reply(400, { ok: false, code: "bad_request" }, origin, deps);
  }
  if (typeof memberId !== "string" || !ID_RE.test(memberId)) {
    return reply(400, { ok: false, code: "bad_request" }, origin, deps);
  }

  let prepared: Prepared;
  try {
    prepared = await deps.prepare(token, memberId);
  } catch {
    deps.log("member.reset_failed");
    return reply(503, { ok: false, code: "unavailable" }, origin, deps);
  }
  if (!prepared.ok) {
    return reply(
      prepared.status,
      {
        ok: false,
        code: prepared.status === 401
          ? "unauthorized"
          : prepared.status === 403
          ? "forbidden"
          : "not_allowed",
        message: prepared.message,
      },
      origin,
      deps,
    );
  }

  // The flag and the audit entry first: if the password step then fails, the member is only asked to change their password.
  let finished;
  try {
    finished = await deps.finish(token, memberId);
  } catch {
    deps.log("member.reset_failed");
    return reply(503, { ok: false, code: "unavailable" }, origin, deps);
  }
  if (!finished.ok) {
    return reply(
      finished.status,
      {
        ok: false,
        code: finished.status === 403 ? "forbidden" : "not_allowed",
        message: finished.message,
      },
      origin,
      deps,
    );
  }
  let set = false;
  try {
    set = await deps.setPassword(
      prepared.authUserId,
      initialPassword(prepared.memberNo, prepared.dob),
    );
  } catch {
    set = false;
  }
  if (!set) {
    deps.log("member.reset_failed");
    return reply(
      503,
      {
        ok: false,
        code: "unavailable",
        message: "The password could not be reset. Please try again.",
      },
      origin,
      deps,
    );
  }
  deps.log("member.reset");
  return reply(200, { ok: true }, origin, deps);
}
