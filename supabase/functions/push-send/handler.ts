// push-send: delivers one notification to the member's registered devices with Web Push, so it arrives even when the
// browser is in the background or closed. The database calls it right after a notification is stored (pg_net), with a
// shared secret in the x-dispatch-secret header. Nothing else may call it. The payload is only a title, a short text and
// an in-app address; device keys stay on the server.
const MAX_BODY_BYTES = 512;
const ID_RE = /^[0-9A-HJKMNP-TV-Z]{26}$/;

export interface Sub {
  id: string;
  endpoint: string;
  p256dh: string;
  auth: string;
}
export interface Target {
  title: string;
  body: string | null;
  url: string | null;
  tag: string | null;
  subs: Sub[];
}
export interface Deps {
  /** The shared secret the database sends. Empty means the function is not set up. */
  secret: string;
  load: (notificationId: string) => Promise<Target | null>;
  send: (sub: Sub, payload: string) => Promise<"ok" | "gone" | "error">;
  mark: (okIds: string[], goneIds: string[]) => Promise<void>;
  log: (event: string, fields?: Record<string, string | number>) => void;
}

/** Compares without stopping at the first difference. */
export function sameSecret(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  }
  return diff === 0;
}

const reply = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });

export async function handle(req: Request, deps: Deps): Promise<Response> {
  if (req.method !== "POST") {
    return reply(405, { ok: false, code: "method_not_allowed" });
  }
  if (!deps.secret) {
    deps.log("push.not_configured");
    return reply(503, { ok: false, code: "not_configured" });
  }
  if (!sameSecret(req.headers.get("x-dispatch-secret") ?? "", deps.secret)) {
    return reply(401, { ok: false, code: "unauthorized" });
  }
  let id: unknown;
  try {
    const text = await req.text();
    if (text.length > MAX_BODY_BYTES) {
      return reply(413, { ok: false, code: "bad_request" });
    }
    id = (JSON.parse(text) as Record<string, unknown>)?.notification_id;
  } catch {
    return reply(400, { ok: false, code: "bad_request" });
  }
  if (typeof id !== "string" || !ID_RE.test(id)) {
    return reply(400, { ok: false, code: "bad_request" });
  }
  const target = await deps.load(id);
  if (!target) return reply(404, { ok: false, code: "not_found" });
  if (!target.subs.length) {
    return reply(200, { ok: true, sent: 0, gone: 0, failed: 0 });
  }

  const payload = JSON.stringify({
    title: target.title,
    body: target.body ?? "",
    url: target.url ?? "#/",
    tag: target.tag ?? "cpc",
  });
  const results = await Promise.all(
    target.subs.map(async (s) => ({
      id: s.id,
      r: await deps.send(s, payload).catch(() => "error" as const),
    })),
  );
  const ok = results.filter((x) => x.r === "ok").map((x) => x.id);
  const gone = results.filter((x) => x.r === "gone").map((x) => x.id);
  const failed = results.length - ok.length - gone.length;
  await deps.mark(ok, gone).catch(() => {});
  deps.log("push.sent", { sent: ok.length, gone: gone.length, failed });
  return reply(200, { ok: true, sent: ok.length, gone: gone.length, failed });
}
