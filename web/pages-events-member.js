// Member events page (PLAN 6.2): events open for registration, joining a division, and following your registrations.
//   * The page only shows what the server allows. my_event_options says, per division, whether this member may join and
//     why not; register_for_event checks every rule again and its messages are shown as they are.
//   * The registration ID is made once per division and reused if Register is pressed again.
//   * Payment proof goes to the private bucket under the member's own folder, then submit_event_payment records it.
//     Nothing is paid until an admin verifies it; the registration is confirmed by approval and/or the verified fee,
//     as the club's settings require.
import {
  badge,
  button,
  dataTable,
  h,
  openModal,
  pageHeader,
  tabs,
  toast,
} from "./ui.js";
import { formatDate } from "./lib/dates.js";
import { formatMoney } from "./lib/money.js";
import { ulid } from "./lib/ulid.js";

const MAX_PROOF_BYTES = 5 * 1024 * 1024;
const PROOF_TYPES = [
  "image/jpeg",
  "image/png",
  "image/webp",
  "application/pdf",
];
const METHOD_LABEL = {
  cash: "Cash",
  gcash: "GCash",
  maya: "Maya",
  bank_transfer: "Bank transfer",
};
const REG_STATUS = {
  requested: ["Waiting for approval", "warning"],
  confirmed: ["Confirmed", "success"],
  waitlisted: ["Waitlisted", "info"],
  withdrawn: ["Withdrawn", "neutral"],
  rejected: ["Rejected", "danger"],
};
const GENDER_LABEL = { male: "Men", female: "Women", mixed: "Mixed" };

const when = (d) => formatDate(`${d}T00:00:00+08:00`);

function eventMessage(e, fallback = "That did not work. Please try again.") {
  if (e?.code === "23505" || e?.kind === "duplicate") {
    return e.cause?.message ??
      "You or your partner are already registered in this division.";
  }
  const own = ["22023", "42501", "CP422", "CP409"].includes(e?.code) &&
    e.cause?.message;
  return own || e?.message || fallback;
}

export function createMemberEventsPages({ api, client, session }) {
  const profile = () => session.getState().profile ?? {};

  async function loadSettings(keys) {
    const rows = await api.read((c) =>
      c.from("settings").select("key,value").in("key", keys).is("unit_id", null)
        .is("deleted_at", null)
    );
    return Object.fromEntries((rows ?? []).map((r) => [r.key, r.value]));
  }

  function eventsPage() {
    const page = h("div", { class: "page" });
    const tabsHost = h("div", {});
    const body = h("div", { class: "events-body" });
    const state = {
      tab: "open",
      status: "loading",
      options: [],
      mine: [],
      pays: {},
      settings: {},
    };
    // One registration ID per division, so pressing Register again is not a second registration.
    const regIds = new Map();
    const regIdFor = (key) => {
      if (!regIds.has(key)) regIds.set(key, api.newKey());
      return regIds.get(key);
    };

    async function refresh() {
      state.status = state.options.length || state.mine.length
        ? "refreshing"
        : "loading";
      draw();
      try {
        const [options, mine, settings] = await Promise.all([
          api.rpc("my_event_options"),
          api.read((c) =>
            c.from("registrations").select(
              "id,status,status_reason,fee_snapshot,meta,division:divisions(id,name,status),event:events(name,starts_on)",
            ).order("created_at", { ascending: false }).limit(100)
          ),
          loadSettings([
            "payments.methods",
            "payments.required.event_registration",
            "payments.proof_required_non_cash",
            "payments.instructions",
          ]),
        ]);
        state.options = options ?? [];
        state.mine = mine ?? [];
        state.settings = settings;
        const ids = state.mine.map((r) => r.id);
        const totals = ids.length
          ? await api.read((c) =>
            c.from("source_payment_totals").select(
              "source_id,verified_total,pending_total",
            ).eq("source_type", "event_registration").in("source_id", ids)
          )
          : [];
        state.pays = Object.fromEntries(
          (totals ?? []).map((t) => [t.source_id, t]),
        );
        state.status = "ready";
      } catch {
        state.status = "error";
      }
      draw();
    }

    const remaining = (r) =>
      Math.max(
        0,
        Number(r.fee_snapshot) -
          Number(state.pays[r.id]?.verified_total ?? 0) -
          Number(state.pays[r.id]?.pending_total ?? 0),
      );

    // ------------------------------------------------------------- register
    function registerModal(ev, d) {
      const doubles = d.format === "doubles";
      const error = h("p", {
        class: "field-error form-error",
        role: "alert",
        hidden: true,
      });
      const fail = (m) => {
        error.textContent = m;
        error.hidden = false;
        return false;
      };
      let partner = null; // { member_id, display_name, member_no }
      const chosen = h("p", { class: "muted" }, "No partner chosen yet.");
      const results = h("div", { class: "staff-results" });
      const term = h("input", {
        class: "input",
        id: "rg-term",
        type: "search",
        placeholder: "Partner's name or member ID",
        maxlength: 60,
      });
      async function search() {
        const text = term.value.trim();
        if (text.length < 2) return;
        try {
          const rows = await api.rpc("find_players", { p_term: text });
          results.replaceChildren(
            ...(rows ?? []).map((r) =>
              h(
                "button",
                {
                  type: "button",
                  class: "staff-result",
                  onClick: () => {
                    partner = r;
                    chosen.textContent =
                      `Partner: ${r.display_name} (${r.member_no})`;
                    results.replaceChildren();
                  },
                },
                h(
                  "span",
                  {},
                  r.display_name,
                  h("span", { class: "sub" }, r.member_no),
                ),
              )
            ),
          );
          if (!rows?.length) chosen.textContent = "Nobody active matches.";
        } catch (e) {
          chosen.textContent = eventMessage(e, "The search did not work.");
        }
      }
      term.addEventListener("keydown", (e) => {
        if (e.key === "Enter") {
          e.preventDefault();
          search();
        }
      });
      const full = d.max_entries && d.taken >= d.max_entries;
      return openModal({
        title: "Register",
        eyebrow: `${ev.name} · ${d.name}`,
        icon: "trophy",
        confirmLabel: full ? "Join the waitlist" : "Register",
        body: h(
          "div",
          { class: "stack" },
          h(
            "p",
            {},
            Number(ev.fee) > 0
              ? `Fee: ${formatMoney(ev.fee)}${
                doubles ? " for the pair, paid by you" : ""
              }.`
              : "There is no fee.",
          ),
          full
            ? h(
              "p",
              { class: "muted" },
              "This division is full. You will be put on the waitlist.",
            )
            : null,
          doubles
            ? h(
              "div",
              { class: "stack" },
              h("label", { for: "rg-term" }, "Doubles partner *"),
              h(
                "div",
                { class: "actions" },
                term,
                button({ label: "Search", onClick: search }),
              ),
              results,
              chosen,
              h(
                "p",
                { class: "muted" },
                "Your partner must also be allowed to join this division.",
              ),
            )
            : null,
          error,
        ),
        onConfirm: async () => {
          if (doubles && !partner) return fail("Choose your doubles partner.");
          try {
            const r = await api.rpc("register_for_event", {
              p_id: regIdFor(`${d.id}:${partner?.member_id ?? ""}`),
              p_division_id: d.id,
              p_partner_member_id: partner?.member_id ?? null,
            });
            toast(
              r.status === "waitlisted"
                ? "You are on the waitlist."
                : r.status === "confirmed"
                ? "You are registered."
                : "Registration sent. It is confirmed once the club approves it.",
              { tone: "success" },
            );
            await refresh();
          } catch (e) {
            return fail(eventMessage(e));
          }
        },
      });
    }

    // ------------------------------------------------------------ withdraw
    function withdrawModal(r) {
      const error = h("p", {
        class: "field-error form-error",
        role: "alert",
        hidden: true,
      });
      return openModal({
        title: "Withdraw your registration",
        eyebrow: `${r.event?.name ?? ""} · ${r.division?.name ?? ""}`,
        icon: "alert",
        confirmLabel: "Withdraw",
        destructive: true,
        body: h(
          "div",
          { class: "stack" },
          h(
            "p",
            {},
            r.status === "confirmed" && Number(r.fee_snapshot) > 0
              ? "Your fee charge is reversed. If you already paid, the club will return it."
              : "Your place goes to the next person waiting, if there is one.",
          ),
          h(
            "div",
            { class: "field" },
            h("label", { for: "wd-reason" }, "Reason (optional)"),
            h("textarea", {
              class: "input textarea",
              id: "wd-reason",
              name: "reason",
              rows: 2,
              maxlength: 500,
            }),
          ),
          error,
        ),
        onConfirm: async (form) => {
          try {
            await api.rpc("withdraw_registration", {
              p_registration_id: r.id,
              p_reason: String(form.get("reason") ?? "").trim() || null,
            });
            toast("You have withdrawn.", { tone: "success" });
            await refresh();
          } catch (e) {
            error.textContent = eventMessage(e);
            error.hidden = false;
            return false;
          }
        },
      });
    }

    // ----------------------------------------------------------------- pay
    function payModal(r) {
      const methods = state.settings["payments.methods"] ?? ["cash"];
      const proofRequired =
        state.settings["payments.proof_required_non_cash"] !== false;
      const paymentId = api.newKey();
      const instructions = String(state.settings["payments.instructions"] ?? "")
        .trim();
      const error = h("p", {
        class: "field-error form-error",
        role: "alert",
        hidden: true,
      });
      const proof = h("input", {
        class: "input",
        id: "pay-proof",
        name: "proof",
        type: "file",
        accept: PROOF_TYPES.join(","),
      });
      let uploaded = null;
      return openModal({
        title: "Pay the registration fee",
        eyebrow: `${r.event?.name ?? ""} · ${r.division?.name ?? ""}`,
        icon: "currency",
        confirmLabel: "Send payment",
        body: h(
          "div",
          { class: "stack" },
          instructions ? h("p", { class: "card" }, instructions) : null,
          h(
            "p",
            { class: "muted" },
            `Still to pay: ${formatMoney(remaining(r))}`,
          ),
          h(
            "div",
            { class: "field" },
            h("label", { for: "pay-method" }, "Method *"),
            h(
              "select",
              { class: "input select-input", id: "pay-method", name: "method" },
              ...methods.map((m) =>
                h("option", { value: m }, METHOD_LABEL[m] ?? m)
              ),
            ),
          ),
          h(
            "div",
            { class: "field" },
            h("label", { for: "pay-ref" }, "Reference number"),
            h("input", {
              class: "input",
              id: "pay-ref",
              name: "reference",
              maxlength: 64,
            }),
          ),
          h(
            "div",
            { class: "field" },
            h("label", { for: "pay-amount" }, "Amount (PHP) *"),
            h("input", {
              class: "input",
              id: "pay-amount",
              name: "amount",
              type: "number",
              min: "0.01",
              step: "0.01",
              required: true,
              value: remaining(r).toFixed(2),
            }),
          ),
          h(
            "div",
            { class: "field" },
            h(
              "label",
              { for: "pay-proof" },
              proofRequired
                ? "Proof of payment (cash needs none)"
                : "Proof of payment (optional)",
            ),
            proof,
            h("span", { class: "field-hint" }, "A photo or PDF, up to 5 MB."),
          ),
          error,
        ),
        onConfirm: async (form) => {
          const fail = (m) => {
            error.textContent = m;
            error.hidden = false;
            return false;
          };
          const method = String(form.get("method"));
          const amount = Number(form.get("amount"));
          if (!(amount > 0) || Math.round(amount * 100) !== amount * 100) {
            return fail(
              "Enter an amount above zero with at most two decimals.",
            );
          }
          const file = proof.files?.[0] ?? null;
          if (
            file &&
            (!PROOF_TYPES.includes(file.type) || file.size > MAX_PROOF_BYTES)
          ) {
            return fail(
              "The proof must be a JPG, PNG, WebP or PDF file up to 5 MB.",
            );
          }
          if (!file && method !== "cash" && proofRequired) {
            return fail("Attach the proof of payment.");
          }
          try {
            let path = null;
            if (file) {
              if (!uploaded || uploaded.file !== file) {
                const ext = {
                  "image/jpeg": "jpg",
                  "image/png": "png",
                  "image/webp": "webp",
                  "application/pdf": "pdf",
                }[file.type];
                const candidate =
                  `${profile().org_id}/${profile().profile_id}/${ulid()}.${ext}`;
                const { error: upErr } = await client.storage.from(
                  "payment-proofs",
                ).upload(candidate, file, {
                  contentType: file.type,
                  upsert: false,
                });
                if (upErr) {
                  return fail(
                    "The proof could not be uploaded. Check the file and try again.",
                  );
                }
                uploaded = { file, path: candidate };
              }
              path = uploaded.path;
            }
            await api.rpc("submit_event_payment", {
              p_id: paymentId,
              p_registration_id: r.id,
              p_method: method,
              p_reference_no: String(form.get("reference") ?? "").trim() ||
                null,
              p_amount: amount,
              p_proof_path: path,
            });
            toast("Payment sent. An admin will check it.", { tone: "success" });
            await refresh();
          } catch (e) {
            return fail(eventMessage(e));
          }
        },
      });
    }

    // --------------------------------------------------------------- views
    function divisionsTable(ev) {
      return dataTable({
        schema: {
          columns: [
            {
              key: "name",
              label: "Division",
              render: (d) =>
                h(
                  "span",
                  {},
                  d.name,
                  h(
                    "span",
                    { class: "sub" },
                    [
                      d.format === "doubles" ? "Doubles" : "Singles",
                      GENDER_LABEL[d.gender],
                      d.age_group,
                      d.category,
                    ].filter(Boolean).join(" · "),
                  ),
                ),
            },
            {
              key: "spots",
              label: "Entries",
              align: "right",
              render: (d) =>
                d.max_entries
                  ? `${d.taken} of ${d.max_entries}`
                  : String(d.taken),
            },
            {
              key: "state",
              label: "Status",
              render: (d) =>
                d.mine
                  ? badge(
                    ...(REG_STATUS[d.mine.status] ??
                      [d.mine.status, "neutral"]),
                  )
                  : d.problem
                  ? h("span", { class: "muted" }, d.problem)
                  : badge("Open", "success"),
            },
            {
              key: "actions",
              label: "Action",
              align: "center",
              render: (d) =>
                !d.mine && !d.problem
                  ? button({
                    label: d.max_entries && d.taken >= d.max_entries
                      ? "Waitlist"
                      : "Register",
                    variant: "primary",
                    size: "sm",
                    onClick: () => registerModal(ev, d),
                  })
                  : null,
            },
          ],
        },
        rows: ev.divisions,
        state: "ready",
        ariaLabel: `Divisions of ${ev.name}`,
        emptyTitle: "No divisions",
        emptyText: "This event has no open divisions.",
      });
    }

    function openView() {
      if (state.status === "loading") {
        return dataTable({
          schema: { columns: [{ key: "n", label: "Event", render: () => "" }] },
          rows: [],
          state: "loading",
          ariaLabel: "Events",
        });
      }
      if (state.status === "error") {
        return dataTable({
          schema: { columns: [{ key: "n", label: "Event", render: () => "" }] },
          rows: [],
          state: "error",
          onRetry: refresh,
          ariaLabel: "Events",
        });
      }
      if (!state.options.length) {
        return dataTable({
          schema: { columns: [{ key: "n", label: "Event", render: () => "" }] },
          rows: [],
          state: "ready",
          ariaLabel: "Events",
          emptyTitle: "No events open for registration",
          emptyText:
            "When the club opens registration, the event appears here.",
        });
      }
      return h(
        "div",
        { class: "stack" },
        ...state.options.map((ev) =>
          h(
            "section",
            { class: "card stack" },
            h("h2", {}, ev.name),
            h(
              "p",
              { class: "muted" },
              [
                ev.starts_on === ev.ends_on
                  ? when(ev.starts_on)
                  : `${when(ev.starts_on)} – ${when(ev.ends_on)}`,
                ev.location,
                Number(ev.fee) > 0 ? formatMoney(ev.fee) : "Free",
              ].filter(Boolean).join(" · "),
            ),
            divisionsTable(ev),
          )
        ),
      );
    }

    function mineView() {
      return dataTable({
        schema: {
          columns: [
            {
              key: "event",
              label: "Event",
              render: (r) =>
                h(
                  "span",
                  {},
                  r.event?.name ?? "—",
                  h("span", { class: "sub" }, r.division?.name ?? ""),
                ),
            },
            {
              key: "fee",
              label: "Fee",
              align: "right",
              render: (r) =>
                Number(r.fee_snapshot) ? formatMoney(r.fee_snapshot) : "Free",
            },
            {
              key: "status",
              label: "Status",
              render: (r) =>
                h(
                  "span",
                  {},
                  badge(...(REG_STATUS[r.status] ?? [r.status, "neutral"])),
                  r.status === "rejected" && r.status_reason
                    ? h("span", { class: "sub" }, r.status_reason)
                    : null,
                ),
            },
            {
              key: "actions",
              label: "Action",
              align: "center",
              render: (r) => {
                const live = ["requested", "confirmed", "waitlisted"].includes(
                  r.status,
                );
                return h(
                  "span",
                  { class: "row-actions" },
                  live && remaining(r) > 0
                    ? button({
                      label: "Pay",
                      size: "sm",
                      onClick: () => payModal(r),
                    })
                    : null,
                  r.division && ["drawn", "in_progress", "finalized"].includes(
                      r.division.status,
                    )
                    ? button({
                      label: "Bracket",
                      size: "sm",
                      onClick: () => {
                        location.hash = `#/bracket?division=${r.division.id}`;
                      },
                    })
                    : null,
                  live && r.division?.status === "open"
                    ? button({
                      label: "Withdraw",
                      size: "sm",
                      onClick: () => withdrawModal(r),
                    })
                    : null,
                );
              },
            },
          ],
        },
        rows: state.mine,
        state: state.status,
        ariaLabel: "My registrations",
        onRetry: refresh,
        emptyTitle: "No registrations yet",
        emptyText: "Register for an event and it will be listed here.",
      });
    }

    function draw() {
      tabsHost.replaceChildren(tabs({
        activeId: state.tab,
        tabs: [
          { id: "open", label: "Open events" },
          { id: "mine", label: "My registrations" },
        ],
        onChange: (id) => {
          state.tab = id;
          draw();
        },
      }));
      body.replaceChildren(state.tab === "open" ? openView() : mineView());
    }

    page.append(
      pageHeader({
        icon: "trophy",
        eyebrow: "Play",
        title: "Events",
        description:
          "Join a division, pay the fee if there is one, and follow your registrations.",
      }),
      tabsHost,
      body,
    );
    refresh();
    return page;
  }

  return { eventsPage };
}
