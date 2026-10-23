// member-signup: public sign-up for NEW members only (PLAN 3.3; docs/FEATURES.md 4.4, docs/SECURITY.md section 2).
// An applicant gives their details and chooses a password; the function assigns the next member ID, creates the
// account and the member (status pending_approval, no permissions), records the waiver and privacy consents, and
// flags possible duplicates and minors for the admin. It never accepts a member ID from the caller: a request
// that names one is refused, so nobody can claim an existing member.
//
// Protections: allowed origins only; Cloudflare Turnstile verified through Supabase Auth; a hidden honeypot field;
// an attempt limit per address; strict input validation and a password policy; generic failure messages.
import { checkPasswordPolicy } from "../_shared/password-policy.ts";
import { type SignupData, validateSignup } from "../_shared/signup-rules.ts";

const MAX_BODY_BYTES = 8192;
export const LIMIT = { max: 10, windowSeconds: 3600, lockSeconds: 3600 };

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
  signupEnabled: () => Promise<boolean>;
  /** Verifies the Turnstile token with Auth. */
  checkCaptcha: (token: string) => Promise<"ok" | "failed" | "unavailable">;
  allocateMemberNo: () => Promise<string>;
  createAuthUser: (
    email: string,
    password: string,
  ) => Promise<{ ok: true; id: string } | { ok: false }>;
  deleteAuthUser: (id: string) => Promise<void>;
  createMember: (
    memberNo: string,
    data: SignupData,
    authUserId: string,
  ) => Promise<void>;
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

function clientAddress(req: Request): string {
  const forwarded = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
  return req.headers.get("cf-connecting-ip") ?? forwarded ??
    req.headers.get("x-real-ip") ?? "unknown";
}

export async function handle(req: Request, deps: Deps): Promise<Response> {
  const origin = req.headers.get("origin");
  // Sign-up is called from the app's own pages only.
  if (!origin || !deps.allowedOrigins.includes(origin)) {
    return new Response(null, {
      status: 403,
      headers: { "Cache-Control": "no-store" },
    });
  }
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: cors(origin, deps) });
  }
  if (req.method !== "POST") {
    return reply(405, { ok: false, code: "method_not_allowed" }, origin, deps);
  }

  let body: Record<string, unknown>;
  try {
    const text = await req.text();
    if (text.length > MAX_BODY_BYTES) {
      return reply(413, { ok: false, code: "bad_request" }, origin, deps);
    }
    const parsed = JSON.parse(text);
    if (
      typeof parsed !== "object" || parsed === null || Array.isArray(parsed)
    ) throw new Error("shape");
    body = parsed as Record<string, unknown>;
  } catch {
    return reply(400, { ok: false, code: "bad_request" }, origin, deps);
  }

  // Honeypot: a person never sees this field. Answer as if it worked, and do nothing.
  if (typeof body.website === "string" && body.website.trim() !== "") {
    deps.log("signup.honeypot");
    return reply(200, { ok: true, queued: true }, origin, deps);
  }

  const checked = validateSignup(body, new Date(deps.now()));
  if (!checked.ok) {
    if (checked.code === "existing_member_claim") {
      return reply(
        400,
        {
          ok: false,
          code: "existing_member_claim",
          message:
            "Sign-up is for new members only. If you are already a member, sign in with your member ID.",
        },
        origin,
        deps,
      );
    }
    return reply(
      400,
      { ok: false, code: "invalid", errors: checked.errors },
      origin,
      deps,
    );
  }
  const data = checked.data;

  const ipKey = `ip:${await deps.sha256(`v1|signup|${clientAddress(req)}`)}`;
  if (await deps.isLocked([ipKey])) {
    return reply(
      429,
      {
        ok: false,
        code: "too_many_attempts",
        message: "Too many attempts. Please try again later.",
      },
      origin,
      deps,
    );
  }
  await deps.recordFailure(
    ipKey,
    LIMIT.max,
    LIMIT.windowSeconds,
    LIMIT.lockSeconds,
  ); // counts every attempt

  if (!(await deps.signupEnabled())) {
    return reply(
      403,
      {
        ok: false,
        code: "closed",
        message: "New sign-ups are closed right now. Please ask the club.",
      },
      origin,
      deps,
    );
  }

  const problems = checkPasswordPolicy(data.password, {
    member_no: "CPC-0000-00000",
    date_of_birth: data.date_of_birth,
  });
  if (problems.length) {
    return reply(
      400,
      { ok: false, code: "weak_password", problems },
      origin,
      deps,
    );
  }

  const captcha = await deps.checkCaptcha(data.captcha_token);
  if (captcha === "failed") {
    return reply(
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
  if (captcha === "unavailable") {
    return reply(
      503,
      {
        ok: false,
        code: "unavailable",
        message: "Sign-up is unavailable right now. Please try again shortly.",
      },
      origin,
      deps,
    );
  }

  let memberNo: string;
  let userId: string | null = null;
  try {
    memberNo = await deps.allocateMemberNo();
    const created = await deps.createAuthUser(
      `${memberNo.toLowerCase()}@members.cpc.app`,
      data.password,
    );
    if (!created.ok) throw new Error("auth");
    userId = created.id;
    await deps.createMember(memberNo, data, userId);
  } catch {
    if (userId) await deps.deleteAuthUser(userId).catch(() => {});
    deps.log("signup.failed");
    return reply(
      503,
      {
        ok: false,
        code: "unavailable",
        message: "Sign-up could not be completed. Please try again shortly.",
      },
      origin,
      deps,
    );
  }
  deps.log("signup.created");
  // The new ID is shown once on the page: the applicant needs it to sign in.
  return reply(200, { ok: true, member_no: memberNo }, origin, deps);
}
