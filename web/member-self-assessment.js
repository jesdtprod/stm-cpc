import { badge, button, h, icon } from "./ui.js";
import { formatDateTime } from "./lib/dates.js";
import { assessPointsModal, formatPoints } from "./cpc-points.js";

const STATUS_LABEL = {
  NR: "Not Rated",
  self: "Self-Assessed",
  admin: "Admin Assessed",
  played: "Updated by Play",
};

/**
 * Rank Assessment (Member Profile and Member Details): a Singles rating and a Doubles rating (2.000-8.000, NR when none)
 * and the Club Rank, which the database always derives from the higher of the two. Members may submit their first
 * ratings once; afterwards only administrators (ranks.override) change them. Nothing here calculates a rank.
 */
export function selfAssessmentCard(
  { api, memberId = null, staff = false, canEdit = true, name = "this member" },
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
      h("span", { class: "section-icon", "aria-hidden": "true" }, icon("medal")),
      h(
        "div",
        { class: "profile-section-copy" },
        h("h3", { class: "profile-section-title" }, "Rank Assessment"),
        h(
          "p",
          { class: "profile-section-sub muted" },
          "Your Singles and Doubles ratings determine your Club Rank. Submit your starting ratings once; club admins manage later updates.",
        ),
      ),
    ),
    body,
  );
  let intent = null;

  async function load() {
    card.setAttribute("aria-busy", "true");
    body.replaceChildren(h("span", { class: "sk sk-input", "aria-hidden": "true" }));
    try {
      const data = await api.rpc("get_member_ratings", { p_member_id: memberId });
      if (!data?.member_id) throw new Error("No rating data");
      render(data);
    } catch {
      body.replaceChildren(
        h("p", { class: "field-error", role: "alert" }, "Ratings could not be loaded."),
        button({ label: "Retry", variant: "secondary", onClick: load }),
      );
    } finally {
      card.setAttribute("aria-busy", "false");
    }
  }

  const ratingTile = (data, discipline, label, editable) => {
    const side = data[discipline];
    return h(
      "div",
      { class: "assessment-summary-tile is-primary", "data-discipline": discipline },
      h("div", { class: "assessment-tile-heading" },
        h("span", { class: "assessment-label" }, label),
        editable
          ? button({
            label: side.points == null ? "Assess" : "Edit",
            icon: "edit",
            variant: "secondary",
            size: "sm",
            type: "button",
            onClick: () =>
              assessPointsModal({
                api,
                discipline,
                row: {
                  member_id: data.member_id,
                  display_name: name,
                  singles: { points: data.singles.points, version: data.singles.version },
                  doubles: { points: data.doubles.points, version: data.doubles.version },
                },
                onDone: load,
              }),
          })
          : icon("trophy"),
      ),
      h("strong", { class: "assessment-rank" }, side.points == null ? "NR" : formatPoints(side.points)),
      h("span", { class: "sub" }, side.classification ?? "Not Rated"),
      h(
        "div",
        { class: "assessment-tile-foot" },
        badge(STATUS_LABEL[side.status] ?? STATUS_LABEL.NR, side.status === "NR" ? "neutral" : "success"),
      ),
      side.updated_at
        ? h("span", { class: "sub assessment-when" }, formatDateTime(side.updated_at))
        : null,
    );
  };

  function render(data) {
    const adminEdit = canEdit && data.admin_edit;
    const club = data.club_rank ?? {};
    const clubTile = h(
      "div",
      { class: "assessment-summary-tile is-primary assessment-club", "data-tile": "club-rank" },
      h("span", { class: "section-icon", "aria-hidden": "true" }, icon("medal")),
      h("div", { class: "assessment-club-copy" },
        h("span", { class: "assessment-label" }, "Club Rank"),
        h("strong", { class: "assessment-official-rank" }, club.name ?? "Not Rated"),
        club.range ? h("span", { class: "sub" }, club.range) : h("span", { class: "sub" }, "No rating yet"),
      ),
      h("div", { class: "assessment-club-basis" },
        badge("Automatic", "neutral"),
        h("span", { class: "sub" }, club.best_points != null
          ? `Based on: ${club.source === "doubles" ? "Doubles" : "Singles"} Rating (${formatPoints(club.best_points)})`
          : "Your higher rating determines your rank."),
      ),
    );
    const summary = h(
      "div",
      { class: "assessment-summary is-ratings" },
      ratingTile(data, "singles", "Singles Rating", adminEdit),
      ratingTile(data, "doubles", "Doubles Rating", adminEdit),
      clubTile,
    );

    // initial self-submission: only for a member's own profile, and only for ratings not yet submitted
    let form = null;
    if (data.can_self_submit && !staff) {
      const error = h("p", { class: "field-error", role: "alert", hidden: true });
      const field = (id, label, side) =>
        side.points == null
          ? h(
            "div",
            { class: "field" },
            h("label", { for: id }, label),
            h("input", {
              class: "input", id, name: id, type: "number", inputmode: "decimal", min: "2", max: "8", step: "0.001",
              placeholder: "NR (not rated)",
            }),
            h("span", { class: "sub" }, "2.000–8.000 · Up to three decimal places"),
          )
          : null;
      const singles = field("self-singles", "Singles Rating", data.singles);
      const doubles = field("self-doubles", "Doubles Rating", data.doubles);
      const read = (el) => {
        const raw = el?.querySelector("input").value.trim() ?? "";
        if (!raw) return { value: null };
        const n = Number(raw);
        return /^\d(\.\d{1,3})?$/.test(raw) && n >= 2 && n <= 8 ? { value: n } : { invalid: true };
      };
      form = h(
        "fieldset",
        { class: "self-assessment-controls" },
        h("div", { class: "assessment-form-head" },
          h("h4", {}, "Set your starting ratings"),
          h("p", { class: "sub" }, "Enter the ratings you know. Leave a field empty to keep it not rated."),
        ),
        h("div", { class: "assessment-fields" }, singles, doubles),
        error,
        h(
          "div",
          { class: "assessment-actions" },
          button({
            label: "Save Ratings",
            icon: "check",
            variant: "primary",
            type: "button",
            onClick: async () => {
              error.hidden = true;
              const s = read(singles);
              const d = read(doubles);
              if (s.invalid || d.invalid) {
                error.textContent = "Enter a rating from 2.000 to 8.000 with at most three decimals.";
                error.hidden = false;
                return;
              }
              if (s.value == null && d.value == null) {
                error.textContent = "Enter a Singles rating, a Doubles rating, or both.";
                error.hidden = false;
                return;
              }
              const payload = { p_singles: s.value, p_doubles: d.value };
              const fingerprint = JSON.stringify(payload);
              if (intent?.fingerprint !== fingerprint) intent = { fingerprint, key: api.newKey() };
              form.disabled = true;
              card.setAttribute("aria-busy", "true");
              try {
                await api.rpc("submit_member_ratings", { ...payload, p_key: intent.key });
                intent = null;
                await load();
              } catch (e) {
                error.textContent = ["22023", "42501"].includes(e?.code)
                  ? e.cause?.message || e.message
                  : "Ratings could not be saved. Please try again.";
                error.hidden = false;
              } finally {
                form.disabled = false;
                card.setAttribute("aria-busy", "false");
              }
            },
          }),
        ),
      );
    }

    const locked = !form && !adminEdit;
    body.replaceChildren(
      h(
        "div",
        { class: "assessment-content" },
        summary,
        form,
        locked ? h(
          "div",
          { class: "assessment-footer" },
          locked
            ? h(
              "p",
              { class: "assessment-lock-note" },
              icon("lock"),
              h("span", {}, "Only an admin can update your ratings."),
            )
            : null,
        ) : null,
      ),
    );
  }
  load();
  return card;
}
