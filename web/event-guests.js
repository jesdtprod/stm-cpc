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
  { api, refresh, getEvent, getDivisions },
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
            h("span", { class: "section-icon is-sm", "aria-hidden": "true" }, icon("trophy")),
            h("span", { class: "guest-modal-section-title" }, "Guest Assessment (Optional)"),
          ),
          h(
            "div",
            { class: "form-grid-2" },
            field(
              "guest-singles",
              "Singles Rating",
              h("input", {
                id: "guest-singles", name: "guest-singles", class: "input", type: "number", inputmode: "decimal",
                min: "2", max: "8", step: "0.001", placeholder: "NR (not rated)",
              }),
              "2.000–8.000, used for singles divisions.",
            ),
            field(
              "guest-doubles",
              "Doubles Rating",
              h("input", {
                id: "guest-doubles", name: "guest-doubles", class: "input", type: "number", inputmode: "decimal",
                min: "2", max: "8", step: "0.001", placeholder: "NR (not rated)",
              }),
              "2.000–8.000, used for doubles divisions.",
            ),
          ),
          h("p", { class: "sub" }, "Leave either rating blank for Unrated. Unrated guests may join Beginner divisions starting at Beginner Low; other divisions require an eligible rating."),
        ),
        h(
          "div",
          { class: "guest-modal-section" },
          h(
            "div",
            { class: "guest-modal-section-head" },
            h("span", { class: "section-icon is-sm", "aria-hidden": "true" }, icon("medal")),
            h("span", { class: "guest-modal-section-title" }, "DUPR (Optional)"),
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
        const rating = (id) => {
          const raw = String(form.get(id) ?? "").trim();
          if (!raw) return { value: null };
          const n = Number(raw);
          return /^\d(\.\d{1,3})?$/.test(raw) && n >= 2 && n <= 8 ? { value: n } : { invalid: true };
        };
        const singles = rating("guest-singles");
        const doubles = rating("guest-doubles");
        if (singles.invalid || doubles.invalid) {
          return fail(error, new Error("Enter a rating from 2.000 to 8.000 with at most three decimals."));
        }
        try {
          await api.rpc("create_guest_event_participant", {
            p_id: participantId,
            p_event_id: event.id,
            p_guest_person_id: personId,
            p_guest_name: String(form.get("guest-name") ?? "").trim(),
            p_guest_mobile: String(form.get("guest-mobile") ?? "").trim() || null,
            p_guest_gender: form.get("guest-gender") || null,
            p_guest_birth_date: form.get("guest-dob") || null,
            p_dupr_id: duprId || null,
            p_singles_rating: singles.value,
            p_doubles_rating: doubles.value,
          });
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

  // Edit a guest (events.admin_roster): the profile (name, mobile, gender, birth date, DUPR ID) and the Singles and Doubles
  // ratings. The database refuses a rating change without a reason, a frozen rating, and any change that would make the
  // guest ineligible for a division they are already in. Registrations keep the name they were made under.
  async function editGuest(participantId = "") {
    const event = getEvent();
    let players;
    try {
      players = await api.rpc("event_participant_choices", { p_event_id: event.id });
    } catch (e) {
      toast(e?.cause?.message || e.message, { tone: "error" });
      return;
    }
    const guests = (players ?? []).filter((p) => !p.member_id);
    if (!guests.length) {
      toast("There are no guests to edit yet.", { tone: "warning" });
      return;
    }
    const error = errorLine();
    let loaded = null;
    let intent = null;
    const guestSelect = select(
      "edit-guest",
      guests.map((g) => [g.id, g.display_name]),
      guests.some((g) => g.id === participantId) ? participantId : guests[0].id,
    );
    const nameInput = h("input", { id: "edit-name", name: "edit-name", class: "input", required: true, maxlength: 120 });
    const mobileInput = h("input", { id: "edit-mobile", name: "edit-mobile", type: "tel", class: "input", maxlength: 40 });
    const genderSelect = select("edit-gender", [["", "Not provided"], ["male", "Male"], ["female", "Female"]]);
    const dobInput = dateControl({ id: "edit-dob", name: "edit-dob" });
    const duprInput = h("input", {
      id: "edit-dupr", name: "edit-dupr", class: "input", maxlength: 32, autocapitalize: "characters", autocomplete: "off",
    });
    const ratingInput = (id) =>
      h("input", {
        id, name: id, class: "input", type: "number", inputmode: "decimal", min: "2", max: "8", step: "0.001",
        placeholder: "NR (not rated)",
      });
    const singlesInput = ratingInput("edit-singles");
    const doublesInput = ratingInput("edit-doubles");
    const singlesNote = h("p", { class: "sub" });
    const doublesNote = h("p", { class: "sub" });
    const reasonInput = h("textarea", {
      id: "edit-reason", name: "edit-reason", class: "input textarea", rows: 2, maxlength: 500,
      placeholder: "Required when a rating changes.",
    });

    async function loadGuest() {
      error.hidden = true;
      try {
        loaded = await api.rpc("event_guest_profile", { p_participant_id: guestSelect.value });
      } catch (e) {
        fail(error, e);
        return;
      }
      nameInput.value = loaded.display_name ?? "";
      mobileInput.value = loaded.mobile ?? "";
      genderSelect.value = loaded.gender ?? "";
      dobInput.value = loaded.date_of_birth ?? "";
      duprInput.value = loaded.dupr_id ?? "";
      for (const [discipline, input, note] of [["singles", singlesInput, singlesNote], ["doubles", doublesInput, doublesNote]]) {
        const side = loaded[discipline] ?? {};
        input.value = side.points == null ? "" : Number(side.points).toFixed(3);
        input.disabled = Boolean(side.frozen);
        note.textContent = side.frozen
          ? "Frozen: this guest is in a drawn division, so the rating can't change."
          : side.points == null
          ? "Not rated (NR). Enter a rating to assess the guest."
          : "";
      }
      reasonInput.value = "";
    }
    guestSelect.addEventListener("change", loadGuest);
    loadGuest();

    const section = (iconName, title, ...children) =>
      h(
        "div",
        { class: "form-section event-registration-partner-panel guest-edit-section" },
        h(
          "div",
          { class: "guest-modal-section-head" },
          h("span", { class: "section-icon is-sm", "aria-hidden": "true" }, icon(iconName)),
          h("span", { class: "guest-modal-section-title" }, title),
        ),
        ...children,
      );
    return openModal({
      title: "Edit Guest",
      icon: "user",
      eyebrow: "Guest Management",
      size: "lg",
      description: event.name,
      confirmLabel: "Save Changes",
      body: h(
        "div",
        { class: "stack guest-edit-form" },
        h("div", { class: "event-registration-summary-card guest-edit-selector" },
          field("edit-guest", "Choose Guest", guestSelect),
        ),
        h("div", { class: "guest-edit-layout" },
        section(
          "user",
          "Guest Details",
          h("div", { class: "form-grid-2" },
          field("edit-name", "Full Name *", inputWithIcon(nameInput, "user")),
          field("edit-mobile", "Mobile", inputWithIcon(mobileInput, "phone")),
          ),
          h(
            "div",
            { class: "form-grid-2" },
            field("edit-gender", "Gender", genderSelect),
            field("edit-dob", "Birth Date", dobInput),
          ),
          field("edit-dupr", "DUPR ID (Optional)", inputWithIcon(duprInput, "medal")),
        ),
        section(
          "trophy",
          "Club Ratings",
          h(
            "div",
            { class: "form-grid-2" },
            field("edit-singles", "Singles Rating", singlesInput, "2.000–8.000"),
            field("edit-doubles", "Doubles Rating", doublesInput, "2.000–8.000"),
          ),
          singlesNote,
          doublesNote,
          field("edit-reason", "Reason for a rating change", reasonInput),
        ),
        ),
        h("p", { class: "event-registration-partner-tip" }, icon("info"),
          h("span", {}, "Existing registrations keep their original player names. A reason is required when changing a rating."),
        ),
        error,
      ),
      onConfirm: async () => {
        error.hidden = true;
        if (!loaded) return fail(error, new Error("The guest could not be loaded. Close and try again."));
        const rating = (input) => {
          const raw = input.value.trim();
          if (!raw) return { value: null };
          const n = Number(raw);
          return /^\d(\.\d{1,3})?$/.test(raw) && n >= 2 && n <= 8 ? { value: n } : { invalid: true };
        };
        const singles = rating(singlesInput);
        const doubles = rating(doublesInput);
        if (singles.invalid || doubles.invalid) {
          return fail(error, new Error("Enter a rating from 2.000 to 8.000 with at most three decimals."));
        }
        const duprId = duprInput.value.trim().toUpperCase();
        if (duprId && !/^[A-Z0-9]{1,32}$/.test(duprId)) {
          return fail(error, new Error("DUPR ID must contain 1 to 32 letters or numbers."));
        }
        const changed = (value, side) => value != null && Number(value) !== Number(side?.points ?? Number.NaN);
        const reason = reasonInput.value.trim();
        if ((changed(singles.value, loaded.singles) || changed(doubles.value, loaded.doubles)) && reason.length < 3) {
          return fail(error, new Error("Give a reason of at least 3 characters for changing a rating."));
        }
        const payload = {
          p_participant_id: guestSelect.value,
          p_name: nameInput.value.trim(),
          p_mobile: mobileInput.value.trim() || null,
          p_gender: genderSelect.value || null,
          p_birth_date: dobInput.value || null,
          p_dupr_id: duprId || null,
          p_singles_rating: singles.value,
          p_doubles_rating: doubles.value,
          p_reason: reason || null,
        };
        const fingerprint = JSON.stringify(payload);
        if (intent?.fingerprint !== fingerprint) intent = { fingerprint, key: api.newKey() };
        try {
          await api.rpc("update_event_guest", { ...payload, p_key: intent.key });
          toast("Guest updated.", { tone: "success" });
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
    // The guest's stored ratings (assessed when the guest was added): registering uses the one for the division's format.
    let ratingRows = [];
    try {
      ratingRows = await api.rpc("guest_participant_ratings", { p_event_id: event.id }) ?? [];
    } catch {
      ratingRows = [];
    }
    const ratingOf = (participantId, discipline) =>
      ratingRows.find((r) => r.participant_id === participantId && r.discipline === discipline)?.points ?? null;
    const ratingNote = (participantId, format) => {
      const value = ratingOf(participantId, format);
      return value == null
        ? `Unrated for ${format}. May register in Beginner divisions starting at Beginner Low.`
        : `${format === "doubles" ? "Doubles" : "Singles"} rating ${Number(value).toFixed(3)} (assessed when the guest was added).`;
    };
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
    // The partner list belongs to the chosen division and the chosen guest: a doubles division needs a partner (members who
    // are eligible for it, and guests without an entry), the guest being registered is never offered, and a singles
    // division has no partner. The database repeats every check when the guest is registered.
    const guestSelect = select(
      "guest-player",
      guests.filter((p) =>
        !change || change.kind !== "move" ||
        p.id === source.guest_participant_id
      ).map((p) => [p.id, p.display_name]),
      source?.guest_participant_id ?? guests[0].id,
    );
    const divisionSelect = select(
      "guest-division",
      divisions.map((d) => [d.id, d.name]),
      divisions.some((d) => d.id === divisionId) ? divisionId : divisions[0]?.id,
    );
    const partnerSelect = h("select", { id: "guest-partner", name: "guest-partner", hidden: true },
      h("option", { value: "" }, "Loading partners…"));
    const partnerTerm = searchControl({
      id: "guest-partner-search", class: "input", maxlength: 60,
      placeholder: "Partner's name or member ID", "aria-label": "Find doubles partner",
    });
    const partnerStatus = h("p", { class: "sub form-help-text", role: "status" }, "Type at least 2 letters or numbers.");
    const partnerResults = h("div", { class: "staff-results", role: "radiogroup", "aria-label": "Eligible doubles partners" });
    const partnerPreview = h("div", { class: "partner-preview-host" });
    function showPartner() {
      const selected = partners.find((p) => p.id === partnerSelect.value);
      partnerPreview.replaceChildren();
      partnerResults.hidden = Boolean(selected);
      partnerStatus.hidden = Boolean(selected);
      if (selected) partnerPreview.append(h("div", { class: "staff-selected-card" },
        h("div", { class: "member-meta" },
          h("strong", { class: "member-name" }, selected.display_name),
          h("span", { class: "sub member-subtext" }, selected.member_no || "Guest"),
        ),
        button({ label: "Change", icon: "refresh", variant: "ghost", onClick: () => {
          partnerSelect.value = "";
          partnerResults.replaceChildren();
          partnerStatus.textContent = "Type at least 2 letters or numbers.";
          showPartner();
          syncPartnerFields();
          partnerTerm.focus();
        } }),
      ));
    }
    function searchPartners() {
      partnerSelect.value = "";
      showPartner();
      syncPartnerFields();
      const term = partnerTerm.value.trim().toLocaleLowerCase();
      partnerResults.replaceChildren();
      if (partnerProblem) {
        partnerStatus.textContent = partnerProblem;
        return;
      }
      if (term.length < 2) {
        partnerStatus.textContent = "Type at least 2 letters or numbers.";
        return;
      }
      const found = partners.filter((p) => `${p.display_name} ${p.member_no ?? ""}`.toLocaleLowerCase().includes(term));
      partnerStatus.textContent = found.length ? `${found.length} found. Choose one below.` : "No eligible partners match.";
      partnerResults.replaceChildren(...found.map((p) => h("label", { class: "staff-result" },
        h("input", { type: "radio", name: "guest-partner-result", value: p.id, onChange: () => {
          partnerSelect.value = p.id;
          showPartner();
          syncPartnerFields();
        } }),
        h("span", { class: "member-meta" },
          h("strong", { class: "member-name" }, p.display_name),
          h("span", { class: "sub member-subtext" }, p.member_no || "Guest"),
        ),
        badge(p.is_guest ? "Guest" : "Member", p.is_guest ? "neutral" : "info"),
      )));
    }
    partnerTerm.addEventListener("keydown", (e) => {
      if (e.key === "Enter") { e.preventDefault(); searchPartners(); }
    });
    const partnerRatingNote = h("p", { class: "sub field-hint", hidden: true });
    const guestRatingNote = h("p", { class: "sub field-hint" });
    const partnerPanel = h(
      "div",
      { class: "form-section event-registration-partner-panel" },
      h(
        "div",
        { class: "event-registration-partner-head" },
        h("div", { class: "event-registration-partner-label" }, icon("userPlus"), h("strong", {}, "Doubles Partner *")),
        badge("Required", "warning"),
      ),
      partnerSelect,
      h("div", { class: "guest-search-row" }, partnerTerm,
        button({ label: "Search", icon: "search", variant: "secondary", onClick: searchPartners }),
      ),
      partnerStatus,
      partnerResults,
      partnerPreview,
      partnerRatingNote,
      h("p", { class: "event-registration-partner-tip" }, icon("info"),
        h("span", {}, "Both players must fit this division. Unrated players are allowed in Beginner divisions starting at Beginner Low. Only eligible partners without an entry are listed."),
      ),
    );
    let partners = [];
    let partnerProblem = "";
    let partnerLoad = 0;
    const memberParticipantIds = new Map();
    let wantedPartner = defaultPartner;
    const formatOf = () => divisions.find((d) => d.id === divisionSelect.value)?.format ?? "singles";
    const isDoubles = () => formatOf() === "doubles";
    const partnerIsGuest = () => isDoubles() && partners.find((x) => x.id === partnerSelect.value)?.is_guest === true;
    const syncPartnerFields = () => {
      partnerPanel.hidden = !isDoubles();
      partnerRatingNote.hidden = !partnerIsGuest();
      if (partnerIsGuest()) partnerRatingNote.textContent = ratingNote(partnerSelect.value, "doubles");
      guestRatingNote.textContent = ratingNote(guestSelect.value, formatOf());
      if (partnerProblem) partnerStatus.textContent = partnerProblem;
    };
    async function loadPartners() {
      const request = ++partnerLoad;
      partnerProblem = "";
      partners = [];
      partnerResults.replaceChildren();
      partnerPreview.replaceChildren();
      partnerTerm.value = "";
      partnerStatus.textContent = "Type at least 2 letters or numbers.";
      if (!isDoubles()) {
        partners = [];
        partnerSelect.replaceChildren(h("option", { value: "" }, "No partner (singles)"));
        partnerSelect.value = "";
        syncPartnerFields();
        return;
      }
      partnerSelect.replaceChildren(h("option", { value: "" }, "Loading partners…"));
      try {
        const args = {
          p_division_id: divisionSelect.value,
          p_guest_participant_id: guestSelect.value,
        };
        const [rows, eligibility] = await Promise.all([
          api.rpc("eligible_event_partners", args),
          api.rpc("guest_division_eligibility", args),
        ]);
        if (request !== partnerLoad) return;
        partnerProblem = eligibility?.eligible === false ? eligibility.reason || "Choose a division that fits this guest." : "";
        partners = partnerProblem ? [] : (rows ?? []).map((p) => ({ ...p, participant_id: p.id, id: p.id ?? `member:${p.member_id}` }));
      } catch (e) {
        if (request !== partnerLoad) return;
        partnerProblem = ["22023", "42501"].includes(e?.code)
          ? e.cause?.message || e.message
          : "Partner eligibility could not be checked. Change the guest or division to retry.";
        partners = [];
      }
      partnerSelect.replaceChildren(
        h("option", { value: "" }, partners.length ? "Choose a partner" : "No eligible partner available"),
        ...partners.map((x) => h("option", { value: x.id }, `${x.display_name} · ${x.member_no || "Guest"}`)),
      );
      partnerSelect.value = partners.some((x) => x.id === wantedPartner) ? wantedPartner : "";
      showPartner();
      syncPartnerFields();
    }
    divisionSelect.addEventListener("change", () => {
      wantedPartner = "";
      loadPartners();
    });
    guestSelect.addEventListener("change", () => {
      wantedPartner = partnerSelect.value;
      loadPartners();
    });
    partnerSelect.addEventListener("change", syncPartnerFields);
    loadPartners();
    return openModal({
      title: change
        ? (change.kind === "move" ? "Move Guest Entry" : "Replace Players")
        : "Register Guest",
      icon: "trophy",
      eyebrow: "Event Registration",
      description: change
        ? "The original registration is kept in history. Fees use the current event price. Payment credit follows the same guest payer; a replacement payer needs their own payment."
        : event.name,
      confirmLabel: change ? "Save Change" : "Register Guest",
      body: h(
        "div",
        { class: "stack guest-registration-form" },
        h("div", { class: "event-registration-summary-card" },
          h("div", { class: "event-registration-summary-header" },
            h("div", { class: "event-registration-summary-title-col" },
              h("span", { class: "eyebrow" }, "Tournament Division"),
              h("strong", { class: "event-registration-division-title" }, event.name),
            ),
            h("div", { class: "event-registration-summary-badges" },
              Number(event.fee) > 0 ? badge(formatMoney(event.fee), "primary") : badge("Free Entry", "success"),
              badge("Admin Entry", "info"),
            ),
          ),
          field("guest-division", "Division *", divisionSelect),
        ),
        h(
          "div",
          { class: "form-section event-registration-partner-panel" },
          h(
            "div",
            { class: "event-registration-partner-head" },
            h("div", { class: "event-registration-partner-label" }, icon("user"), h("strong", {}, "Guest & Assessment")),
            badge("Required", "warning"),
          ),
          field("guest-player", "Guest *", guestSelect),
          guestRatingNote,
        ),
        partnerPanel,
        h("p", { class: "event-registration-partner-tip" }, icon("info"),
          h("span", {}, "Admins may register guests while registration is open or closed. Eligibility, capacity and payment rules apply."),
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
          if (isDoubles() && !form.get("guest-partner")) {
            return fail(error, new Error("Choose a doubles partner."));
          }
          const selectedPartner = partners.find((p) => p.id === form.get("guest-partner"));
          let partnerId = isDoubles() ? form.get("guest-partner") || null : null;
          if (isDoubles() && selectedPartner?.member_id && !selectedPartner.participant_id) {
            if (!memberParticipantIds.has(selectedPartner.member_id)) memberParticipantIds.set(selectedPartner.member_id, api.newKey());
            const participant = await api.rpc("ensure_event_member_participant", {
              p_id: memberParticipantIds.get(selectedPartner.member_id),
              p_event_id: event.id,
              p_member_id: selectedPartner.member_id,
            });
            partnerId = participant.id;
          }
          const request = {
            p_id: key,
            p_division_id: form.get("guest-division"),
            p_participant_id: form.get("guest-player"),
            p_rank_id: null,
            p_partner_participant_id: partnerId,
            p_partner_rank_id: null,
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
    editGuest,
    addExisting,
    register,
    payment,
    change: (row, kind) => register(row.division_id, { row, kind }),
  };
}
