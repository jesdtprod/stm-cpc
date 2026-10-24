// Account pages (PLAN 3.4): sign in, forced password change, profile completion, pending approval.
// All dynamic text goes through h()/textContent (see ui.js), so nothing here can inject markup.
import {
  badge,
  button,
  createCourtWatermarkSvg,
  field,
  h,
  icon,
  pageHeader,
  toast,
  withPending,
} from "./ui.js";
import {
  localPasswordProblems,
  problemMessages,
} from "./lib/password-hints.js";
import { suggestNameParts } from "./lib/names.js";

const NCR_REGION = "130000000";

/** Where a signed-in user belongs: the gate page, or the profile page when it is the next step, or home. */
export function nextHash(state) {
  if (state.status !== "signed_in") return "#/signin";
  if (state.gate === "password_change") return "#/password";
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
  { session, api, authApi, getAccessToken, renderTurnstile },
) {
  const go = (hash) => {
    if (location.hash !== hash) location.hash = hash;
  };

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
      placeholder: "Example: CPC-2026-00001 or name@email.com",
      iconLeading: "user",
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
      iconLeading: "lock",
    });
    const pwInput = password.querySelector("input");
    pwInput.setAttribute("autocomplete", "current-password");
    const error = errorBox();

    const submit = button({
      label: "Sign in",
      variant: "primary",
      type: "submit",
      icon: "check",
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

    const watermarkEl = createCourtWatermarkSvg("auth-court-watermark");

    const containerEl = h(
      "div",
      { class: "auth-page-container" },
      watermarkEl,
      h(
        "div",
        { class: "auth-page" },
        // Landing page style brand header: Logo flanked side-by-side by paddle and ball
        h(
          "div",
          { class: "auth-brand-top" },
          h(
            "div",
            { class: "auth-brand-flank auth-brand-flank-left" },
            h("img", {
              src: "icons/paddle.png",
              alt: "Tournament Pickleball Paddle Left",
              class: "auth-top-paddle auth-top-paddle-left",
            }),
            h("img", {
              src: "icons/ball.png",
              alt: "Tournament Pickleball Left",
              class: "auth-top-ball auth-top-ball-left",
            }),
          ),
          h("img", {
            class: "auth-brand-logo",
            src: "icons/cpc-logo.png",
            alt: "Capitol Pickleball Club",
            width: "68",
            height: "68",
          }),
          h(
            "div",
            { class: "auth-brand-flank auth-brand-flank-right" },
            h("img", {
              src: "icons/ball.png",
              alt: "Tournament Pickleball Right",
              class: "auth-top-ball auth-top-ball-right",
            }),
            h("img", {
              src: "icons/paddle.png",
              alt: "Tournament Pickleball Paddle Right",
              class: "auth-top-paddle auth-top-paddle-right",
            }),
          ),
        ),
        h(
          "div",
          { class: "auth-hero-badge" },
          icon("trophy"),
          "Province of Sultan Kudarat’s Pickleball Court",
        ),
        h(
          "div",
          { class: "auth-title-wrap" },
          h(
            "h1",
            { class: "auth-page-title", id: "page-title", tabindex: "-1" },
            "Sign In to ",
            h(
              "span",
              { class: "auth-title-accent" },
              "Capitol Pickleball Club",
            ),
          ),
          h(
            "p",
            { class: "auth-page-subtitle" },
            "Use your member ID and password to manage court bookings, ranks, and event registrations.",
          ),
        ),
        h(
          "div",
          { class: "card auth-card" },
          form,
          h(
            "div",
            { class: "auth-first-time-box" },
            icon("info"),
            h(
              "span",
              {},
              h(
                "strong",
                { class: "auth-first-time-strong" },
                "First time here? ",
              ),
              "Your initial password is the last 5 digits of your member ID followed by your birth date as MMDDYYYY (e.g. 0000112212025). You will be prompted to choose a new password upon first sign-in.",
            ),
          ),
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
        h(
          "a",
          { href: "#/", class: "auth-back-link" },
          icon("arrowLeft"),
          "Back to home",
        ),
      ),
    );

    return containerEl;
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

    return h(
      "div",
      { class: "page auth-page" },
      pageHeader({
        icon: "check",
        eyebrow: forced ? "One more step" : "Account",
        title: forced ? "Choose a new password" : "Change password",
        description: forced
          ? "For your security, replace the password you were given before you continue."
          : "Pick a new password for your account.",
      }),
      h("div", { class: "card auth-card" }, form),
    );
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

  /** A <select> field with a blank first option. `choices` is a list of [value, label]. */
  function choiceField(id, label, choices, selected, blankLabel) {
    const sel = h(
      "select",
      { class: "input", id, name: id },
      h("option", { value: "" }, blankLabel),
      ...choices.map(([v, l]) =>
        h("option", { value: v, selected: v === selected ? true : null }, l)
      ),
    );
    return {
      sel,
      node: h("div", { class: "field" }, h("label", { for: id }, label), sel),
    };
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
      hint: guess?.last
        ? "Suggested from your name: please check it."
        : undefined,
    });
    const firstName = field({
      id: "pf-first",
      label: "First name",
      value: me.first_name ?? guess?.first ?? "",
      required: true,
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
      hint: "How your name appears in the app and on brackets.",
    });
    const gender = choiceField(
      "pf-gender",
      "Gender (optional)",
      GENDERS,
      me.gender,
      "Prefer not to say",
    );
    const birth = field({
      id: "pf-birth",
      label: "Date of birth",
      value: formatDate(me.date_of_birth),
      hint: "To change your date of birth, ask the club.",
    });
    birth.querySelector("input").disabled = true;
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
      hint: "For example 09171234567",
      placeholder: "09171234567",
    });
    mobile.querySelector("input").setAttribute("autocomplete", "tel");
    mobile.querySelector("input").setAttribute("inputmode", "tel");
    const email = field({
      id: "pf-email",
      label: "Email (optional)",
      type: "email",
      value: me.email ?? "",
    });
    email.querySelector("input").setAttribute("autocomplete", "email");

    // ---- emergency contact
    const emName = field({
      id: "pf-em-name",
      label: "Emergency contact name (optional)",
      value: me.emergency_name ?? "",
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
    });
    emPhone.querySelector("input").setAttribute("inputmode", "tel");

    // ---- address
    const street = field({
      id: "pf-street",
      label: "House number and street (optional)",
      value: me.street_line ?? "",
    });
    const selectField = (id, label) => {
      const sel = h("select", {
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

    const submit = button({
      label: "Save profile",
      variant: "primary",
      type: "submit",
      icon: "check",
    });
    const form = h(
      "form",
      { class: "stack", novalidate: true, onSubmit: (e) => e.preventDefault() },
      h("h2", { class: "form-section" }, "Name"),
      lastName,
      firstName,
      middleName,
      suffix.node,
      display,
      gender.node,
      birth,
      h("h2", { class: "form-section" }, "Contact"),
      mobile,
      email,
      h("h2", { class: "form-section" }, "Emergency contact"),
      emName,
      emRel,
      emPhone,
      h("h2", { class: "form-section" }, "Address"),
      street,
      province.node,
      city.node,
      barangay.node,
      error,
      h("div", { class: "actions" }, submit),
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
        try {
          await api.rpc("update_my_profile", {
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
          });
          await session.refresh();
          toast("Profile saved.");
          go(nextHash(session.getState()));
        } catch (e) {
          showError(error, e.message || "Your profile could not be saved.");
        }
      }),
    );

    return h(
      "div",
      { class: "page auth-page" },
      pageHeader({
        icon: "edit",
        eyebrow: "Your account",
        title: "Complete your profile",
        description:
          "The club needs your details, contact numbers and address before it can approve your membership.",
      }),
      h("div", { class: "card auth-card" }, form),
    );
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
    email: "Enter a valid email address, or leave it blank.",
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
    const birth = field({
      id: "su-birth",
      label: "Date of birth",
      type: "date",
      required: true,
    });
    birth.querySelector("input").setAttribute(
      "max",
      new Date().toISOString().slice(0, 10),
    );
    birth.querySelector("input").setAttribute("min", "1920-01-01");
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
      label: "Email (optional)",
      type: "email",
    });
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
      { class: "stack", novalidate: true, onSubmit: (e) => e.preventDefault() },
      h("h2", { class: "form-section" }, "About you"),
      firstName,
      lastName,
      middleName,
      suffix.node,
      gender.node,
      birth,
      h("h2", { class: "form-section" }, "Contact"),
      mobile,
      email,
      h("h2", { class: "form-section" }, "Password"),
      password,
      confirm,
      h("h2", { class: "form-section" }, "Agreements"),
      waiver.node,
      privacy.node,
      trap,
      turnstileBox,
      error,
      h("div", { class: "actions" }, submit),
    );
    const card = h("div", { class: "card auth-card" }, form);

    form.addEventListener(
      "submit",
      withPending(submit, async () => {
        showError(error, []);
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
            date_of_birth: inputValue(birth),
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

    return h(
      "div",
      { class: "page auth-page" },
      pageHeader({
        icon: "plus",
        eyebrow: "New members",
        title: "Create an account",
        description:
          "For people who are not members yet. Existing members already have an account: sign in instead.",
      }),
      card,
      h(
        "p",
        { class: "muted small" },
        "Already a member? ",
        h("a", { href: "#/signin" }, "Sign in"),
        ". Under 18? A parent or guardian should complete this form, and the club will ask for a signed waiver.",
      ),
    );
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
