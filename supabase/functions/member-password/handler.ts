// member-password: changes a signed-in member's password (PLAN 3.4; docs/SECURITY.md section 2).
// Used for the forced change after the first sign-in and for later voluntary changes. The browser sends the
// new password with its session token; this function checks the policy, asks the Auth Admin API to set it,
// clears the forced-change flag, signs out the member's other sessions, and audits the change.
//
// Rules: the caller must hold a valid, recent session (a token older than FRESH_SECONDS means sign in again),
// the password must be 12-128 characters and must not be built from the member's own details (the first
// password rule, their ID, their birth date) or be a very common choice, attempts are throttled, and
// responses never echo the password.
import {
  checkPasswordPolicy,
  MAX_PASSWORD_LENGTH,
  MIN_PASSWORD_LENGTH,
  type PolicyContext,
} from "../_shared/password-policy.ts";

export const FRESH_SECONDS = 15 * 60;
const MAX_BODY_BYTES = 2048;
const LIMIT = { max: 10, windowSeconds: 900, lockSeconds: 900 };

export interface Caller {
  userId: string;
  /** When the access token was issued (seconds since the epoch). */
  issuedAt: number;
}
export interface Deps {
  allowedOrigins: string[];
  now: () => number;
  sha256: (text: string) => Promise<string>;
  /** Verifies the bearer token with Auth; null when it is missing, invalid or expired. */
  caller: (req: Request) => Promise<Caller | null>;
  context: (
    userId: string,
  ) => Promise<(PolicyContext & { member_id: string; status: string }) | null>;
  isLocked: (keys: string[]) => Promise<boolean>;
  recordFailure: (
    key: string,
    max: number,
    windowSeconds: number,
    lockSeconds: number,
  ) => Promise<boolean>;
  setPassword: (userId: string, password: string) => Promise<boolean>;
  passwordChanged: (memberId: string) => Promise<void>;
  signOutOthers: (req: Request) => Promise<void>;
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

  const caller = await deps.caller(req);
  if (!caller) {
    return reply(401, { ok: false, code: "unauthorized" }, origin, deps);
  }

  let password: unknown;
  try {
    const text = await req.text();
    if (text.length > MAX_BODY_BYTES) {
      return reply(413, { ok: false, code: "bad_request" }, origin, deps);
    }
    password = (JSON.parse(text) as Record<string, unknown>)?.new_password;
  } catch {
    return reply(400, { ok: false, code: "bad_request" }, origin, deps);
  }
  if (
    typeof password !== "string" || password.length === 0 ||
    password.length > MAX_PASSWORD_LENGTH + 64
  ) {
    return reply(400, { ok: false, code: "bad_request" }, origin, deps);
  }

  const key = `id:${await deps.sha256(`v1|pw|${caller.userId}`)}`;
  if (await deps.isLocked([key])) {
    return reply(
      429,
      {
        ok: false,
        code: "too_many_attempts",
        message: "Too many attempts. Please try again in a few minutes.",
      },
      origin,
      deps,
    );
  }
  if (deps.now() / 1000 - caller.issuedAt > FRESH_SECONDS) {
    return reply(
      401,
      {
        ok: false,
        code: "sign_in_again",
        message:
          "For your security, please sign in again, then change your password.",
      },
      origin,
      deps,
    );
  }

  const ctx = await deps.context(caller.userId);
  if (
    !ctx ||
    !["invited", "pending_approval", "active", "imported"].includes(ctx.status)
  ) {
    return reply(403, { ok: false, code: "forbidden" }, origin, deps);
  }

  const problems = checkPasswordPolicy(password, ctx);
  if (problems.length) {
    await deps.recordFailure(
      key,
      LIMIT.max,
      LIMIT.windowSeconds,
      LIMIT.lockSeconds,
    );
    return reply(
      400,
      {
        ok: false,
        code: "weak_password",
        problems,
        min_length: MIN_PASSWORD_LENGTH,
      },
      origin,
      deps,
    );
  }

  if (!(await deps.setPassword(caller.userId, password))) {
    deps.log("password.auth_failed");
    return reply(
      503,
      {
        ok: false,
        code: "unavailable",
        message:
          "The password could not be changed right now. Please try again shortly.",
      },
      origin,
      deps,
    );
  }
  await deps.passwordChanged(ctx.member_id);
  await deps.signOutOthers(req).catch(() => {});
  deps.log("password.changed");
  return reply(200, { ok: true }, origin, deps);
}
