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
  icon,
  iconButton,
  memberHero,
  openModal,
  searchControl,
  selectControl,
  tableFilter,
  toast,
} from "./ui.js";
import { formatDate } from "./lib/dates.js";
import { formatMoney } from "./lib/money.js";
import { ulid } from "./lib/ulid.js";
import { eventSummary, eventSummarySkeleton } from "./event-summary.js";

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
  bank_transfer: "Bank Transfer",
};
const REG_STATUS = {
  requested: ["Waiting for Approval", "warning"],
  confirmed: ["Confirmed", "success"],
  waitlisted: ["Waitlisted", "info"],
  withdrawn: ["Withdrawn", "neutral"],
  rejected: ["Rejected", "danger"],
};
const GENDER_LABEL = { male: "Men", female: "Women", mixed: "Mixed" };
const CATEGORY_ORDER = {
  beginner: 0, novice: 1, intermediate: 2, advanced: 3, advance: 3, elite: 4,
};
const categoryOrder = (d) =>
  CATEGORY_ORDER[String(d.category ?? "").trim().toLowerCase()] ?? 5;
const genderOrder = (d) => ({ male: 0, female: 1, mixed: 2 })[d.gender] ?? 3;
const levelOrder = (d) => /\blow\b/i.test(d.name) ? 0
  : /\bhigh\b/i.test(d.name) ? 1 : 2;
const compareDivisions = (a, b) =>
  categoryOrder(a) - categoryOrder(b) ||
  (categoryOrder(a) === 5
    ? String(a.category ?? "").localeCompare(String(b.category ?? ""), "en")
    : 0) ||
  genderOrder(a) - genderOrder(b) || levelOrder(a) - levelOrder(b) ||
  String(a.name).localeCompare(String(b.name), "en", { numeric: true });

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
    const page = h("div", { class: "page member-events-page" });
    const tabsHost = h("div", {});
    const body = h("div", { class: "events-body" });
    const state = {
      tab: "open",
      status: "loading",
      options: [],
      mine: [],
      pays: {},
      settings: {},
      term: "",
    };
    const search = searchControl({
      id: "member-events-search",
      class: "input",
      placeholder: "Search events...",
      "aria-label": "Search Events and Registrations",
      onInput: () => {
        state.term = search.value;
        draw();
      },
    });
    const matches = (...values) => {
      const normalize = (value) =>
        String(value ?? "").normalize("NFKD")
          .replace(/\p{M}/gu, "").toLocaleLowerCase();
      const text = normalize(values.join(" "));
      return normalize(state.term).trim().split(/\s+/).filter(Boolean)
        .every((term) => text.includes(term));
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
        const details = options?.length ? await api.read((c) =>
          c.from("events").select(
            "id,dupr_rated,apply_cpc_rank_changes,divisions(id,status)," +
              "default_template:format_templates!events_default_format_template_id_fkey(name)",
          ).in("id", options.map((ev) => ev.id))
        ) : [];
        const summaries = new Map(details.map((ev) => [ev.id, ev]));
        state.options = (options ?? []).map((ev) => ({
          ...ev,
          dupr_rated: summaries.get(ev.id)?.dupr_rated,
          apply_cpc_rank_changes: summaries.get(ev.id)?.apply_cpc_rank_changes,
          default_format_template_name: summaries.get(ev.id)?.default_template?.name,
          divisions_count: summaries.get(ev.id)?.divisions?.filter((d) => d.status !== "cancelled").length ??
            (ev.divisions ?? []).length,
          divisions: [...(ev.divisions ?? [])].sort(compareDivisions),
        }));
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
      const full = d.max_entries && d.taken >= d.max_entries;
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
      const previewHost = h("div", { class: "partner-preview-host" });
      const summary = h(
        "p",
        { class: "sub form-help-text" },
        "Search by partner's name or member ID. Active members only.",
      );
      const results = h("div", { class: "staff-results" });
      const term = searchControl({
        class: "input",
        id: "rg-term",
        type: "search",
        placeholder: "Partner's name or member ID",
        maxlength: 60,
      });

      function updatePartner(p) {
        partner = p;
        if (!p) {
          previewHost.replaceChildren();
          results.hidden = false;
          summary.hidden = false;
          return;
        }
        results.hidden = true;
        summary.hidden = true;
        previewHost.replaceChildren(
          h(
            "div",
            { class: "staff-selected-card" },
            h(
              "div",
              { class: "staff-selected-identity" },
              h(
                "span",
                {
                  class: "member-avatar is-icon staff-selected-avatar",
                  "aria-hidden": "true",
                },
                icon("user"),
              ),
              h(
                "div",
                { class: "member-meta" },
                h(
                  "div",
                  { class: "staff-selected-header-row" },
                  h("strong", { class: "member-name" }, p.display_name),
                  badge("Doubles Partner", "success"),
                ),
                h(
                  "span",
                  { class: "sub member-subtext" },
                  `Member ID: ${p.member_no}`,
                ),
              ),
            ),
            button({
              label: "Change",
              icon: "refresh",
              variant: "ghost",
              class: "staff-change-btn",
              onClick: (e) => {
                e.preventDefault();
                updatePartner(null);
                const checked = results.querySelector(
                  "input[type='radio']:checked",
                );
                if (checked) checked.checked = false;
              },
            }),
          ),
        );
      }

      async function search() {
        updatePartner(null);
        const text = term.value.trim();
        if (text.length < 2) {
          summary.textContent = "Type at least 2 letters or numbers.";
          results.replaceChildren();
          return;
        }
        summary.textContent = "Searching players…";
        try {
          const rows = await api.rpc("find_players", { p_term: text });
          const players = (rows ?? []).filter((r) =>
            r.member_id !== profile()?.id
          );
          summary.textContent = players.length
            ? `${players.length} found. Choose one below.`
            : "No active members match. Your partner must be an active club member.";
          results.replaceChildren(
            ...players.map((r) =>
              h(
                "label",
                { class: "staff-result" },
                h("input", {
                  type: "radio",
                  name: "partner",
                  value: r.member_id,
                  onChange: () => updatePartner(r),
                }),
                h("span", {
                  class: "member-avatar is-icon",
                  "aria-hidden": "true",
                }, icon("user")),
                h(
                  "span",
                  { class: "member-meta" },
                  h("span", { class: "member-name" }, r.display_name),
                  h(
                    "span",
                    { class: "sub member-subtext" },
                    r.member_no,
                  ),
                ),
                badge("Active", "success"),
              )
            ),
          );
        } catch (e) {
          summary.textContent = eventMessage(e, "The search did not work.");
        }
      }

      term.addEventListener("keydown", (e) => {
        if (e.key === "Enter") {
          e.preventDefault();
          search();
        }
      });

      const summaryCard = h(
        "div",
        { class: "event-registration-summary-card" },
        h(
          "div",
          { class: "event-registration-summary-header" },
          h(
            "div",
            { class: "event-registration-summary-title-col" },
            h("span", { class: "eyebrow" }, "Tournament Division"),
            h("strong", { class: "event-registration-division-title" }, d.name),
            h(
              "span",
              { class: "sub" },
              [
                ev.name,
                d.format === "doubles" ? "Doubles" : "Singles",
                GENDER_LABEL[d.gender],
                d.category,
              ].filter(Boolean).join(" · "),
            ),
          ),
          h(
            "div",
            { class: "event-registration-summary-badges" },
            Number(ev.fee) > 0
              ? badge(formatMoney(ev.fee), "primary")
              : badge("Free Entry", "success"),
            full ? badge("Waitlist Only", "warning") : badge("Open", "success"),
          ),
        ),
        Number(ev.fee) > 0
          ? h(
            "div",
            { class: "event-registration-fee-note" },
            icon("currency"),
            h(
              "span",
              {},
              `Registration fee: ${formatMoney(ev.fee)}${
                doubles ? " for the pair (paid by you upon approval)" : ""
              }.`,
            ),
          )
          : null,
        full
          ? h(
            "div",
            {
              class:
                "division-problem-callout event-registration-waitlist-callout",
            },
            icon("info"),
            h(
              "span",
              {},
              "This division has reached capacity. Submitting places your team on the official waitlist.",
            ),
          )
          : null,
      );

      const partnerPanel = doubles
        ? h(
          "div",
          { class: "form-section event-registration-partner-panel" },
          h(
            "div",
            { class: "event-registration-partner-head" },
            h(
              "div",
              { class: "event-registration-partner-label" },
              icon("userPlus"),
              h("strong", {}, "Doubles Partner *"),
            ),
            badge("Required", "warning"),
          ),
          h(
            "div",
            { class: "staff-search" },
            term,
            button({
              label: "Search",
              icon: "search",
              onClick: search,
            }),
          ),
          summary,
          results,
          previewHost,
          h(
            "p",
            { class: "event-registration-partner-tip" },
            icon("info"),
            h(
              "span",
              {},
              "Your partner must also be an active club member eligible for this division.",
            ),
          ),
        )
        : null;

      return openModal({
        title: "Register for Division",
        eyebrow: "Event Registration",
        description: `${ev.name} · ${d.name}`,
        icon: "trophy",
        size: "md",
        confirmLabel: full ? "Join Waitlist" : "Register",
        cancelLabel: "Cancel",
        body: h(
          "div",
          { class: "stack" },
          summaryCard,
          partnerPanel,
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
        title: "Withdraw Your Registration",
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
        title: "Pay the Registration Fee",
        eyebrow: `${r.event?.name ?? ""} · ${r.division?.name ?? ""}`,
        icon: "currency",
        confirmLabel: "Send Payment",
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
            selectControl(
              { class: "input select-input", id: "pay-method", name: "method" },
              ...methods.map((m) =>
                h("option", { value: m }, METHOD_LABEL[m] ?? m)
              ),
            ),
          ),
          h(
            "div",
            { class: "field" },
            h("label", { for: "pay-ref" }, "Reference Number"),
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
    function divisionsTable(ev, viewState = "ready") {
      const divisionBadge = (d) =>
        d.mine
          ? badge(
            ...(REG_STATUS[d.mine.status] ??
              [d.mine.status, "neutral"]),
          )
          : d.problem
          ? badge("Unavailable", "warning")
          : d.max_entries && d.taken >= d.max_entries
          ? badge("Waitlist", "info")
          : badge("Open", "success");

      return h(
        "div",
        { class: "member-event-division-list" },
        dataTable({
          searchable: false,
          searchState: state,
          schema: {
            columns: [
              {
                key: "name",
                label: "Division",
                render: (d) =>
                  h(
                    "div",
                    { class: "member-event-division-col" },
                    h(
                      "div",
                      { class: "member-event-division-header" },
                      h(
                        "div",
                        { class: "member-event-division-identity" },
                        h("span", {
                          class: `member-avatar is-icon ${d.problem ? "is-restricted" : "is-eligible"}`,
                          "aria-hidden": "true",
                        }, icon("trophy")),
                        h(
                          "div",
                          { class: "member-event-division-copy" },
                          h(
                            "strong",
                            { class: "member-event-division-name" },
                            d.name,
                          ),
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
                      ),
                      h(
                        "div",
                        { class: "member-event-division-badge-mobile" },
                        divisionBadge(d),
                      ),
                    ),
                    d.problem
                      ? h(
                        "div",
                        { class: "member-event-restriction-note" },
                        icon("info"),
                        h("span", {}, d.problem),
                      )
                      : null,
                  ),
              },
              {
                key: "spots",
                label: "Entries",
                align: "right",
                render: (d) =>
                  h(
                    "div",
                    { class: "member-event-entries" },
                    h(
                      "div",
                      { class: "member-event-entries-meta" },
                      h("span", { class: "member-event-entries-label" }, "Entries"),
                      h(
                        "strong",
                        { class: "member-event-entries-count" },
                        d.max_entries
                          ? `${d.taken} of ${d.max_entries}`
                          : String(d.taken),
                      ),
                    ),
                    d.max_entries
                      ? h("progress", {
                        class: "member-event-capacity",
                        value: Math.max(
                          0,
                          Math.min(Number(d.taken), Number(d.max_entries)),
                        ),
                        max: d.max_entries,
                        "aria-label": `Entry capacity for ${d.name}`,
                      })
                      : h("span", { class: "sub" }, "No Entry Limit"),
                  ),
              },
              {
                key: "state",
                label: "Status",
                render: (d) => divisionBadge(d),
              },
              {
                key: "actions",
                label: "Action",
                align: "center",
                actionCount: 1,
                render: (d) =>
                  !d.mine && !d.problem
                    ? iconButton({
                      icon: "userPlus",
                      label: d.max_entries && d.taken >= d.max_entries
                        ? "Waitlist"
                        : "Register",
                      variant: "success",
                      onClick: () => registerModal(ev, d),
                    })
                    : null,
              },
            ],
          },
          rows: ev.divisions,
          state: viewState,
          ariaLabel: `Divisions of ${ev.name}`,
          emptyTitle: "No Divisions",
          emptyText: "This event has no open divisions.",
        }),
      );
    }

    function memberEventSummary(ev) {
      return h("header", { class: "member-event-header" },
        ...eventSummary({ ...ev, status: "registration_open" }),
      );
    }

    function openView() {
      const options = state.options.flatMap((ev) => {
        const eventText = [
          ev.name,
          ev.location,
          when(ev.starts_on),
          when(ev.ends_on),
        ];
        if (matches(...eventText)) return [ev];
        const divisions = (ev.divisions ?? []).filter((d) =>
          matches(
            ...eventText,
            d.name,
            d.format === "doubles" ? "Doubles" : "Singles",
            GENDER_LABEL[d.gender],
            d.age_group,
            d.category,
            d.mine ? REG_STATUS[d.mine.status]?.[0] : d.problem ||
              (d.max_entries && d.taken >= d.max_entries ? "Waitlist" : "Open"),
          )
        );
        return divisions.length ? [{ ...ev, divisions }] : [];
      });
      if (state.status === "loading") {
        const bar = (shape = "w-70") => h("span", { class: `sk ${shape}` });
        return h(
          "section",
          {
            class: "member-panel member-event-panel",
            "aria-label": "Loading Events",
            "aria-busy": "true",
          },
          h(
            "header",
            { class: "member-event-header", "aria-hidden": "true" },
            ...eventSummarySkeleton(),
          ),
          h(
            "div",
            { class: "member-event-divisions" },
            h("div", {
              class: "member-event-divisions-heading",
              "aria-hidden": "true",
            }, bar("w-30")),
            divisionsTable({ name: "Loading Event", divisions: [] }, "loading"),
          ),
        );
      }
      if (state.status === "error") {
        return dataTable({
          searchable: false,
          searchState: state,
          schema: { columns: [{ key: "n", label: "Event", render: () => "" }] },
          rows: [],
          state: "error",
          onRetry: refresh,
          ariaLabel: "Events",
        });
      }
      if (!options.length) {
        return dataTable({
          searchable: false,
          searchState: state,
          schema: { columns: [{ key: "n", label: "Event", render: () => "" }] },
          rows: [],
          state: "ready",
          ariaLabel: "Events",
          emptyTitle: state.term.trim()
            ? "No matching events"
            : "No events open for registration",
          emptyText: state.term.trim()
            ? "Try another event, division, or category."
            : "When the club opens registration, the event appears here.",
        });
      }
      return h(
        "div",
        { class: "stack" },
        ...options.map((ev) =>
          h(
            "section",
            {
              class: "member-panel member-event-panel",
              "aria-label": ev.name,
              "aria-busy": state.status === "refreshing" ? "true" : "false",
            },
            memberEventSummary(ev),
            h(
              "div",
              { class: "member-event-divisions" },
              h(
                "div",
                { class: "member-event-divisions-heading" },
                h("h3", {}, "Divisions"),
                h(
                  "span",
                  { class: "sub" },
                  `${ev.divisions.length} ${
                    ev.divisions.length === 1 ? "Division" : "Divisions"
                  }`,
                ),
              ),
              divisionsTable(ev),
            ),
          )
        ),
      );
    }

    function mineView() {
      return dataTable({
        searchable: false,
        searchState: state,
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
                Number(r.fee_snapshot)
                  ? formatMoney(r.fee_snapshot)
                  : badge("Free", "success"),
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
              actionCount: 3,
              render: (r) => {
                const live = ["requested", "confirmed", "waitlisted"].includes(
                  r.status,
                );
                return h(
                  "span",
                  { class: "row-actions" },
                  live && remaining(r) > 0
                    ? iconButton({
                      icon: "currency",
                      label: "Pay",
                      variant: "success",
                      onClick: () => payModal(r),
                    })
                    : null,
                  r.division && ["drawn", "in_progress", "finalized"].includes(
                      r.division.status,
                    )
                    ? iconButton({
                      icon: "layers",
                      label: "Bracket",
                      variant: "info",
                      onClick: () => {
                        location.hash = `#/bracket?division=${r.division.id}`;
                      },
                    })
                    : null,
                  live && r.division?.status === "open"
                    ? iconButton({
                      icon: "x",
                      label: "Withdraw",
                      variant: "danger",
                      onClick: () => withdrawModal(r),
                    })
                    : null,
                );
              },
            },
          ],
        },
        rows: state.mine.filter((r) =>
          matches(
            r.event?.name,
            r.division?.name,
            REG_STATUS[r.status]?.[0],
            r.status_reason,
            Number(r.fee_snapshot) ? formatMoney(r.fee_snapshot) : "Free",
          )
        ),
        state: state.status,
        ariaLabel: "My Registrations",
        onRetry: refresh,
        emptyTitle: "No registrations yet",
        emptyText: "Register for an event and it will be listed here.",
      });
    }

    function draw() {
      tabsHost.replaceChildren(tableFilter({
        activeId: state.tab,
        tabs: [
          { id: "open", label: "Open Events", badge: state.options.length },
          { id: "mine", label: "My Registrations", badge: state.mine.length },
        ],
        onChange: (id) => {
          state.tab = id;
          draw();
        },
      }));
      body.replaceChildren(state.tab === "open" ? openView() : mineView());
    }

    page.append(
      memberHero({
        iconName: "trophy",
        eyebrow: "Play",
        title: "Events",
        chip: "Events and Registration",
        titleBadge: true,
        description:
          "Join a division, pay the fee if there is one, and follow your registrations.",
      }),
      h(
        "div",
        { class: "toolbar admin-members-toolbar has-status-badges" },
        search,
        tabsHost,
      ),
      body,
    );
    refresh();
    return page;
  }

  return { eventsPage };
}
