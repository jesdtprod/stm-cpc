// Staff-only guest setup and registration. Database RPCs own all eligibility,
// fees, payment status, duplicate protection and permission decisions.
import {
  badge,
  button,
  dateControl,
  h,
  icon,
  inputWithIcon,
  openModal,
  searchControl,
  selectControl,
  switchToggle,
  toast,
} from "./ui.js";
import { formatMoney } from "./lib/money.js";

const field = (id, label, control, hint) =>
  h(
    "div",
    { class: "field" },
    h("label", { for: id }, label),
    control,
    hint ? h("span", { class: "field-hint" }, hint) : null,
  );
const select = (id, options, value = "") =>
  selectControl(
    { id, name: id, class: "input select-input" },
    ...options.map(([key, label]) =>
      h("option", { value: key, selected: key === value }, label)
    ),
  );
const errorLine = () =>
  h("p", { class: "field-error", role: "alert", hidden: true });
const fail = (error, e) => {
  error.textContent = e?.cause?.message || e?.message || "Please try again.";
  error.hidden = false;
  return false;
};

export function createGuestEventActions(
  { api, refresh, getEvent, getDivisions, getRanks },
) {
  function policy() {
    const event = getEvent();
    const key = api.newKey();
    const error = errorLine();
    return openModal({
      title: "Guest Registration",
      icon: "user",
      eyebrow: event.name,
      description:
        "Only administrators can manage guest players. Guest registration can be enabled while registration is open or closed, before the draw.",
      confirmLabel: "Save Policy",
      body: h(
        "div",
        { class: "stack" },
        h(
          "div",
          { class: "guest-policy-card" },
          h(
            "div",
            { class: "guest-policy-info" },
            h(
              "span",
              { class: "badge-icon is-info guest-policy-icon", "aria-hidden": "true" },
              icon("users"),
            ),
            h(
              "div",
              { class: "guest-policy-copy" },
              h("strong", { class: "guest-policy-title" }, "Allow Guest Players"),
              h(
                "p",
                { class: "guest-policy-sub" },
                "Permit non-members to register for tournament divisions before the draw.",
              ),
            ),
          ),
          switchToggle({
            id: "allow-event-guests",
            name: "allow-event-guests",
            label: "Allow Guest Players",
            checked: event.allow_guest_players,
          }),
        ),
        h(
          "div",
          { class: "modal-callout is-info guest-policy-callout" },
          h("span", { class: "modal-callout-icon", "aria-hidden": "true" }, icon("info")),
          h(
            "div",
            { class: "modal-callout-text" },
            h("strong", {}, "Guest Policy Guidelines"),
            h(
              "p",
              { class: "sub" },
              "Administrators may add guests and assign assessed ranks while registration is open or closed. Category rules, division capacity limits, and entry fees apply to all guest entries. Drawn divisions cannot change roster policy.",
            ),
          ),
        ),
        error,
      ),
      onConfirm: async (form) => {
        try {
          await api.rpc("set_event_guest_policy", {
            p_event_id: event.id,
            p_allow: form.has("allow-event-guests"),
            p_key: key,
          });
          toast("Guest registration policy saved.", { tone: "success" });
          await refresh();
        } catch (e) {
          return fail(error, e);
        }
      },
    });
  }

  function addGuest() {
    const event = getEvent();
    const participantId = api.newKey();
    const personId = api.newKey();
    const error = errorLine();
    return openModal({
      title: "Add Guest",
      icon: "user",
      eyebrow: event.name,
      description:
        "Create a guest identity once, then register them in eligible divisions. Search existing players first to avoid duplicate profiles.",
      confirmLabel: "Add Guest",
      body: h(
        "div",
        { class: "stack" },
        h(
          "div",
          { class: "guest-modal-section" },
          h(
            "div",
            { class: "guest-modal-section-head" },
            h("span", { class: "section-icon is-sm", "aria-hidden": "true" }, icon("user")),
            h("span", { class: "guest-modal-section-title" }, "Guest Identity"),
          ),
          field(
            "guest-name",
            "Full Name *",
            inputWithIcon(
              h("input", {
                id: "guest-name",
                name: "guest-name",
                class: "input",
                required: true,
                maxlength: 120,
                placeholder: "Full legal or preferred name",
              }),
              "user",
            ),
          ),
          field(
            "guest-mobile",
            "Mobile",
            inputWithIcon(
              h("input", {
                id: "guest-mobile",
                name: "guest-mobile",
                type: "tel",
                class: "input",
                maxlength: 40,
                placeholder: "0917XXXXXXX",
              }),
              "phone",
            ),
          ),
        ),
        h(
          "div",
          { class: "guest-modal-section" },
          h(
            "div",
            { class: "guest-modal-section-head" },
            h("span", { class: "section-icon is-sm", "aria-hidden": "true" }, icon("calendar")),
            h("span", { class: "guest-modal-section-title" }, "Tournament Eligibility"),
          ),
          h(
            "div",
            { class: "form-grid-2" },
            field(
              "guest-gender",
              "Gender",
              select("guest-gender", [["", "Not provided"], ["male", "Male"], [
                "female",
                "Female",
              ]]),
              "Required for divisions with gender rules.",
            ),
            field(
              "guest-dob",
              "Birth Date",
              dateControl({ id: "guest-dob", name: "guest-dob" }),
              "Required for age-bracket divisions.",
            ),
          ),
        ),
        h(
          "div",
          { class: "guest-modal-section" },
          h(
            "div",
            { class: "guest-modal-section-head" },
            h("span", { class: "section-icon is-sm", "aria-hidden": "true" }, icon("medal")),
            h("span", { class: "guest-modal-section-title" }, "Rating (Optional)"),
          ),
          field(
            "guest-dupr-id",
            "DUPR ID (Optional)",
            inputWithIcon(
              h("input", {
                id: "guest-dupr-id",
                name: "guest-dupr-id",
                class: "input",
                maxlength: 32,
                autocapitalize: "characters",
                autocomplete: "off",
                placeholder: "Enter DUPR ID",
              }),
              "medal",
            ),
            "Recorded with event participation. Self-reported; no account verification or rating sync.",
          ),
        ),
        error,
      ),
      onConfirm: async (form) => {
        const duprId = String(form.get("guest-dupr-id") ?? "").trim()
          .toUpperCase();
        if (duprId && !/^[A-Z0-9]{1,32}$/.test(duprId)) {
          return fail(
            error,
            new Error("DUPR ID must contain 1 to 32 letters or numbers."),
          );
        }
        try {
          await api.rpc(
            duprId
              ? "create_guest_event_participant"
              : "create_event_participant",
            {
              p_id: participantId,
              p_event_id: event.id,
              p_guest_person_id: personId,
              p_guest_name: String(form.get("guest-name") ?? "").trim(),
              p_guest_mobile: String(form.get("guest-mobile") ?? "").trim() ||
                null,
              p_guest_gender: form.get("guest-gender") || null,
              p_guest_birth_date: form.get("guest-dob") || null,
              ...(duprId ? { p_dupr_id: duprId } : {}),
            },
          );
          toast("Guest added. Use Register Guest to select a division.", {
            tone: "success",
          });
          await refresh();
        } catch (e) {
          return fail(error, e);
        }
      },
    });
  }

  function addExisting() {
    const event = getEvent();
    const id = api.newKey();
    const error = errorLine();
    let selected = null;
    let request = 0;
    let debounceTimer = null;

    const previewHost = h("div", { class: "staff-selected-preview" });
    const results = h("div", {
      class: "staff-results guest-player-results",
      role: "radiogroup",
      "aria-label": "Player search results",
    });
    const search = searchControl({
      id: "event-player-search",
      class: "input",
      placeholder: "Name or member ID (at least 2 characters)",
      "aria-label": "Find existing player",
    });
    const status = h(
      "p",
      { class: "field-hint", role: "status" },
      "Type at least 2 characters to search active members and guests.",
    );

    function updatePreview(player) {
      selected = player;
      if (!player) {
        previewHost.replaceChildren();
        results.hidden = false;
        status.hidden = false;
        return;
      }
      results.hidden = true;
      status.hidden = true;
      const isMember = Boolean(player.member_id);
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
              icon(isMember ? "userCheck" : "users"),
            ),
            h(
              "div",
              { class: "member-meta" },
              h(
                "div",
                { class: "staff-selected-header-row" },
                h("strong", { class: "member-name" }, player.display_name),
                badge(isMember ? "Member" : "Guest", isMember ? "info" : "neutral"),
              ),
              h(
                "span",
                { class: "sub member-subtext" },
                isMember ? `Member ID: ${player.member_no}` : "Existing Guest Profile",
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
              updatePreview(null);
              const checkedRadio = Array.from(
                results.querySelectorAll("input"),
              ).find((i) => i.checked);
              if (checkedRadio) checkedRadio.checked = false;
              search.focus();
            },
          }),
        ),
      );
    }

    const find = async () => {
      const current = ++request;
      updatePreview(null);
      results.replaceChildren();
      const term = search.value.trim();
      if (term.length < 2) {
        status.textContent = "Type at least 2 characters to search.";
        return;
      }
      status.textContent = "Searching club profiles…";
      try {
        const rows = await api.rpc("search_event_players", {
          p_event_id: event.id,
          p_term: term,
        });
        if (current !== request) return;
        status.textContent = rows?.length
          ? `Choose a player (${rows.length} found). Choose one below.`
          : "No matches. Try another name or add a new guest.";
        results.replaceChildren(
          ...(rows ?? []).map((row) => {
            const isMember = Boolean(row.member_id);
            return h(
              "label",
              { class: "staff-result guest-player-result" },
              h("input", {
                type: "radio",
                name: "existing-event-player",
                value: row.person_id,
                onChange: () => {
                  updatePreview(row);
                },
              }),
              h(
                "span",
                { class: "member-avatar is-icon", "aria-hidden": "true" },
                icon(isMember ? "user" : "users"),
              ),
              h(
                "div",
                { class: "member-meta" },
                h("span", { class: "member-name" }, row.display_name),
                h(
                  "span",
                  { class: "sub member-subtext" },
                  isMember ? `Member ID: ${row.member_no}` : "Guest Player",
                ),
              ),
              badge(isMember ? "Member" : "Guest", isMember ? "info" : "neutral"),
            );
          }),
        );
      } catch (e) {
        if (current === request) fail(error, e);
        status.textContent = "Search failed. Try again.";
      }
    };

    search.addEventListener("input", () => {
      ++request;
      updatePreview(null);
      clearTimeout(debounceTimer);
      const text = search.value.trim();
      if (!text) {
        status.textContent = "Type at least 2 characters to search active members and guests.";
        results.replaceChildren();
        return;
      }
      if (text.length < 2) {
        status.textContent = "Type at least 2 characters to search.";
        results.replaceChildren();
        return;
      }
      debounceTimer = setTimeout(() => {
        find();
      }, 250);
    });

    search.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        clearTimeout(debounceTimer);
        find();
      }
    });

    return openModal({
      title: "Add Existing Player",
      icon: "userPlus",
      eyebrow: event.name,
      description:
        "Reuse a member or guest identity. Members may partner with guests without changing their membership.",
      confirmLabel: "Add Participant",
      body: h(
        "div",
        { class: "stack" },
        h(
          "div",
          { class: "guest-modal-section" },
          h(
            "div",
            { class: "guest-modal-section-head" },
            h("span", { class: "section-icon is-sm", "aria-hidden": "true" }, icon("search")),
            h("span", { class: "guest-modal-section-title" }, "Find Player"),
            badge("All Club Profiles", "neutral"),
          ),
          h(
            "div",
            { class: "guest-search-row" },
            search,
            button({ label: "Search", icon: "search", variant: "secondary", onClick: find }),
          ),
          status,
          previewHost,
          results,
        ),
        error,
      ),
      onConfirm: async () => {
        if (!selected) {
          return fail(
            error,
            new Error("Choose a player from the search results."),
          );
        }
        try {
          await api.rpc("create_event_participant", {
            p_id: id,
            p_event_id: event.id,
            p_member_id: selected.member_id || null,
            p_guest_person_id: selected.member_id ? null : selected.person_id,
          });
          toast("Player added to the event participant list.", {
            tone: "success",
          });
          await refresh();
        } catch (e) {
          return fail(error, e);
        }
      },
    });
  }

  async function register(divisionId = "", change = null) {
    const event = getEvent();
    let players;
    try {
      players = await api.rpc("event_participant_choices", {
        p_event_id: event.id,
      });
    } catch (e) {
      toast(e?.cause?.message || e.message, { tone: "error" });
      return;
    }
    const guests = (players ?? []).filter((p) => !p.member_id);
    if (!guests.length) {
      toast("Add a guest or an existing guest player first.", {
        tone: "warning",
      });
      return;
    }
    const key = api.newKey();
    const error = errorLine();
    const ranks = [
      ["", "Choose assessed rank"],
      ...getRanks().map((r) => [r.id, r.label]),
    ];
    const source = change?.row;
    const defaultPartner = source?.guest_partner_participant_id ??
      players?.find((p) =>
        p.member_id && p.member_id === source?.meta?.partner_member_id
      )?.id ?? "";
    const divisions = getDivisions().filter((d) =>
      d.status === "open" &&
      (!change || (change.kind === "move"
        ? d.id !== source.division_id
        : d.id === source.division_id))
    );
    if (!divisions.length) {
      toast("No eligible undrawn destination division is available.", {
        tone: "warning",
      });
      return;
    }
    return openModal({
      title: change
        ? (change.kind === "move" ? "Move Guest Entry" : "Replace Players")
        : "Register Guest",
      icon: "layers",
      eyebrow: event.name,
      description: change
        ? "The original registration is kept in history. Fees use the current event price. Payment credit follows the same guest payer; a replacement payer needs their own payment."
        : "Administrators may register guests while registration is open or closed. Eligibility, capacity and payment rules still apply.",
      confirmLabel: change ? "Save Change" : "Register Guest",
      body: h(
        "div",
        { class: "stack" },
        h(
          "div",
          { class: "guest-modal-section" },
          h(
            "div",
            { class: "guest-modal-section-head" },
            h("span", { class: "section-icon is-sm", "aria-hidden": "true" }, icon("user")),
            h("span", { class: "guest-modal-section-title" }, "Guest & Rank Assessment"),
          ),
          field(
            "guest-player",
            "Guest *",
            select(
              "guest-player",
              guests.filter((p) =>
                !change || change.kind !== "move" ||
                p.id === source.guest_participant_id
              ).map((p) => [p.id, p.display_name]),
              source?.guest_participant_id ?? guests[0].id,
            ),
          ),
          field(
            "guest-rank",
            "Assessed Guest Rank *",
            select("guest-rank", ranks, source?.guest_rank_id ?? ""),
            "An authorized staff member assesses the guest. The server checks the division's category and rank band.",
          ),
        ),
        h(
          "div",
          { class: "guest-modal-section" },
          h(
            "div",
            { class: "guest-modal-section-head" },
            h("span", { class: "section-icon is-sm", "aria-hidden": "true" }, icon("trophy")),
            h("span", { class: "guest-modal-section-title" }, "Division & Team"),
          ),
          field(
            "guest-division",
            "Division *",
            select(
              "guest-division",
              divisions.map((
                d,
              ) => [d.id, d.name]),
              divisions.some((d) => d.id === divisionId)
                ? divisionId
                : divisions[0]?.id,
            ),
          ),
          field(
            "guest-partner",
            "Doubles Partner",
            select("guest-partner", [
              ["", "No partner (singles)"],
              ...(players ?? []).map((
                p,
              ) => [p.id, `${p.display_name} · ${p.member_no || "Guest"}`]),
            ], defaultPartner),
            "Add the partner to the event participant list first. Singles take no partner.",
          ),
          field(
            "guest-partner-rank",
            "Assessed Partner Rank",
            select(
              "guest-partner-rank",
              ranks,
              source?.guest_partner_rank_id ?? "",
            ),
            "Choose only for a guest partner. A member's rank is read from their profile.",
          ),
        ),
        change
          ? h(
            "div",
            { class: "guest-modal-section" },
            h(
              "div",
              { class: "guest-modal-section-head" },
              h("span", { class: "section-icon is-sm", "aria-hidden": "true" }, icon("file")),
              h("span", { class: "guest-modal-section-title" }, "Change Reason"),
            ),
            field(
              "guest-change-reason",
              "Reason *",
              h("textarea", {
                id: "guest-change-reason",
                name: "guest-change-reason",
                class: "input textarea",
                required: true,
                minlength: 3,
                maxlength: 500,
                rows: 3,
                placeholder: "Provide context or explanation for this roster change...",
              }),
              "Recorded with the original and replacement registrations.",
            ),
          )
          : null,
        error,
      ),
      onConfirm: async (form) => {
        try {
          const request = {
            p_id: key,
            p_division_id: form.get("guest-division"),
            p_participant_id: form.get("guest-player"),
            p_rank_id: form.get("guest-rank") || null,
            p_partner_participant_id: form.get("guest-partner") || null,
            p_partner_rank_id: form.get("guest-partner-rank") || null,
          };
          if (change) {
            delete request.p_participant_id;
            request.p_registration_id = source.id;
            request.p_kind = change.kind;
            request.p_reason = String(form.get("guest-change-reason") ?? "")
              .trim();
            request.p_replacement_participant_id = change.kind === "replace"
              ? form.get("guest-player")
              : null;
          }
          await api.rpc(
            change ? "change_guest_registration" : "register_guest_for_event",
            request,
          );
          toast(
            change
              ? "Guest roster change saved with its history."
              : "Guest registration saved. Approval and payment rules apply.",
            {
              tone: "success",
            },
          );
          await refresh();
        } catch (e) {
          return fail(error, e);
        }
      },
    });
  }

  async function payment(row, remaining) {
    let settings;
    let profile;
    try {
      const [rows, profiles] = await Promise.all([
        api.read((c) =>
          c.from("settings").select("key,value").is("unit_id", null).is(
            "deleted_at",
            null,
          )
            .in("key", [
              "payments.methods",
              "payments.instructions",
              "payments.proof_required_non_cash",
            ])
        ),
        api.rpc("my_profile"),
      ]);
      settings = Object.fromEntries((rows ?? []).map((r) => [r.key, r.value]));
      profile = profiles?.[0];
      if (!profile) {
        throw new Error("Sign in again before submitting a payment.");
      }
    } catch (e) {
      toast(e?.cause?.message || e.message, { tone: "error" });
      return;
    }
    const methods = settings["payments.methods"] ?? ["cash"];
    const proofRequired =
      settings["payments.proof_required_non_cash"] !== false;
    const proofTypes = {
      "image/jpeg": "jpg",
      "image/png": "png",
      "image/webp": "webp",
      "application/pdf": "pdf",
    };
    const proof = h("input", {
      class: "input",
      id: "guest-payment-proof",
      type: "file",
      accept: Object.keys(proofTypes).join(","),
    });
    let uploaded;
    const key = api.newKey();
    const error = errorLine();
    return openModal({
      title: "Record Guest Payment",
      icon: "file",
      eyebrow: row.guest_name_snapshot,
      description:
        "Submit a receipt for normal payment verification. Recording it does not automatically approve the registration.",
      confirmLabel: "Submit Payment",
      body: h(
        "div",
        { class: "stack" },
        h("p", {}, `Remaining fee: ${formatMoney(remaining)}`),
        settings["payments.instructions"]
          ? h("p", { class: "muted" }, settings["payments.instructions"])
          : null,
        field(
          "guest-payment-method",
          "Method *",
          select(
            "guest-payment-method",
            methods.map((
              m,
            ) => [
              m,
              ({
                cash: "Cash",
                gcash: "GCash",
                maya: "Maya",
                bank_transfer: "Bank Transfer",
                other: "Other",
              })[m] ?? m,
            ]),
            methods[0],
          ),
        ),
        field(
          "guest-payment-reference",
          "Reference Number",
          h("input", {
            class: "input",
            id: "guest-payment-reference",
            name: "guest-payment-reference",
            maxlength: 64,
          }),
        ),
        field(
          "guest-cash-amount",
          "Amount Received *",
          h("input", {
            id: "guest-cash-amount",
            name: "guest-cash-amount",
            class: "input",
            type: "number",
            min: "0.01",
            max: remaining,
            step: "0.01",
            value: remaining,
            required: true,
          }),
        ),
        field(
          "guest-payment-proof",
          "Payment Proof",
          proof,
          proofRequired
            ? "Required for non-cash payments. JPG, PNG, WebP or PDF up to 5 MB."
            : "Optional. JPG, PNG, WebP or PDF up to 5 MB.",
        ),
        error,
      ),
      onConfirm: async (form) => {
        const method = form.get("guest-payment-method");
        const file = proof.files?.[0];
        if (
          file &&
          (!proofTypes[file.type] || file.size > 5 * 1024 * 1024 || !file.size)
        ) {
          return fail(
            error,
            new Error("Choose a JPG, PNG, WebP or PDF up to 5 MB."),
          );
        }
        if (method !== "cash" && proofRequired && !file) {
          return fail(error, new Error("Attach the payment proof."));
        }
        try {
          if (file && uploaded?.file !== file) {
            const path =
              `${profile.org_id}/${profile.profile_id}/${api.newKey()}.${
                proofTypes[file.type]
              }`;
            await api.read((c) =>
              c.storage.from("payment-proofs").upload(path, file, {
                contentType: file.type,
                upsert: false,
              })
            );
            uploaded = { file, path };
          }
          await api.rpc("submit_guest_event_payment", {
            p_id: key,
            p_registration_id: row.id,
            p_method: method,
            p_reference_no: form.get("guest-payment-reference") || null,
            p_amount: Number(form.get("guest-cash-amount")),
            p_proof_path: file ? uploaded.path : null,
          });
          toast("Receipt submitted. Verify it in Payments.", {
            tone: "success",
          });
          await refresh();
        } catch (e) {
          return fail(error, e);
        }
      },
    });
  }
  return {
    policy,
    addGuest,
    addExisting,
    register,
    payment,
    change: (row, kind) => register(row.division_id, { row, kind }),
  };
}
