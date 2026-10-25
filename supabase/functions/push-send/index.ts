// Wires the push-send handler to Supabase and the Web Push protocol (keys and URL are injected as secrets, never in the repo).
// Edge Functions import by URL; versions are pinned.
// deno-lint-ignore no-import-prefix
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.118.0";
// deno-lint-ignore no-import-prefix
import webpush from "npm:web-push@3.6.7";
import { type Deps, handle, type Sub, type Target } from "./handler.ts";

const service = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const vapidPublic = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
const vapidPrivate = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
const vapidSubject = Deno.env.get("VAPID_SUBJECT") ??
  "https://jesdtprod.github.io/stm-cpc/";
if (vapidPublic && vapidPrivate) {
  webpush.setVapidDetails(vapidSubject, vapidPublic, vapidPrivate);
}

const deps: Deps = {
  secret: vapidPublic && vapidPrivate
    ? (Deno.env.get("PUSH_DISPATCH_SECRET") ?? "")
    : "",
  load: async (id) => {
    const { data, error } = await service.rpc("push_targets", {
      p_notification_id: id,
    });
    if (error || !data) return null;
    return data as Target;
  },
  send: async (sub: Sub, payload: string) => {
    try {
      await webpush.sendNotification(
        {
          endpoint: sub.endpoint,
          keys: { p256dh: sub.p256dh, auth: sub.auth },
        },
        payload,
        { TTL: 86400, urgency: "high" },
      );
      return "ok";
    } catch (e) {
      const status = (e as { statusCode?: number })?.statusCode;
      return status === 404 || status === 410 ? "gone" : "error";
    }
  },
  mark: async (okIds, goneIds) => {
    await service.rpc("push_mark", { p_ok_ids: okIds, p_gone_ids: goneIds });
  },
  // Events carry counts only: no names, addresses, keys or message text.
  log: (event, fields) => console.log(JSON.stringify({ event, ...fields })),
};

Deno.serve((req) => handle(req, deps));
