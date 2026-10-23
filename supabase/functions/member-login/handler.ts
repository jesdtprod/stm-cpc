// member-login: member ID + password sign-in (PLAN 3.1; docs/SECURITY.md section 2).
// The handler holds all the rules and receives everything it touches through `Deps`, so the rules are
// unit-tested without a network. index.ts wires the real Supabase clients.
//
// Rules:
//  * One generic answer ("invalid_credentials") for an unknown ID, a wrong password, a malformed ID and a
//    locked ID or address. The Auth call is made for every attempt, so the paths cost about the same.
//  * Cloudflare Turnstile is verified by Supabase Auth itself: the token is passed through, and a missing
//    or bad token is refused by Auth (reported as captcha_failed, which says nothing about any member).
//  * Lockout: 5 failures per member ID or 30 per address inside 15 minutes lock that key for 15 minutes.
//    The counters hold SHA-256 hashes, never the ID or the address.
//  * Only after the credentials are proven correct may the answer say more (account disabled, first
//    password expired). No session is returned in those cases, and the Auth session is revoked.

export const GENERIC_MESSAGE =
  "Sign-in failed. Check your member ID and password, or try again later.";
export const ID_PATTERN = /^CPC-\d{4}-\d{5}$/;
export const EMAIL_DOMAIN = "members.cpc.app";
export const LIMITS = {
  idMaxFailures: 5,
  ipMaxFailures: 30,
  windowSeconds: 900,
  lockSeconds: 900,
};
const ALLOWED_STATUSES = new Set([
  "imported",
  "invited",
  "pending_approval",
  "active",
]);
const MAX_BODY_BYTES = 4096;

export interface Session {
  access_token: string;
  refresh_token: string;
  expires_in?: number;
}
export type SignInResult =
  | { ok: true; session: Session; userId: string }
  | { ok: false; reason: "invalid" | "captcha" | "unavailable" };
export interface MemberState {
  member_id: string;
  member_no: string;
  status: string;
  must_change_password: boolean;
  temp_password_expires_at: string | null;
}
export interface Deps {
  allowedOrigins: string[];
  now: () => number;
  sha256: (text: string) => Promise<string>;
  isLocked: (keys: string[]) => Promise<boolean>;
  recordFailure: (
    key: string,
    max: number,
    windowSeconds: number,
    lockSeconds: number,
  ) => Promise<boolean>;
  clearFailures: (key: string) => Promise<void>;
  signIn: (
    email: string,
    password: string,
    captchaToken: string,
  ) => Promise<SignInResult>;
  revoke: (accessToken: string) => Promise<void>;
  memberState: (userId: string) => Promise<MemberState | null>;
  loginSucceeded: (memberId: string) => Promise<void>;
  log: (event: string, fields?: Record<string, string | number>) => void;
}

/** "  cpc-2026-00001 " -> "CPC-2026-00001". */
export function normalizeMemberId(raw: string): string {
  return raw.trim().toUpperCase();
}

/** The internal Auth address for a member ID. Never shown or mailed. */
export function internalEmail(memberNo: string): string {
  return `${memberNo.toLowerCase()}@${EMAIL_DOMAIN}`;
}

function corsHeaders(
  origin: string | null,
  deps: Deps,
): Record<string, string> {
  const headers: Record<string, string> = {
    "Vary": "Origin",
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
  };
  if (origin && deps.allowedOrigins.includes(origin)) {
    headers["Access-Control-Allow-Origin"] = origin;
    headers["Access-Control-Allow-Methods"] = "POST, OPTIONS";
    headers["Access-Control-Allow-Headers"] =
      "authorization, apikey, content-type, x-client-info, x-request-id";
    headers["Access-Control-Max-Age"] = "600";
  }
  return headers;
}

function json(
  status: number,
  body: Record<string, unknown>,
  origin: string | null,
  deps: Deps,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders(origin, deps),
      "Content-Type": "application/json",
    },
  });
}

const generic = (origin: string | null, deps: Deps) =>
  json(
    401,
    { ok: false, code: "invalid_credentials", message: GENERIC_MESSAGE },
    origin,
    deps,
  );

function clientAddress(req: Request): string {
  const forwarded = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
  return req.headers.get("cf-connecting-ip") ?? forwarded ??
    req.headers.get("x-real-ip") ?? "unknown";
}

interface Input {
  memberId: string;
  password: string;
  captchaToken: string;
}

function parseInput(value: unknown): Input | null {
  if (typeof value !== "object" || value === null) return null;
  const v = value as Record<string, unknown>;
  const id = v.member_id;
  const pw = v.password;
  const token = v.captcha_token;
  if (typeof id !== "string" || id.trim().length < 3 || id.length > 40) {
    return null;
  }
  if (typeof pw !== "string" || pw.length < 1 || pw.length > 128) return null;
  if (typeof token !== "string" || token.length < 1 || token.length > 4096) {
    return null;
  }
  return { memberId: id, password: pw, captchaToken: token };
}

export async function handle(req: Request, deps: Deps): Promise<Response> {
  const origin = req.headers.get("origin");
  if (origin && !deps.allowedOrigins.includes(origin)) {
    return new Response(null, {
      status: 403,
      headers: { "Cache-Control": "no-store" },
    });
  }
  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: corsHeaders(origin, deps),
    });
  }
  if (req.method !== "POST") {
    return json(405, { ok: false, code: "method_not_allowed" }, origin, deps);
  }

  let input: Input | null = null;
  try {
    const text = await req.text();
    if (text.length > MAX_BODY_BYTES) {
      return json(413, { ok: false, code: "bad_request" }, origin, deps);
    }
    input = parseInput(JSON.parse(text));
  } catch {
    input = null;
  }
  if (!input) {
    return json(400, { ok: false, code: "bad_request" }, origin, deps);
  }

  const memberNo = normalizeMemberId(input.memberId);
  const wellFormed = ID_PATTERN.test(memberNo);
  const idKey = `id:${await deps.sha256(`v1|${memberNo}`)}`;
  const ipKey = `ip:${await deps.sha256(`v1|${clientAddress(req)}`)}`;

  if (await deps.isLocked([idKey, ipKey])) {
    deps.log("login.locked_out");
    return generic(origin, deps);
  }

  // A malformed ID still goes through Auth (with an address no member has), so the cost is the same.
  const email = wellFormed
    ? internalEmail(memberNo)
    : `invalid-${(await deps.sha256(memberNo)).slice(0, 24)}@${EMAIL_DOMAIN}`;
  const result = await deps.signIn(email, input.password, input.captchaToken);

  if (!result.ok) {
    if (result.reason === "captcha") {
      await deps.recordFailure(
        ipKey,
        LIMITS.ipMaxFailures,
        LIMITS.windowSeconds,
        LIMITS.lockSeconds,
      );
      return json(
        400,
        {
          ok: false,
          code: "captcha_failed",
          message: "Please complete the security check and try again.",
        },
        origin,
        deps,
      );
    }
    if (result.reason === "unavailable") {
      deps.log("login.auth_unavailable");
      return json(
        503,
        {
          ok: false,
          code: "unavailable",
          message:
            "Sign-in is unavailable right now. Please try again shortly.",
        },
        origin,
        deps,
      );
    }
    const idLocked = await deps.recordFailure(
      idKey,
      LIMITS.idMaxFailures,
      LIMITS.windowSeconds,
      LIMITS.lockSeconds,
    );
    const ipLocked = await deps.recordFailure(
      ipKey,
      LIMITS.ipMaxFailures,
      LIMITS.windowSeconds,
      LIMITS.lockSeconds,
    );
    if (idLocked || ipLocked) deps.log("login.lock_applied");
    return generic(origin, deps);
  }

  // The credentials are correct from here on.
  const state = await deps.memberState(result.userId);
  if (!state || state.member_no !== memberNo) {
    await deps.revoke(result.session.access_token);
    return generic(origin, deps);
  }
  if (!ALLOWED_STATUSES.has(state.status)) {
    await deps.revoke(result.session.access_token);
    return json(
      403,
      {
        ok: false,
        code: "account_disabled",
        message: "This account cannot sign in. Please contact the club.",
      },
      origin,
      deps,
    );
  }
  if (
    state.must_change_password && state.temp_password_expires_at &&
    Date.parse(state.temp_password_expires_at) < deps.now()
  ) {
    await deps.revoke(result.session.access_token);
    return json(
      403,
      {
        ok: false,
        code: "password_expired",
        message:
          "Your first password has expired. Please ask the club to reset it.",
      },
      origin,
      deps,
    );
  }

  await deps.clearFailures(idKey);
  await deps.loginSucceeded(state.member_id);
  return json(
    200,
    {
      ok: true,
      session: {
        access_token: result.session.access_token,
        refresh_token: result.session.refresh_token,
      },
      must_change_password: state.must_change_password,
    },
    origin,
    deps,
  );
}
