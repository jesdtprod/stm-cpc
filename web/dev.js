// Development self-check page. It is registered only when the app is served from localhost
// (see app.js), signs in with a test account's email and password, and runs the live checks for
// PLAN steps 1B.2, 1B.4, 1B.5, 1B.7 and 1B.8. It is replaced by the real sign-in page in step 3.4.
import { button, field, h, pageHeader, toast } from "./ui.js";
import { renderTurnstile } from "./lib/turnstile.js";
import { can } from "./lib/permissions.js";
import { ulid } from "./lib/ulid.js";
import { ADMIN_CODES } from "./pages-home.js";

export const isLocalDev = ["localhost", "127.0.0.1"].includes(
  location.hostname,
);

// 1x1 transparent PNG.
const PNG_BASE64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";
const pngBlob = () =>
  new Blob([Uint8Array.from(atob(PNG_BASE64), (c) => c.charCodeAt(0))], {
    type: "image/png",
  });

export function createDev({ client, api, session, reporter }) {
  /** Replaces the member-login Edge Function until step 3.1: password sign-in with a Turnstile token. */
  async function devLogin({ email, password }, captchaToken) {
    const { data, error } = await client.auth.signInWithPassword({
      email,
      password,
      options: { captchaToken },
    });
    if (error) throw error;
    return data.session;
  }

  function page() {
    const log = h("pre", { class: "dev-log", "aria-live": "polite" });
    const out = (ok, text) =>
      log.append(`${ok === null ? "•" : ok ? "PASS" : "FAIL"}  ${text}\n`);
    const me = () => session.getState().profile;
    const status = h("p", { class: "muted", role: "status" }, "Signed out.");
    const showState = (s) => {
      status.textContent = s.status === "signed_in"
        ? `Signed in. Gate: ${
          s.gate ?? "none"
        }. Permissions: ${s.grants.length}.`
        : `Signed out${s.reason ? ` (${s.reason})` : ""}.`;
    };
    showState(session.getState());
    addEventListener("cpc:session", (e) => {
      showState(e.detail);
      out(
        null,
        `session event: ${e.detail.status}${
          e.detail.reason ? ` (${e.detail.reason})` : ""
        }`,
      );
    });

    let token = null;
    const box = h("div", {});
    setTimeout(
      () =>
        renderTurnstile(box, {
          action: "dev-signin",
          onToken: (t) => (token = t),
          onExpire: () => (token = null),
        }),
      0,
    );
    const email = field({
      id: "dev-email",
      label: "Test account email",
      type: "email",
    });
    const password = field({
      id: "dev-password",
      label: "Password",
      type: "password",
    });
    const signIn = button({
      label: "Sign In",
      variant: "primary",
      onClick: async () => {
        try {
          await session.signIn({
            email: email.querySelector("input").value,
            password: password.querySelector("input").value,
          }, token);
          password.querySelector("input").value = "";
        } catch (e) {
          toast(e.message ?? "Sign-in failed");
        }
      },
    });

    const checks = {
      identity() {
        const s = session.getState();
        out(
          s.status === "signed_in",
          `signed in, profile ${s.profile?.profile_id ?? "none"}, gate ${
            s.gate ?? "none"
          }`,
        );
        out(
          null,
          `permissions (${s.grants.length}): ${
            s.grants.map((g) => g.code).join(", ") || "none"
          }`,
        );
      },
      async errors() {
        const err = new Error(`selfcheck-${Date.now()} ana@example.test`);
        const first = await reporter.report(err);
        const second = await reporter.report(err);
        out(
          first === "sent" && second === "duplicate",
          `error report: first ${first}, repeat ${second}`,
        );
        if (can("audit.read")) {
          const rows = await api.read((c) =>
            c.from("client_errors").select("id,message").like(
              "message",
              "selfcheck-%",
            ).limit(50)
          );
          const mine = rows.filter((r) => r.message.includes("[email]"));
          out(
            mine.length >= 1 && mine.every((r) => !r.message.includes("@")),
            `client_errors holds the sanitized report (${mine.length} row(s), no email)`,
          );
        } else {out(
            null,
            "read-back of client_errors needs audit.read: run this check as the admin account",
          );}
        for (
          const [label, run, kind] of [
            ["unknown function", () => api.rpc("no_such_function"), null],
            [
              "forbidden write",
              () =>
                api.read((c) =>
                  c.from("org_members").insert({
                    org_id: "x",
                    profile_id: "y",
                    role_id: "z",
                  })
                ),
              "forbidden",
            ],
          ]
        ) {
          try {
            await run();
            out(false, `${label}: expected an error`);
          } catch (e) {
            out(
              kind ? e.kind === kind : true,
              `${label} -> "${e.message}" (${e.kind})`,
            );
          }
        }
      },
      async idempotent() {
        if (!can("settings.manage")) {
          return out(null, "needs settings.manage: run as manager or admin");
        }
        const key = api.newKey();
        const row = {
          org_id: me().org_id,
          type: "selfcheck",
          code: `sc-${key.slice(-8).toLowerCase()}`,
          label: "Self-check Row",
        };
        await api.create("lookups", key, row);
        await api.create("lookups", key, row);
        const rows = await api.read((c) =>
          c.from("lookups").select("id").eq("id", key)
        );
        out(
          rows.length === 1,
          `two creates with one key produced ${rows.length} record(s)`,
        );
      },
      async storage() {
        const bucket = client.storage.from("payment-proofs");
        const org = me().org_id;
        const mine = `${org}/${me().profile_id}/selfcheck-${Date.now()}.png`;
        const mayUpload = can("payments.submit");
        const tryUpload = async (path, blob, opts) =>
          (await bucket.upload(path, blob, opts)).error;
        const ok = await tryUpload(mine, pngBlob(), {
          contentType: "image/png",
        });
        out(
          mayUpload ? !ok : !!ok,
          `own folder upload ${ok ? `refused (${ok.message})` : "accepted"}${
            mayUpload ? "" : " (this role has no payments.submit)"
          }`,
        );
        const wrongType = await tryUpload(
          `${org}/${me().profile_id}/selfcheck.txt`,
          new Blob(["hello"], { type: "text/plain" }),
          { contentType: "text/plain" },
        );
        out(
          !!wrongType,
          `wrong file type ${
            wrongType ? `refused (${wrongType.message})` : "ACCEPTED"
          }`,
        );
        const tooBig = await tryUpload(
          `${org}/${me().profile_id}/selfcheck-big.png`,
          new Blob([new Uint8Array(6 * 1024 * 1024)], { type: "image/png" }),
          { contentType: "image/png" },
        );
        out(
          !!tooBig,
          `6 MB file ${tooBig ? `refused (${tooBig.message})` : "ACCEPTED"}`,
        );
        const elsewhere = await tryUpload(
          `${org}/${ulid()}/selfcheck.png`,
          pngBlob(),
          { contentType: "image/png" },
        );
        out(
          !!elsewhere,
          `another member's folder ${
            elsewhere ? `refused (${elsewhere.message})` : "ACCEPTED"
          }`,
        );
        if (mayUpload && !ok) {
          const dl = await bucket.download(mine);
          out(
            !dl.error,
            `owner can read the file back${
              dl.error ? ` (${dl.error.message})` : ""
            }`,
          );
        }
        out(
          null,
          "to prove another member cannot read it, run this check as one member and then sign in as another",
        );
        const listing = await bucket.list(`${org}/${me().profile_id}`);
        out(null, `files visible in own folder: ${listing.data?.length ?? 0}`);
      },
    };

    const run = (name) => async () => {
      if (session.getState().status !== "signed_in") {
        return out(false, "sign in first");
      }
      out(null, `--- ${name}`);
      try {
        await checks[name]();
      } catch (e) {
        out(false, `${name} threw: ${e.message}`);
      }
    };

    return h(
      "div",
      { class: "page" },
      pageHeader({
        icon: "info",
        eyebrow: "Development Only",
        title: "Self-check",
        description:
          "Sign in with a test account, then run the checks. Shown only on localhost.",
      }),
      h(
        "div",
        { class: "card" },
        h("h2", {}, "Sign In"),
        email,
        password,
        box,
        h(
          "div",
          { class: "actions" },
          signIn,
          button({
            label: "Sign Out",
            onClick: () => session.signOut("manual"),
          }),
          button({
            label: "Simulate Member Session",
            onClick: () => {
              session.mockSession({
                grants: [
                  "bookings.create",
                  "events.register",
                  "payments.submit",
                ].map((code) => ({
                  code,
                  org_id: "org-1",
                  unit_id: null,
                })),
                profile: { profile_id: "dev-member-1", org_id: "org-1" },
                access: {
                  display_name: "Kyle Marquez",
                  member_no: "CPC-2026-00001",
                  status: "active",
                  must_change_password: false,
                  profile_complete: true,
                },
              });
              location.hash = "#/";
            },
          }),
          button({
            label: "Simulate Admin Session",
            variant: "accent",
            onClick: () => {
              session.mockSession({
                grants: ADMIN_CODES.map((code) => ({
                  code,
                  org_id: "org-1",
                  unit_id: null,
                })),
                profile: { profile_id: "dev-admin-1", org_id: "org-1" },
                access: {
                  display_name: "Admin User",
                  member_no: "CPC-2026-00001",
                  must_change_password: false,
                  profile_complete: true,
                },
              });
              location.hash = "#/admin";
            },
          }),
        ),
        status,
      ),
      h(
        "div",
        { class: "card" },
        h("h2", {}, "Checks"),
        h(
          "p",
          { class: "muted" },
          "Idle sign-out: open this page as http://localhost:8099/?idle=20#/dev to use a 20-second timeout. Cross-tab: open a second tab, then sign out in one.",
        ),
        h(
          "div",
          { class: "actions" },
          ...Object.keys(checks).map((n) =>
            button({ label: n, onClick: run(n) })
          ),
        ),
        log,
      ),
    );
  }

  return { devLogin, page };
}
