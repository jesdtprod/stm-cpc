// Account pages (PLAN 3.4): sign in, forced password change, profile completion, pending approval.
// All dynamic text goes through h()/textContent (see ui.js), so nothing here can inject markup.
import {
  badge,
  button,
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
      label: "Member ID",
      required: true,
      placeholder: "Example: CPC-2026-00001",
    });
    const idInput = memberId.querySelector("input");
    idInput.setAttribute("autocomplete", "username");
    idInput.setAttribute("autocapitalize", "characters");
    idInput.setAttribute("spellcheck", "false");
    const password = field({
      id: "signin-password",
      label: "Password",
      type: "password",
      required: true,
    });
    password.querySelector("input").setAttribute(
      "autocomplete",
      "current-password",
    );
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
          return showError(error, "Enter your member ID and password.");
        }
        if (!token) {
          return showError(error, "Please complete the security check first.");
        }
        const used = token;
        token = null;
        try {
          await session.signIn({ memberId: id, password: pw }, used);
          password.querySelector("input").value = "";
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

    return h(
      "div",
      { class: "page auth-page" },
      pageHeader({
        icon: "check",
        eyebrow: "Members",
        title: "Sign in",
        description: "Use your member ID and password.",
      }),
      h(
        "div",
        { class: "card auth-card" },
        form,
        h(
          "p",
          { class: "muted small" },
          "First time here? Your first password is the last 5 digits of your member ID followed by your birth date as MMDDYYYY. You will be asked to choose a new one.",
        ),
      ),
    );
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

  function profilePage() {
    const state = session.getState();
    if (state.gate === "password_change") {
      queueMicrotask(() => go("#/password"));
      return h("div", { class: "page" });
    }
    const me = state.access ?? {};
    const name = field({
      id: "pf-name",
      label: "Display name",
      value: me.display_name ?? "",
      required: true,
    });
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
      await fill(
        city.sel,
        await areaList("city_muni", code),
        "Choose a city or municipality",
        selected,
      );
    }
    async function loadBarangays(code, selected) {
      if (!code) return fill(barangay.sel, [], "Choose a city first");
      await fill(
        barangay.sel,
        await areaList("barangay", code),
        "Choose a barangay",
        selected,
      );
    }
    const startProvince = me.province_code ?? me.region_code ?? "";
    (async () => {
      try {
        await fill(
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
      name,
      mobile,
      email,
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
        if (inputValue(name).trim().length < 2) {
          missing.push("Enter your name.");
        }
        if (inputValue(mobile).replace(/\D/g, "").length < 10) {
          missing.push("Enter a valid mobile number, for example 09171234567.");
        }
        if (!barangay.sel.value) {
          missing.push("Choose your province, city and barangay.");
        }
        if (missing.length) return showError(error, missing);
        try {
          await api.rpc("update_my_profile", {
            p_display_name: inputValue(name),
            p_mobile: inputValue(mobile),
            p_email: inputValue(email) || null,
            p_street_line: inputValue(street) || null,
            p_barangay_code: barangay.sel.value,
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
          "The club needs your contact details and address before it can approve your membership.",
      }),
      h("div", { class: "card auth-card" }, form),
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

  return { signInPage, passwordPage, profilePage, pendingPage };
}
