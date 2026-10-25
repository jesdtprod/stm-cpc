// Account pages (PLAN 3.4): sign in, forced password change, profile completion, pending approval.
// All dynamic text goes through h()/textContent (see ui.js), so nothing here can inject markup.
import {
  adminHero,
  attachPagePattern,
  badge,
  button,
  calendarDropdown,
  createCourtWatermarkSvg,
  field,
  h,
  icon,
  pageHeader,
  searchableSelect,
  selectControl,
  setupConvexPatternCanvas,
  skeleton,
  toast,
  withPending,
} from "./ui.js";
import {
  localPasswordProblems,
  problemMessages,
} from "./lib/password-hints.js";
import { suggestNameParts } from "./lib/names.js";
import {
  AVATAR_TYPES,
  avatarFileError,
  avatarImage,
  resizeToJpeg,
  signedAvatarUrls,
} from "./lib/avatar.js";
import { ulid } from "./lib/ulid.js";

const NCR_REGION = "130000000";

/** Where a signed-in user belongs: the gate page, or the profile page when it is the next step, or home. */
export function nextHash(state) {
  if (state.status !== "signed_in") return "#/signin";
  if (state.gate === "password_change") return "#/password";
  if (state.gate === "profile_update") return "#/profile";
  if (state.gate === "pending") {
    return state.access && !state.access.profile_complete &&
        state.access.status !== "pending_approval"
      ? "#/profile"
      : "#/pending";
  }
  return "#/";
}

const inputValue = (wrapper) => wrapper.querySelector("input,select").value;

function errorBox() {
  return h("p", {
    class: "field-error form-error",
    role: "alert",
    tabindex: "-1",
    hidden: true,
  });
}
function showError(box, messages) {
  const list = [].concat(messages).filter(Boolean);
  box.replaceChildren(...list.flatMap((m, i) => (i ? [h("br"), m] : [m])));
  box.hidden = list.length === 0;
  if (list.length) box.focus();
}

export function createAccountPages(
  { session, api, client, authApi, getAccessToken, renderTurnstile },
) {
  const go = (hash) => {
    if (location.hash !== hash) location.hash = hash;
  };

  // The page both sign-in and sign-up use: the home hero look, text on the left and the form card on the right.
  function authShell({ titleLead, subtitle, card, wide = false }) {
    // The same background as the home page: the court pattern canvas that follows the pointer, and the court blueprint.
    const canvasEl = h("canvas", {
      class: "cpc-hero-canvas",
      "aria-hidden": "true",
    });
    const watermarkEl = createCourtWatermarkSvg();

    const flank = (side, first, second) =>
      h(
        "div",
        { class: `cpc-top-flank cpc-top-flank-${side}` },
        h("img", {
          src: `icons/${first}.png`,
          alt: "",
          class: `cpc-top-${first} cpc-top-${first}-${side}`,
        }),
        h("img", {
          src: `icons/${second}.png`,
          alt: "",
          class: `cpc-top-${second} cpc-top-${second}-${side}`,
        }),
      );

    // The same structure and classes as the home page hero (and so the same fonts and sizes): the text on the left,
    // where the home page has its headline, and the sign-in form on the right, where the home page has the phone.
    const containerEl = h(
      "div",
      { class: `auth-page-container cpc-hero${wide ? " auth-wide" : ""}` },
      canvasEl,
      watermarkEl,
      h(
        "div",
        { class: "cpc-landing-container" },
        h(
          "div",
          { class: "cpc-hero-grid auth-split" },
          h(
            "div",
            { class: "cpc-hero-content" },
            h(
              "div",
              { class: "cpc-hero-brand-top" },
              flank("left", "paddle", "ball"),
              h("img", {
                class: "cpc-hero-logo cpc-top-logo",
                src: "icons/cpc-logo-256.webp",
                alt: "Capitol Pickleball Club",
                width: "72",
                height: "72",
              }),
              flank("right", "ball", "paddle"),
            ),
            // Desktop only, at the top of the text: two crossed paddles, each with its own ball.
            h(
              "div",
              { class: "auth-showcase", "aria-hidden": "true" },
              ...["a", "b"].map((side) =>
                h(
                  "div",
                  { class: `auth-showcase-unit auth-showcase-unit-${side}` },
                  h("img", {
                    class: "auth-showcase-paddle",
                    src: "icons/paddle-480.webp",
                    alt: "",
                  }),
                  h("img", {
                    class: "auth-showcase-ball",
                    src: "icons/ball-240.webp",
                    alt: "",
                  }),
                )
              ),
            ),
            h(
              "div",
              { class: "cpc-hero-badge" },
              icon("trophy"),
              "Province of Sultan Kudarat’s Pickleball Court",
            ),
            h(
              "h1",
              { class: "cpc-hero-title", id: "page-title", tabindex: "-1" },
              titleLead,
              h(
                "span",
                { class: "cpc-hero-title-accent" },
                "Capitol Pickleball Club",
              ),
            ),
            h(
              "p",
              { class: "cpc-hero-subtitle" },
              subtitle,
            ),
          ),
          h(
            "div",
            { class: "auth-form-col" },
            card,
          ),
        ),
      ),
    );

    setupConvexPatternCanvas(canvasEl, containerEl, watermarkEl);
    return containerEl;
  }

  // ---------------------------------------------------------------- sign in
  function signInPage() {
    const state = session.getState();
    if (state.status === "signed_in") {
      queueMicrotask(() => go(nextHash(state)));
      return h("div", { class: "page" });
    }

    let token = null;
    let widget = null;
    const box = h("div", { class: "turnstile-box" });
    renderTurnstile(box, {
      action: "member-signin",
      onToken: (t) => (token = t),
      onExpire: () => (token = null),
      onError: (m) => showError(error, m),
    }).then((w) => (widget = w)).catch((e) => showError(error, e.message));

    const memberId = field({
      id: "signin-id",
      label: "Member ID or email",
      required: true,
      placeholder: "CPC-2026-00001 or your email",
      iconLeading: "idCard",
    });
    const idInput = memberId.querySelector("input");
    idInput.setAttribute("autocomplete", "username");
    idInput.setAttribute("autocapitalize", "none");
    idInput.setAttribute("spellcheck", "false");
    const password = field({
      id: "signin-password",
      label: "Password",
      type: "password",
      required: true,
      placeholder: "••••••••••••",
      iconLeading: "keyRound",
    });
    const pwInput = password.querySelector("input");
    pwInput.setAttribute("autocomplete", "current-password");
    const error = errorBox();

    const submit = button({
      label: "Sign in",
      variant: "primary",
      type: "submit",
    });
    const form = h(
      "form",
      { class: "stack", novalidate: true, onSubmit: (e) => e.preventDefault() },
      memberId,
      password,
      box,
      error,
      h("div", { class: "actions" }, submit),
    );
    form.addEventListener(
      "submit",
      withPending(submit, async () => {
        showError(error, []);
        const id = inputValue(memberId).trim();
        const pw = inputValue(password);
        if (!id || !pw) {
          return showError(
            error,
            "Enter your member ID or email and your password.",
          );
        }
        if (!token) {
          return showError(error, "Please complete the security check first.");
        }
        const used = token;
        token = null;
        try {
          await session.signIn({ memberId: id, password: pw }, used);
          pwInput.value = "";
          go(nextHash(session.getState()));
        } catch (e) {
          showError(
            error,
            e.code ? e.message : "Sign-in failed. Please try again.",
          );
        } finally {
          widget?.reset(); // the token is single use
        }
      }),
    );

    return authShell({
      titleLead: "Sign In to ",
      subtitle:
        "Use your member ID or email and your password to manage court bookings, ranks, and event registrations.",
      card: h(
        "div",
        { class: "card auth-card" },
        h(
          "div",
          { class: "auth-card-head" },
          h(
            "span",
            { class: "badge-icon", "aria-hidden": "true" },
            icon("logIn"),
          ),
          h(
            "div",
            { class: "auth-card-head-copy" },
            h("div", { class: "eyebrow" }, "Member Access"),
            h("h2", { class: "card-title" }, "Sign In"),
            h(
              "p",
              { class: "card-subtitle muted" },
              "Enter your member ID or email to access your account.",
            ),
          ),
        ),
        form,
        h(
          "div",
          { class: "auth-card-footer" },
          "Not a member yet? ",
          h(
            "a",
            { href: "#/signup", class: "auth-signup-link" },
            "Create an account / Join the club",
          ),
          ".",
        ),
      ),
    });
  }

  // ---------------------------------------------------------------- password
  function passwordPage() {
    const state = session.getState();
    const forced = Boolean(state.access?.must_change_password);
    const next = field({
      id: "pw-new",
      label: "New password",
      type: "password",
      required: true,
      hint: "At least 12 characters. A few unrelated words works well.",
    });
    const again = field({
      id: "pw-confirm",
      label: "Repeat the new password",
      type: "password",
      required: true,
    });
    next.querySelector("input").setAttribute("autocomplete", "new-password");
    again.querySelector("input").setAttribute("autocomplete", "new-password");
    const error = errorBox();
    const submit = button({
      label: "Save password",
      variant: "primary",
      type: "submit",
      icon: "check",
    });
    const form = h(
      "form",
      { class: "stack", novalidate: true, onSubmit: (e) => e.preventDefault() },
      next,
      again,
      error,
      h("div", { class: "actions" }, submit),
    );
    form.addEventListener(
      "submit",
      withPending(submit, async () => {
        showError(error, []);
        const pw = inputValue(next);
        const problems = localPasswordProblems(pw, inputValue(again));
        if (problems.length) return showError(error, problems);
        try {
          await authApi.changePassword(pw, await getAccessToken());
          next.querySelector("input").value = "";
          again.querySelector("input").value = "";
          await session.refresh();
          toast("Password changed.");
          go(nextHash(session.getState()));
        } catch (e) {
          if (e.code === "weak_password") {
            showError(error, problemMessages(e.problems));
          } else if (e.code === "sign_in_again") {
            showError(error, e.message);
            error.append(
              " ",
              h("a", {
                href: "#/signin",
                onClick: () => session.signOut("manual"),
              }, "Sign in again"),
            );
          } else {showError(
              error,
              e.message || "The password could not be changed.",
            );}
        }
      }),
    );

    const pwPage = h("div", {
      class: "page admin-dashboard admin-members-page profile-page",
    });
    attachPagePattern(pwPage);
    pwPage.append(
      adminHero({
        title: forced ? "Choose a new password" : "Change password",
        chip: forced ? "One more step" : "Account Security",
        description: forced
          ? "For your security, replace the password you were given before you continue."
          : "Pick a strong new password for your account.",
        actions: !forced
          ? [
            button({
              label: "My profile",
              icon: "user",
              variant: "secondary",
              onClick: () => go("#/profile"),
            }),
          ]
          : [],
      }),
      h(
        "div",
        { class: "member-panel profile-section-card profile-password-card" },
        h(
          "div",
          { class: "profile-section-head" },
          h(
            "span",
            { class: "section-icon", "aria-hidden": "true" },
            icon("keyRound"),
          ),
          h(
            "div",
            { class: "profile-section-copy" },
            h("h2", { class: "profile-section-title" }, "Update Password"),
            h(
              "p",
              { class: "profile-section-sub muted" },
              "Use at least 12 characters. Avoid reusing your temporary password or birth date.",
            ),
          ),
        ),
        form,
      ),
    );
    return pwPage;
  }

  // ---------------------------------------------------------------- profile
  const options = (rows, placeholder, selected) => [
    h("option", { value: "" }, placeholder),
    ...rows.map((r) =>
      h("option", {
        value: r.code,
        selected: r.code === selected ? true : null,
      }, r.name)
    ),
  ];

  async function areaList(level, parentCode) {
    return await api.read((c) => {
      let q = c.from("psgc_areas").select("code,name").eq("level", level).order(
        "name",
      );
      if (parentCode) q = q.eq("parent_code", parentCode);
      return q;
    });
  }

  /** Provinces, plus any region whose cities have no province (Metro Manila and a few others). */
  async function provinceChoices() {
    const [provinces, direct] = await Promise.all([
      areaList("province"),
      api.read((c) =>
        c.from("psgc_areas").select("parent_code").eq("level", "city_muni").is(
          "province_code",
          null,
        )
      ),
    ]);
    const regionCodes = [...new Set(direct.map((r) => r.parent_code))];
    const regions = regionCodes.length
      ? await api.read((c) =>
        c.from("psgc_areas").select("code,name").eq("level", "region").in(
          "code",
          regionCodes,
        )
      )
      : [];
    const named = regions.map((r) => ({
      code: r.code,
      name: r.code === NCR_REGION ? "Metro Manila" : r.name,
    }));
    return [...provinces, ...named].sort((a, b) =>
      a.name.localeCompare(b.name)
    );
  }

  const SUFFIXES = ["Jr.", "Sr.", "II", "III", "IV", "V"];
  const GENDERS = [["male", "Male"], ["female", "Female"]];

  /** A dropdown field (the shared list component, with search) with a blank first choice. `choices` is a list of [value, label]. */
  function choiceField(id, label, choices, selected, blankLabel) {
    const node = searchableSelect({
      id,
      label,
      placeholder: blankLabel,
      value: selected ?? "",
      options: [
        { value: "", label: blankLabel },
        ...choices.map(([value, text]) => ({ value, label: text })),
      ],
    });
    // `sel.value` keeps working for the code that reads the chosen value
    return { sel: node, node };
  }

  const formatDate = (iso) => {
    if (!iso) return "";
    const [y, m, d] = iso.split("-").map(Number);
    return new Date(Date.UTC(y, m - 1, d)).toLocaleDateString("en-PH", {
      year: "numeric",
      month: "long",
      day: "numeric",
      timeZone: "UTC",
    });
  };

  function profilePage() {
    const state = session.getState();
    if (state.gate === "password_change") {
      queueMicrotask(() => go("#/password"));
      return h("div", { class: "page" });
    }
    const me = state.access ?? {};
    // Members imported with only a display name get a suggested split to check. It is only saved if they
    // save the form.
    const guess = !me.first_name && !me.last_name
      ? suggestNameParts(me.display_name)
      : null;

    // ---- name
    const lastName = field({
      id: "pf-last",
      label: "Last name",
      value: me.last_name ?? guess?.last ?? "",
      required: true,
      iconLeading: "user",
      hint: guess?.last
        ? "Suggested from your name: please check it."
        : undefined,
    });
    const firstName = field({
      id: "pf-first",
      label: "First name",
      value: me.first_name ?? guess?.first ?? "",
      required: true,
      iconLeading: "user",
    });
    const middleName = field({
      id: "pf-middle",
      label: "Middle name (optional)",
      value: me.middle_name ?? "",
    });
    const suffix = choiceField(
      "pf-suffix",
      "Extension (optional)",
      SUFFIXES.map((x) => [x, x]),
      me.suffix ?? guess?.suffix,
      "None",
    );
    const display = field({
      id: "pf-name",
      label: "Display name",
      value: me.display_name ?? "",
      required: true,
      iconLeading: "idCard",
      hint: "How your name appears in the app and on brackets.",
    });
    const gender = choiceField(
      "pf-gender",
      "Gender (optional)",
      GENDERS,
      me.gender,
      "Prefer not to say",
    );
    const metaBirthDd = h("dd", {}, formatDate(me.date_of_birth) || "—");
    const birth = calendarDropdown({
      id: "pf-birth",
      label: "Date of birth",
      value: me.date_of_birth ?? "",
      min: "1920-01-01",
      max: new Date().toISOString().slice(0, 10),
      defaultView: me.date_of_birth ? me.date_of_birth.slice(0, 7) : "1990-01",
      hint: "Select your date of birth.",
      onChange: (iso) => {
        metaBirthDd.textContent = formatDate(iso) || "—";
      },
    });
    for (const f of [lastName, firstName, middleName]) {
      f.querySelector("input").setAttribute("maxlength", "60");
    }
    firstName.querySelector("input").setAttribute("autocomplete", "given-name");
    lastName.querySelector("input").setAttribute("autocomplete", "family-name");
    middleName.querySelector("input").setAttribute(
      "autocomplete",
      "additional-name",
    );

    // ---- contact
    const mobile = field({
      id: "pf-mobile",
      label: "Mobile number",
      value: me.mobile ?? "",
      required: true,
      iconLeading: "phone",
      hint: "For example 09171234567",
      placeholder: "09171234567",
    });
    mobile.querySelector("input").setAttribute("autocomplete", "tel");
    mobile.querySelector("input").setAttribute("inputmode", "tel");
    const email = field({
      id: "pf-email",
      label: "Email",
      type: "email",
      value: me.email ?? "",
      required: true,
      iconLeading: "mail",
      hint:
        "Required. The club uses it to reach you and you can sign in with it.",
    });
    email.querySelector("input").setAttribute("autocomplete", "email");

    // ---- emergency contact
    const emName = field({
      id: "pf-em-name",
      label: "Emergency contact name (optional)",
      value: me.emergency_name ?? "",
      iconLeading: "user",
    });
    const emRel = field({
      id: "pf-em-rel",
      label: "Relationship (optional)",
      value: me.emergency_relationship ?? "",
      placeholder: "Parent, spouse, friend",
    });
    const emPhone = field({
      id: "pf-em-phone",
      label: "Emergency contact number (optional)",
      value: me.emergency_phone ?? "",
      iconLeading: "phone",
    });
    emPhone.querySelector("input").setAttribute("inputmode", "tel");

    // ---- address
    const street = field({
      id: "pf-street",
      label: "House number and street (optional)",
      value: me.street_line ?? "",
      iconLeading: "home",
    });
    const selectField = (id, label) => {
      const sel = selectControl({
        class: "input",
        id,
        name: id,
        required: true,
        disabled: true,
      });
      return {
        sel,
        node: h(
          "div",
          { class: "field" },
          h("label", { for: id }, `${label} *`),
          sel,
        ),
      };
    };
    const province = selectField("pf-province", "Province or Metro Manila");
    const city = selectField("pf-city", "City or municipality");
    const barangay = selectField("pf-barangay", "Barangay");
    const error = errorBox();

    const addressSkeleton = h(
      "div",
      { class: "profile-address-skeleton", "aria-hidden": "true" },
      skeleton({ height: "44px" }),
      h(
        "div",
        { class: "profile-form-grid is-three-col" },
        skeleton({ height: "44px" }),
        skeleton({ height: "44px" }),
        skeleton({ height: "44px" }),
      ),
    );
    const addressFields = h(
      "div",
      { class: "profile-address-fields", hidden: true },
      street,
      h(
        "div",
        { class: "profile-form-grid is-three-col" },
        province.node,
        city.node,
        barangay.node,
      ),
    );

    function fill(select, rows, placeholder, selected) {
      select.replaceChildren(...options(rows, placeholder, selected));
      select.disabled = rows.length === 0;
    }
    async function loadCities(code, selected) {
      barangay.sel.replaceChildren(...options([], "Choose a city first"));
      barangay.sel.disabled = true;
      if (!code) return fill(city.sel, [], "Choose a province first");
      fill(
        city.sel,
        await areaList("city_muni", code),
        "Choose a city or municipality",
        selected,
      );
    }
    async function loadBarangays(code, selected) {
      if (!code) return fill(barangay.sel, [], "Choose a city first");
      fill(
        barangay.sel,
        await areaList("barangay", code),
        "Choose a barangay",
        selected,
      );
    }
    const startProvince = me.province_code ?? me.region_code ?? "";
    (async () => {
      try {
        fill(
          province.sel,
          await provinceChoices(),
          "Choose a province",
          startProvince,
        );
        if (startProvince) {
          await loadCities(startProvince, me.city_muni_code);
          if (me.city_muni_code) {
            await loadBarangays(me.city_muni_code, me.barangay_code);
          }
        } else await loadCities("");
      } catch {
        showError(
          error,
          "The address list could not be loaded. Check your connection and reload.",
        );
      } finally {
        addressSkeleton.hidden = true;
        addressFields.hidden = false;
      }
    })();
    province.sel.addEventListener(
      "change",
      () =>
        loadCities(province.sel.value).catch(() =>
          showError(error, "Could not load cities.")
        ),
    );
    city.sel.addEventListener(
      "change",
      () =>
        loadBarangays(city.sel.value).catch(() =>
          showError(error, "Could not load barangays.")
        ),
    );

    // ---- photo (Supabase Storage, private). The picture is cropped and shrunk here before it is uploaded.
    let hasPhoto = Boolean(me.avatar_path);
    const photoFace = h("span", {
      class: "avatar-lg profile-avatar-ring",
      "aria-hidden": "true",
    });
    const dropzoneTitle = h(
      "span",
      { class: "profile-upload-title" },
      hasPhoto ? "Replace current photo" : "Click or drop photo here",
    );
    const showFace = (url) => {
      hasPhoto = Boolean(url);
      dropzoneTitle.textContent = hasPhoto
        ? "Replace current photo"
        : "Click or drop photo here";
      if (photoRemove) photoRemove.disabled = !hasPhoto;
      photoFace.replaceChildren(
        avatarImage(url, inputValue(display).trim() || me.display_name),
      );
    };
    const photoNote = h(
      "p",
      {
        class: "muted profile-photo-note",
        id: "pf-photo-note",
        "aria-live": "polite",
      },
      "Square crop · Max 3 MB · Private storage",
    );
    const photoInput = h("input", {
      class: "sr-only profile-photo-input",
      id: "pf-photo",
      type: "file",
      accept: AVATAR_TYPES.join(","),
      "aria-describedby": "pf-photo-note",
    });
    const photoUploadBtn = button({
      label: "Upload",
      icon: "upload",
      variant: "secondary",
      size: "sm",
      ariaLabel: "Upload photo",
      onClick: () => photoInput.click(),
    });
    const photoRemove = button({
      label: "Remove",
      icon: "trash",
      variant: "danger",
      size: "sm",
      ariaLabel: "Remove photo",
      disabled: !hasPhoto,
      onClick: async () => {
        photoRemove.disabled = true;
        photoUploadBtn.disabled = true;
        photoDropzone.disabled = true;
        avatarQuickBtn.disabled = true;
        photoInput.disabled = true;
        photoNote.textContent = "Removing photo...";
        try {
          await api.rpc("set_my_avatar", { p_path: null });
          showFace(null);
          photoInput.value = "";
          photoNote.textContent = "Photo removed.";
          toast("Photo removed.", { tone: "info" });
          await session.refresh();
        } catch {
          photoNote.textContent = "The photo could not be removed. Try again.";
          photoRemove.disabled = !hasPhoto;
        } finally {
          photoUploadBtn.disabled = false;
          photoDropzone.disabled = false;
          avatarQuickBtn.disabled = false;
          photoInput.disabled = false;
        }
      },
    });
    const avatarQuickBtn = h(
      "button",
      {
        type: "button",
        class: "profile-avatar-edit-btn",
        "aria-label": "Upload new profile photo",
        title: "Upload new profile photo",
        onClick: () => photoInput.click(),
      },
      icon("upload"),
    );
    const photoDropzone = h(
      "button",
      {
        type: "button",
        class: "profile-upload-dropzone",
        onClick: () => photoInput.click(),
        onDragover: (e) => {
          e.preventDefault();
          photoDropzone.classList.add("is-dragover");
        },
        onDragleave: () => photoDropzone.classList.remove("is-dragover"),
        onDrop: (e) => {
          e.preventDefault();
          photoDropzone.classList.remove("is-dragover");
          const file = e.dataTransfer?.files?.[0];
          if (file) handlePhotoFile(file);
        },
      },
      h(
        "span",
        { class: "profile-upload-icon", "aria-hidden": "true" },
        icon("upload"),
      ),
      h(
        "span",
        { class: "profile-upload-copy" },
        dropzoneTitle,
        h(
          "span",
          { class: "profile-upload-sub" },
          "JPG, PNG or WebP up to 3 MB",
        ),
      ),
    );
    showFace(null);
    if (me.avatar_path) {
      signedAvatarUrls(client, [me.avatar_path]).then((urls) =>
        showFace(urls.get(me.avatar_path) ?? null)
      );
    }

    async function handlePhotoFile(file) {
      if (!file) return;
      const fileError = avatarFileError(file);
      if (fileError) {
        photoNote.textContent = fileError;
        photoInput.value = "";
        return;
      }
      photoInput.disabled = true;
      photoUploadBtn.disabled = true;
      photoDropzone.disabled = true;
      avatarQuickBtn.disabled = true;
      photoRemove.disabled = true;
      photoNote.textContent = "Saving your photo...";
      try {
        const blob = await resizeToJpeg(file);
        const ids = session.getState().profile ?? {};
        const path = `${ids.org_id}/${ids.profile_id}/${ulid()}.jpg`;
        const { error: upErr } = await client.storage.from("avatars").upload(
          path,
          blob,
          { contentType: "image/jpeg", upsert: false },
        );
        if (upErr) throw upErr;
        await api.rpc("set_my_avatar", { p_path: path });
        showFace(URL.createObjectURL(blob));
        photoNote.textContent = "Photo saved.";
        toast("Photo saved.", { tone: "success" });
        await session.refresh();
      } catch {
        photoNote.textContent =
          "The photo could not be saved. Try another picture.";
        photoRemove.disabled = !hasPhoto;
      } finally {
        photoInput.disabled = false;
        photoUploadBtn.disabled = false;
        photoDropzone.disabled = false;
        avatarQuickBtn.disabled = false;
        photoRemove.disabled = !hasPhoto;
        photoInput.value = "";
      }
    }

    photoInput.addEventListener("change", () => {
      handlePhotoFile(photoInput.files?.[0]);
    });

    const identityName = h(
      "h2",
      { class: "profile-identity-name" },
      me.display_name || "Club Member",
    );
    display.querySelector("input").addEventListener("input", () => {
      identityName.textContent = inputValue(display).trim() ||
        me.display_name || "Club Member";
    });

    const identityCard = h(
      "aside",
      { class: "member-panel profile-identity-card" },
      h(
        "div",
        { class: "profile-identity-top" },
        h(
          "div",
          { class: "profile-avatar-stage" },
          photoFace,
          avatarQuickBtn,
        ),
        identityName,
        h(
          "span",
          { class: "profile-member-id" },
          me.member_no || "CPC Member",
        ),
        h(
          "div",
          { class: "profile-identity-badges" },
          badge(
            me.status === "active" ? "Active Member" : (me.status || "Pending"),
            me.status === "active" ? "success" : "warning",
          ),
          badge(
            me.profile_complete ? "Verified Profile" : "Setup Required",
            me.profile_complete ? "info" : "warning",
          ),
        ),
      ),
      h(
        "div",
        { class: "profile-photo-box" },
        h(
          "div",
          { class: "profile-photo-head" },
          h(
            "label",
            { class: "profile-photo-label", for: "pf-photo" },
            "Profile Photo",
          ),
          h("span", { class: "profile-photo-format-pill" }, "JPG · PNG · WEBP"),
        ),
        photoInput,
        photoDropzone,
        h(
          "div",
          { class: "profile-photo-actions" },
          photoUploadBtn,
          photoRemove,
        ),
        photoNote,
      ),
      h(
        "dl",
        { class: "profile-meta-list" },
        h(
          "div",
          { class: "profile-meta-row" },
          h("dt", {}, "Member ID"),
          h("dd", {}, me.member_no || "Assigned on approval"),
        ),
        h(
          "div",
          { class: "profile-meta-row" },
          h("dt", {}, "Date of birth"),
          metaBirthDd,
        ),
        h(
          "div",
          { class: "profile-meta-row" },
          h("dt", {}, "Sign-in email"),
          h("dd", {}, me.email || "—"),
        ),
      ),
    );

    const submit = button({
      label: "Save profile",
      variant: "primary",
      type: "submit",
      icon: "check",
    });

    const personalCard = h(
      "section",
      { class: "member-panel profile-section-card" },
      h(
        "div",
        { class: "profile-section-head" },
        h(
          "span",
          { class: "section-icon", "aria-hidden": "true" },
          icon("user"),
        ),
        h(
          "div",
          { class: "profile-section-copy" },
          h("h2", { class: "profile-section-title" }, "Personal Information"),
          h(
            "p",
            { class: "profile-section-sub muted" },
            "Your legal name and how you appear on club brackets and directories.",
          ),
        ),
      ),
      h(
        "div",
        { class: "profile-form-grid is-two-col" },
        lastName,
        firstName,
      ),
      h(
        "div",
        { class: "profile-form-grid is-two-col" },
        middleName,
        suffix.node,
      ),
      h(
        "div",
        { class: "profile-form-grid is-three-col" },
        display,
        gender.node,
        birth,
      ),
    );

    const contactCard = h(
      "section",
      { class: "member-panel profile-section-card" },
      h(
        "div",
        { class: "profile-section-head" },
        h(
          "span",
          { class: "section-icon", "aria-hidden": "true" },
          icon("phone"),
        ),
        h(
          "div",
          { class: "profile-section-copy" },
          h(
            "h2",
            { class: "profile-section-title" },
            "Contact & Emergency Details",
          ),
          h(
            "p",
            { class: "profile-section-sub muted" },
            "Where the club sends booking updates and who to reach in an emergency.",
          ),
        ),
      ),
      h(
        "div",
        { class: "profile-form-grid is-two-col" },
        mobile,
        email,
      ),
      h(
        "div",
        { class: "profile-subsection-divider" },
        h(
          "span",
          { class: "profile-subsection-label" },
          "Emergency Contact (Optional)",
        ),
      ),
      h(
        "div",
        { class: "profile-form-grid is-three-col" },
        emName,
        emRel,
        emPhone,
      ),
    );

    const addressCard = h(
      "section",
      { class: "member-panel profile-section-card" },
      h(
        "div",
        { class: "profile-section-head" },
        h(
          "span",
          { class: "section-icon", "aria-hidden": "true" },
          icon("home"),
        ),
        h(
          "div",
          { class: "profile-section-copy" },
          h("h2", { class: "profile-section-title" }, "Residential Address"),
          h(
            "p",
            { class: "profile-section-sub muted" },
            "Your current street address, province, city or municipality, and barangay.",
          ),
        ),
      ),
      addressSkeleton,
      addressFields,
    );

    const actionsBar = h(
      "div",
      { class: "member-panel profile-actions-bar" },
      error,
      h(
        "div",
        { class: "profile-actions-row" },
        h(
          "span",
          { class: "profile-required-note muted" },
          "Fields marked with * are required.",
        ),
        h("div", { class: "actions" }, submit),
      ),
    );

    const form = h(
      "form",
      {
        class: "profile-form-stack",
        novalidate: true,
        onSubmit: (e) => e.preventDefault(),
      },
      state.gate === "profile_update"
        ? h(
          "div",
          { class: "member-panel profile-alert-banner", role: "status" },
          h(
            "span",
            { class: "section-icon is-warning", "aria-hidden": "true" },
            icon("alert"),
          ),
          h(
            "p",
            {},
            "An administrator reset your password. Please check your details and make sure your email is correct, then save.",
          ),
        )
        : null,
      h(
        "div",
        { class: "profile-layout" },
        identityCard,
        h(
          "div",
          { class: "profile-form-column" },
          personalCard,
          contactCard,
          addressCard,
          actionsBar,
        ),
      ),
    );
    form.addEventListener(
      "submit",
      withPending(submit, async () => {
        showError(error, []);
        const missing = [];
        if (!inputValue(lastName).trim()) missing.push("Enter your last name.");
        if (!inputValue(firstName).trim()) {
          missing.push("Enter your first name.");
        }
        if (inputValue(display).trim().length < 2) {
          missing.push("Enter the display name you want to use.");
        }
        if (!inputValue(email).trim()) {
          missing.push("Enter your email address.");
        }
        if (inputValue(mobile).replace(/\D/g, "").length < 10) {
          missing.push("Enter a valid mobile number, for example 09171234567.");
        }
        const hasName = inputValue(emName).trim() !== "";
        const hasPhone = inputValue(emPhone).trim() !== "";
        if (hasName !== hasPhone) {
          missing.push("An emergency contact needs both a name and a number.");
        }
        if (!barangay.sel.value) {
          missing.push("Choose your province, city and barangay.");
        }
        if (missing.length) return showError(error, missing);
        const dobVal = inputValue(birth).trim() || null;
        try {
          const payload = {
            p_display_name: inputValue(display),
            p_mobile: inputValue(mobile),
            p_email: inputValue(email) || null,
            p_street_line: inputValue(street) || null,
            p_barangay_code: barangay.sel.value,
            p_first_name: inputValue(firstName),
            p_middle_name: inputValue(middleName),
            p_last_name: inputValue(lastName),
            p_suffix: suffix.sel.value,
            p_gender: gender.sel.value,
            p_emergency_name: inputValue(emName),
            p_emergency_relationship: inputValue(emRel),
            p_emergency_phone: inputValue(emPhone),
          };
          try {
            await api.rpc("update_my_profile", {
              ...payload,
              p_date_of_birth: dobVal,
            });
          } catch (rpcErr) {
            if (
              rpcErr?.code === "PGRST202" ||
              String(rpcErr?.cause?.message || rpcErr?.message || "").includes(
                "p_date_of_birth",
              )
            ) {
              await api.rpc("update_my_profile", payload);
            } else {
              throw rpcErr;
            }
          }
          await api.rpc("confirm_my_profile");
          await session.refresh();
          toast("Profile saved.", { tone: "success" });
          go(nextHash(session.getState()));
        } catch (e) {
          const own = ["22023", "23505"].includes(e?.code) && e.cause?.message;
          showError(
            error,
            own || e.message || "Your profile could not be saved.",
          );
        }
      }),
    );

    const isOnboarding = !me.profile_complete && me.status !== "active";
    const page = h("div", {
      class: "page admin-dashboard admin-members-page profile-page",
    });
    attachPagePattern(page);
    page.append(
      adminHero({
        title: isOnboarding ? "Complete your profile" : "Account & Profile",
        chip: isOnboarding ? "Member Onboarding" : "Profile Settings",
        description: isOnboarding
          ? "The club needs your details, contact numbers and address before it can approve your membership."
          : "Manage your personal information, contact details, emergency contact, and profile photo.",
        actions: [
          button({
            label: "Change password",
            icon: "keyRound",
            variant: "secondary",
            onClick: () => go("#/password"),
          }),
        ],
      }),
      form,
    );
    return page;
  }

  // ---------------------------------------------------------------- sign up (new members only)
  const FIELD_MESSAGES = {
    first_name: "Enter your first name (letters only).",
    last_name: "Enter your last name (letters only).",
    middle_name: "The middle name can contain letters only.",
    suffix: "Choose an extension from the list.",
    gender: "Choose male or female, or leave it blank.",
    date_of_birth: "Enter your date of birth.",
    mobile: "Enter a valid mobile number, for example 09171234567.",
    email: "Enter a valid email address.",
    password: "Choose a password.",
    consent_waiver: "Please accept the waiver to continue.",
    consent_privacy: "Please accept the privacy notice to continue.",
    captcha_token: "Please complete the security check first.",
  };

  function checkbox(id, text) {
    const box = h("input", { type: "checkbox", id, name: id });
    return {
      box,
      node: h("div", { class: "check" }, box, h("label", { for: id }, text)),
    };
  }

  function signUpPage() {
    const state = session.getState();
    if (state.status === "signed_in") {
      queueMicrotask(() => go(nextHash(state)));
      return h("div", { class: "page" });
    }
    let token = null;
    let widget = null;
    const turnstileBox = h("div", { class: "turnstile-box" });
    const error = errorBox();
    renderTurnstile(turnstileBox, {
      action: "member-signup",
      onToken: (t) => (token = t),
      onExpire: () => (token = null),
      onError: (m) => showError(error, m),
    }).then((w) => (widget = w)).catch((e) => showError(error, e.message));

    const firstName = field({
      id: "su-first",
      label: "First name",
      required: true,
    });
    const lastName = field({
      id: "su-last",
      label: "Last name",
      required: true,
    });
    const middleName = field({
      id: "su-middle",
      label: "Middle name (optional)",
    });
    const suffix = choiceField(
      "su-suffix",
      "Extension (optional)",
      SUFFIXES.map((x) => [x, x]),
      "",
      "None",
    );
    const gender = choiceField(
      "su-gender",
      "Gender (optional)",
      GENDERS,
      "",
      "Prefer not to say",
    );
    const birth = calendarDropdown({
      id: "su-birth",
      label: "Date of birth",
      required: true,
      min: "1920-01-01",
      max: new Date().toISOString().slice(0, 10),
      defaultView: "2000-01",
    });
    const mobile = field({
      id: "su-mobile",
      label: "Mobile number",
      required: true,
      placeholder: "09171234567",
    });
    mobile.querySelector("input").setAttribute("inputmode", "tel");
    mobile.querySelector("input").setAttribute("autocomplete", "tel");
    const email = field({
      id: "su-email",
      label: "Email",
      type: "email",
      required: true,
      placeholder: "you@example.com",
    });
    email.querySelector("input").setAttribute("autocomplete", "email");
    const password = field({
      id: "su-password",
      label: "Password",
      type: "password",
      required: true,
      hint: "At least 12 characters. A few unrelated words works well.",
    });
    const confirm = field({
      id: "su-confirm",
      label: "Repeat the password",
      type: "password",
      required: true,
    });
    password.querySelector("input").setAttribute(
      "autocomplete",
      "new-password",
    );
    confirm.querySelector("input").setAttribute("autocomplete", "new-password");
    for (const f of [firstName, lastName, middleName]) {
      f.querySelector("input").setAttribute("maxlength", "60");
    }
    firstName.querySelector("input").setAttribute("autocomplete", "given-name");
    lastName.querySelector("input").setAttribute("autocomplete", "family-name");

    const waiver = checkbox(
      "su-waiver",
      "I accept the club's waiver and release of liability.",
    );
    const privacy = checkbox(
      "su-privacy",
      "I agree that the club may collect and use my personal information for membership, bookings and tournaments (Data Privacy Act of 2012).",
    );
    // Honeypot: people never see or fill this; automated forms often do.
    const trap = h(
      "div",
      { class: "hp", "aria-hidden": "true" },
      h("label", { for: "su-website" }, "Leave this field empty"),
      h("input", {
        id: "su-website",
        name: "website",
        type: "text",
        tabindex: "-1",
        autocomplete: "off",
      }),
    );

    const submit = button({
      label: "Create my account",
      variant: "primary",
      type: "submit",
      icon: "check",
    });
    const form = h(
      "form",
      {
        class: "stack auth-signup-form",
        novalidate: true,
        onSubmit: (e) => e.preventDefault(),
      },
      h("h3", { class: "form-section" }, "About you"),
      h("div", { class: "form-row" }, firstName, lastName),
      h("div", { class: "form-row" }, middleName, suffix.node),
      h("div", { class: "form-row" }, gender.node, birth),
      h("h3", { class: "form-section" }, "Contact"),
      h("div", { class: "form-row" }, mobile, email),
      h("h3", { class: "form-section" }, "Password"),
      h("div", { class: "form-row" }, password, confirm),
      h("h3", { class: "form-section" }, "Agreements"),
      waiver.node,
      privacy.node,
      trap,
      turnstileBox,
      error,
      h("div", { class: "actions" }, submit),
    );
    const card = h(
      "div",
      { class: "card auth-card" },
      h(
        "div",
        { class: "auth-card-head" },
        h(
          "span",
          { class: "badge-icon", "aria-hidden": "true" },
          icon("userPlus"),
        ),
        h(
          "div",
          { class: "auth-card-head-copy" },
          h("div", { class: "eyebrow" }, "New members"),
          h("h2", { class: "card-title" }, "Create an account"),
          h(
            "p",
            { class: "card-subtitle muted" },
            "It takes about two minutes. The club reviews every membership.",
          ),
        ),
      ),
      form,
      h(
        "div",
        { class: "auth-card-footer" },
        "Already a member? ",
        h("a", { href: "#/signin", class: "auth-signup-link" }, "Sign in"),
        ". Under 18? A parent or guardian should complete this form.",
      ),
    );

    form.addEventListener(
      "submit",
      withPending(submit, async () => {
        showError(error, []);
        if (!inputValue(email).trim()) {
          return showError(error, "Enter your email address.");
        }
        const local = localPasswordProblems(
          inputValue(password),
          inputValue(confirm),
        );
        if (local.length) return showError(error, local);
        if (!token) return showError(error, FIELD_MESSAGES.captcha_token);
        const used = token;
        token = null;
        try {
          const result = await authApi.memberSignup({
            first_name: inputValue(firstName),
            last_name: inputValue(lastName),
            middle_name: inputValue(middleName),
            suffix: suffix.sel.value,
            gender: gender.sel.value,
            date_of_birth: birth.value,
            mobile: inputValue(mobile),
            email: inputValue(email),
            password: inputValue(password),
            consent_waiver: waiver.box.checked,
            consent_privacy: privacy.box.checked,
            website: trap.querySelector("input").value,
          }, used);
          password.querySelector("input").value = "";
          confirm.querySelector("input").value = "";
          card.replaceChildren(
            h("h2", {}, "Your account is ready"),
            h("p", {}, "Your member ID is:"),
            h(
              "p",
              { class: "member-id", tabindex: "0" },
              result.member_no ?? "",
            ),
            h(
              "p",
              { class: "muted" },
              "Write it down: you need it to sign in, together with the password you just chose. The club will review your membership, and you can complete your profile after you sign in.",
            ),
            h(
              "div",
              { class: "actions" },
              h(
                "a",
                { class: "btn btn-primary", href: "#/signin" },
                "Go to sign in",
              ),
            ),
          );
        } catch (e) {
          if (e.code === "invalid") {
            showError(
              error,
              Object.keys(e.errors ?? {}).map((k) =>
                FIELD_MESSAGES[k] ?? "Please check your details."
              ),
            );
          } else if (e.code === "weak_password") {
            showError(error, problemMessages(e.problems));
          } else {showError(
              error,
              e.message || "Sign-up could not be completed.",
            );}
        } finally {
          widget?.reset(); // the token is single use
        }
      }),
    );

    return authShell({
      titleLead: "Join ",
      subtitle:
        "Create your member account to book courts, track your rank and register for club events. Existing members already have an account: sign in instead.",
      card,
      wide: true,
    });
  }

  // ---------------------------------------------------------------- pending
  function step(done, label) {
    return h(
      "li",
      { class: done ? "step done" : "step" },
      icon(done ? "check" : "info"),
      label,
    );
  }

  function pendingPage() {
    const state = session.getState();
    const me = state.access ?? {};
    const approved = me.status === "active";
    const waiting = me.status === "pending_approval";
    const profileDone = Boolean(me.profile_complete);
    return h(
      "div",
      { class: "page auth-page" },
      pageHeader({
        icon: "inbox",
        eyebrow: me.member_no ?? "Your account",
        title: approved
          ? "You are approved"
          : waiting
          ? "Waiting for approval"
          : "Almost there",
        description: approved
          ? "You can now use the app."
          : waiting
          ? "The club will review your membership. You will be able to book courts and join events once it is approved."
          : "Finish your profile so the club can approve your membership.",
      }),
      h(
        "div",
        { class: "card auth-card stack" },
        h(
          "p",
          {},
          "Status: ",
          badge(
            approved
              ? "approved"
              : waiting
              ? "waiting for approval"
              : "profile needed",
            approved ? "success" : "warning",
          ),
        ),
        h(
          "ul",
          { class: "steps" },
          step(true, "Signed in and password changed"),
          step(profileDone, "Profile completed"),
          step(approved, "Approved by the club"),
        ),
        approved
          ? h(
            "div",
            { class: "actions" },
            h(
              "a",
              { class: "btn btn-primary", href: "#/" },
              "Go to the home page",
            ),
          )
          : h(
            "div",
            { class: "actions" },
            h("a", {
              class: "btn" + (profileDone ? "" : " btn-primary"),
              href: "#/profile",
            }, profileDone ? "Edit my profile" : "Complete my profile"),
          ),
      ),
    );
  }

  return { signInPage, signUpPage, passwordPage, profilePage, pendingPage };
}
