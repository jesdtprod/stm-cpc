// staff-create: an administrator adds a staff account for someone who is not a member (a court scanner, referee, front desk,
// manager). The administrator types the first password and hands it to the person; the account must change it at the
// first sign-in. The password is checked against the password policy, never returned and never logged.
//
// The database decides who may do this: the caller's own session is used for the permission check (roles.manage) and to
// reserve the staff ID. Only the Auth Admin call and the final record insert use the service key.
import {
  checkPasswordPolicy,
  PROBLEM_MESSAGES,
} from "../_shared/password-policy.ts";

const MAX_BODY_BYTES = 2048;
export const STAFF_ROLES = ["scanner", "referee", "front_desk", "manager"];

export type Prepared =
  | { ok: true; memberNo: string; actor: string }
  | { ok: false; status: number; message: string };

export type AuthResult =
  | { ok: true; id: string }
  | { ok: false; reason: "exists" | "failed" };

export interface Deps {
  allowedOrigins: string[];
  token: (req: Request) => string | null;
  /** Asks the database, as the caller, whether staff may be added, and reserves the staff ID. */
  prepare: (token: string, role: string, name: string) => Promise<Prepared>;
  createAuthUser: (email: string, password: string) => Promise<AuthResult>;
  deleteAuthUser: (id: string) => Promise<void>;
  /** Writes the club records and gives the role (service role). */
  createRecords: (
    memberNo: string,
    name: string,
    role: string,
    authUserId: string,
    actor: string,
  ) => Promise<void>;
  log: (event: string, fields?: Record<string, string | number>) => void;
}

export const staffEmail = (memberNo: string) =>
  `${memberNo.toLowerCase()}@members.cpc.app`;

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

  let body: Record<string, unknown>;
  try {
    const text = await req.text();
    if (text.length > MAX_BODY_BYTES) {
      return reply(413, { ok: false, code: "bad_request" }, origin, deps);
    }
    body = JSON.parse(text) as Record<string, unknown>;
  } catch {
    return reply(400, { ok: false, code: "bad_request" }, origin, deps);
  }
  const role = body?.role_code;
  const name = body?.display_name;
  const password = body?.password;
  if (
    typeof role !== "string" || !STAFF_ROLES.includes(role) ||
    typeof name !== "string" || name.trim().length < 2 || name.length > 120 ||
    typeof password !== "string"
  ) {
    return reply(400, { ok: false, code: "bad_request" }, origin, deps);
  }

  let prepared: Prepared;
  try {
    prepared = await deps.prepare(token, role, name.trim());
  } catch {
    deps.log("staff.create_failed");
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

  const problems = checkPasswordPolicy(password, {
    member_no: prepared.memberNo,
    date_of_birth: null,
  });
  if (problems.length) {
    return reply(
      422,
      {
        ok: false,
        code: "weak_password",
        problems,
        message: PROBLEM_MESSAGES[problems[0]],
      },
      origin,
      deps,
    );
  }

  const created: AuthResult = await deps.createAuthUser(
    staffEmail(prepared.memberNo),
    password,
  ).catch((): AuthResult => ({ ok: false, reason: "failed" }));
  if (!created.ok) {
    deps.log("staff.create_failed");
    return reply(
      created.reason === "exists" ? 409 : 503,
      {
        ok: false,
        code: created.reason === "exists" ? "already_exists" : "unavailable",
      },
      origin,
      deps,
    );
  }
  try {
    await deps.createRecords(
      prepared.memberNo,
      name.trim(),
      role,
      created.id,
      prepared.actor,
    );
  } catch {
    await deps.deleteAuthUser(created.id).catch(() => {});
    deps.log("staff.create_failed");
    return reply(503, { ok: false, code: "unavailable" }, origin, deps);
  }
  deps.log("staff.created");
  return reply(200, { ok: true, member_no: prepared.memberNo }, origin, deps);
}
