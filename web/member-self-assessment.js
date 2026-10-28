import { badge, button, h, icon, selectField } from "./ui.js";
import { formatDateTime } from "./lib/dates.js";

/** Optional estimate, saved independently of profile details and official CPC ranks. */
export function selfAssessmentCard(
  { api, memberId = null, staff = false, canEdit = true },
) {
  const body = h("div", { class: "stack" });
  const card = h(
    "section",
    {
      class: staff
        ? "member-section-card assessment-card"
        : "member-panel profile-section-card assessment-card",
      "aria-label": "Rank Assessment",
    },
    h(
      "div",
      { class: "profile-section-head" },
      h(
        "span",
        { class: "section-icon", "aria-hidden": "true" },
        icon("medal"),
      ),
      h(
        "div",
        { class: "profile-section-copy" },
        h("h3", {}, "Rank Assessment"),
        h(
          "p",
          { class: "profile-section-sub muted" },
          "Submit your playing level once. Club admins manage later updates.",
        ),
      ),
    ),
    body,
  );
  let intent = null;

  async function load() {
    card.setAttribute("aria-busy", "true");
    body.replaceChildren(
      h("span", { class: "sk sk-input", "aria-hidden": "true" }),
    );
    try {
      const data = await api.rpc("get_member_self_assessment", {
        p_member_id: memberId,
      });
      if (!data?.member_id) throw new Error("No assessment data");
      render(data);
    } catch {
      body.replaceChildren(
        h(
          "p",
          { class: "field-error", role: "alert" },
          "Self-assessment could not be loaded.",
        ),
        button({ label: "Retry", variant: "secondary", onClick: load }),
      );
    } finally {
      card.setAttribute("aria-busy", "false");
    }
  }

  function render(data) {
    const locked = data.locked ??
      (data.version > 0 || data.origin === "club_rank");
    const editable = canEdit && data.can_edit && (data.admin_edit || !locked);
    const options = [
      {
        value: "",
        label: data.admin_edit ? "Not Assessed" : "Choose Your Rank",
      },
      ...(data.options ?? []),
    ];
    if (
      data.rank_id && !options.some((option) => option.value === data.rank_id)
    ) {
      options.push({
        value: data.rank_id,
        label: `${data.rank_name} (Unavailable)`,
        disabled: true,
      });
    }
    const rankName = data.rank_name ||
      options.find((option) => option.value === data.rank_id)?.label ||
      "Not Submitted";
    const statusLabel = data.source === "admin"
      ? "Admin Assessed"
      : data.source === "club"
      ? "Club Assigned"
      : data.source === "member"
      ? "Submitted"
      : "Not Submitted";
    const summary = h(
      "div",
      { class: "assessment-summary" },
      h(
        "div",
        { class: "assessment-summary-tile is-primary" },
        h("span", { class: "assessment-label" }, "Rank Assessment"),
        h(
          "strong",
          { class: "assessment-rank" },
          data.rank_id
            ? rankName
            : data.version > 0
            ? "Not Assessed"
            : "Not Submitted",
        ),
        badge(
          statusLabel,
          data.source === "admin" || data.source === "club"
            ? "success"
            : "neutral",
        ),
      ),
      h(
        "div",
        { class: "assessment-summary-tile is-primary" },
        h("span", { class: "assessment-label" }, "Official Club Rank"),
        h(
          "strong",
          { class: "assessment-official-rank" },
          data.official_rank || "Unranked",
        ),
        h("span", { class: "sub" }, "Used for club events and rank movement."),
      ),
    );
    const rank = editable
      ? selectField({
        id: `self-rank-${data.member_id}`,
        label: "Assessment Rank",
        options,
        value: data.rank_id ?? "",
        hint: data.admin_edit
          ? "Update the member's assessment without changing the official Club Rank."
          : "Choose carefully. Once saved, only an admin can update it.",
      })
      : null;
    const reason = data.admin_edit && editable
      ? h(
        "div",
        { class: "field" },
        h(
          "label",
          { for: `self-reason-${data.member_id}` },
          "Reason for Correction",
        ),
        h("textarea", {
          id: `self-reason-${data.member_id}`,
          class: "input textarea",
          rows: 2,
          maxlength: 500,
          placeholder: "Explain the assessment change.",
        }),
      )
      : null;
    const error = h("p", { class: "field-error", role: "alert", hidden: true });
    const controls = h(
      "fieldset",
      { class: "self-assessment-controls" },
      rank,
      reason,
      error,
    );
    const reload = button({
      label: "Reload Assessment",
      variant: "secondary",
      type: "button",
      onClick: load,
    });
    reload.hidden = true;
    if (editable) {
      controls.append(h(
        "div",
        { class: "assessment-actions" },
        reload,
        button({
          label: data.admin_edit ? "Save Correction" : "Save Assessment",
          icon: "check",
          variant: "primary",
          type: "button",
          onClick: async () => {
            error.hidden = true;
            const reasonText = reason?.querySelector("textarea").value.trim() ||
              null;
            if (!data.admin_edit && !rank.value) {
              error.textContent =
                "Choose a rank before saving your assessment.";
              error.hidden = false;
              return;
            }
            if (data.admin_edit && (!reasonText || reasonText.length < 3)) {
              error.textContent = "Give a reason of at least 3 characters.";
              error.hidden = false;
              return;
            }
            const payload = {
              p_member_id: data.member_id,
              p_rank_id: rank.value || null,
              p_expected_version: data.version,
              p_reason: reasonText,
            };
            const fingerprint = JSON.stringify(payload);
            if (intent?.fingerprint !== fingerprint) {
              intent = { fingerprint, key: api.newKey() };
            }
            controls.disabled = true;
            card.setAttribute("aria-busy", "true");
            try {
              await api.rpc("set_member_self_assessment", {
                ...payload,
                p_key: intent.key,
              });
              intent = null;
              await load();
            } catch (e) {
              error.textContent = ["22023", "CP409", "42501"].includes(e?.code)
                ? e.cause?.message || e.message
                : "Assessment could not be saved. Please try again.";
              error.hidden = false;
              reload.hidden = !["CP409", "42501"].includes(e?.code);
            } finally {
              controls.disabled = false;
              card.setAttribute("aria-busy", "false");
            }
          },
        }),
      ));
    }
    const provenance = data.source === "admin"
      ? "Updated by Admin"
      : data.source === "club"
      ? "Loaded from Your Club Rank"
      : data.source === "member"
      ? "Submitted by You"
      : "No assessment submitted yet.";
    body.replaceChildren(
      h(
        "div",
        { class: "assessment-content" },
        summary,
        editable ? controls : null,
        h(
          "div",
          { class: "assessment-footer" },
          !editable
            ? h(
              "p",
              { class: "assessment-lock-note" },
              icon("lock"),
              h(
                "span",
                {},
                locked
                  ? "Only an admin can update your assessment."
                  : "Your assessment is currently read-only.",
              ),
            )
            : null,
          h(
            "p",
            { class: "assessment-provenance", role: "status" },
            provenance,
            data.updated_at ? ` · ${formatDateTime(data.updated_at)}` : "",
          ),
          data.reason
            ? h("p", { class: "assessment-note" }, data.reason)
            : null,
        ),
      ),
    );
  }
  load();
  return card;
}
