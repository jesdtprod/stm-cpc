// Ratings on screen (PLAN 8.4d/8.4e): every player has a Singles rating and a Doubles rating (2.000-8.000). This module
// holds the shared pieces: the rating value with its provisional/unrated label, the history table, the assessment form
// (ranks.override) and the admin panel that prepares the members and turns ratings on. Used by the Ranking, Home and
// Member Details pages. Nothing here calculates a rating: the database does, and checks every permission.
import { badge, dataTable, h, icon, openModal, toast } from "./ui.js";
import { can } from "./lib/permissions.js";
import { formatDateTime } from "./lib/dates.js";

export const PROVISIONAL_MATCHES = 5;
export const DISCIPLINES = ["singles", "doubles"];
export const DISCIPLINE_LABEL = { singles: "Singles", doubles: "Doubles" };
const SETTING = "ranks.cpc_points_enabled";

export const formatPoints = (value) =>
  value === null || value === undefined ? null : Number(value).toFixed(3);

function messageOf(e, fallback) {
  const own = ["22023", "42501", "CP409", "CP422"].includes(e?.code) && e.cause?.message;
  return own || e?.message || fallback;
}

/** Label for one rating: the value, or Unrated; and the smaller line under it. */
export function ratingLabel({ points, matches }, hasRank = false) {
  if (points === null || points === undefined) {
    return {
      value: "Unrated",
      sub: hasRank ? "Not assessed yet" : "Provisional Beginner Low",
      tone: "neutral",
    };
  }
  const count = Number(matches) || 0;
  return {
    value: formatPoints(points),
    // Only an unrated player is called provisional; an assessed rating is shown as a normal rating.
    sub: count === 0 ? "Assessed · no matches yet" : `${count} ${count === 1 ? "match" : "matches"} played`,
    tone: "success",
  };
}

/** One discipline of a ranking-list row (singles_points, singles_matches, ...). */
export const ratingOf = (row, discipline) => ({
  points: row[`${discipline}_points`],
  matches: row[`${discipline}_matches`],
  provisional: row[`${discipline}_provisional`],
  version: row[`${discipline}_version`],
});

/** The table cell: the rating on top, the muted line below (shared .sub class). */
export function ratingCell(row, discipline, hasRank) {
  const rating = ratingOf(row, discipline);
  if (rating.points === undefined) return h("span", { class: "sub" }, "—");
  const label = ratingLabel(rating, hasRank);
  return h(
    "div",
    { class: "cpc-points-cell" },
    h("strong", { class: `cpc-points-value${rating.points == null ? " is-unrated" : ""}` }, label.value),
    h("span", { class: "sub cpc-points-sub" }, label.sub),
  );
}

/** A member's own two ratings, read through row-level security (self, or staff with members.read). */
export async function loadMemberRatings(api, memberId) {
  const rows = memberId
    ? await api.read((c) =>
      c.from("member_cpc_ratings").select("discipline,points,eligible_match_count,version")
        .eq("member_id", memberId).is("deleted_at", null)
    ) ?? []
    : [];
  const out = {};
  for (const discipline of DISCIPLINES) {
    const r = rows.find((x) => x.discipline === discipline);
    const matches = r?.eligible_match_count ?? 0;
    out[discipline] = {
      points: r?.points ?? null,
      matches,
      provisional: r?.points != null && matches < PROVISIONAL_MATCHES,
      version: r?.version ?? 0,
    };
  }
  return out;
}

export function pointsHistoryTable(rows, state, onRetry, filter) {
  const signed = (n) => `${n >= 0 ? "+" : "−"}${Math.abs(n).toFixed(3)}`;
  const table = dataTable({
    filter,
    schema: {
      columns: [
        { key: "when", label: "When", render: (r) => formatDateTime(r.occurred_at) },
        {
          key: "points",
          label: "Rating",
          render: (r) => {
            const status = r.is_reversal
              ? badge("Reversal", "warning")
              : r.reversed
              ? badge("Reversed", "neutral")
              : null;
            return h(
              "div",
              { class: "rank-history-change" },
              h(
                "span",
                { class: "rank-change-flow" },
                badge(DISCIPLINE_LABEL[r.discipline] ?? "Rating", "info"),
                r.points_before == null
                  ? h("span", { class: "rank-change-prefix" }, "Set to")
                  : badge(formatPoints(r.points_before), "neutral"),
                r.points_before == null ? null : h("span", { class: "rank-change-arrow", "aria-hidden": "true" }, "→"),
                badge(formatPoints(r.points_after), r.is_reversal ? "warning" : "success"),
                r.points_delta == null
                  ? null
                  : h("span", { class: "sub rank-change-sub" }, signed(Number(r.points_delta))),
              ),
              status,
            );
          },
        },
        {
          key: "why",
          label: "Why",
          render: (r) =>
            h(
              "div",
              { class: "rank-history-why" },
              h(
                "span",
                { class: "rank-history-reason" },
                r.entry_type === "admin_assessment" ? `Assessed: ${r.reason ?? "—"}` : r.reason ?? "—",
              ),
              r.event_name
                ? h("span", { class: "sub rank-history-event" }, [r.event_name, r.division_name].filter(Boolean).join(" · "))
                : null,
            ),
        },
      ],
    },
    rows,
    state,
    ariaLabel: "Rating History",
    onRetry,
    emptyTitle: "No rating history yet",
    emptyText: "Ratings appear here after an administrator assesses a starting value or a division is finalized.",
  });
  table.classList.add("rank-history-table-wrap");
  return table;
}

export async function pointsHistoryModal(api, memberId, name) {
  let rows = [];
  let status = "ready";
  try {
    rows = await api.rpc("cpc_points_history_view", { p_member_id: memberId }) ?? [];
  } catch {
    status = "error";
  }
  return openModal({
    title: "Rating History",
    eyebrow: name,
    icon: "clock",
    size: "lg",
    confirmLabel: "Close",
    body: pointsHistoryTable(rows, status),
    onConfirm: () => {},
  });
}

/**
 * Admin form: assess a starting value (ranks.override) for Singles or Doubles. Versioned and idempotent; the database
 * records and audits it. `row` is a ranking-list row (singles_points, doubles_version, ...) or `{ member_id, display_name,
 * singles: {...}, doubles: {...} }` as returned by loadMemberRatings.
 */
export function assessPointsModal({ api, row, discipline = "singles", onDone }) {
  const key = api.newKey();
  const error = h("p", { class: "field-error form-error", role: "alert", hidden: true });
  const ratingFor = (d) => row.singles ? row[d] ?? {} : ratingOf(row, d);
  const select = h(
    "select",
    { class: "input select-input", id: "cpc-discipline", name: "discipline" },
    ...DISCIPLINES.map((d) => h("option", { value: d, selected: d === discipline }, `${DISCIPLINE_LABEL[d]} Rating`)),
  );
  const input = h("input", {
    class: "input", id: "cpc-points", name: "points", type: "number", inputmode: "decimal",
    min: "2", max: "8", step: "0.001", required: true,
  });
  const sync = () => {
    const current = ratingFor(select.value);
    input.value = current.points == null ? "" : formatPoints(current.points);
  };
  sync();
  select.addEventListener("change", sync);
  return openModal({
    title: "Assess Rating",
    eyebrow: row.display_name,
    icon: "medal",
    confirmLabel: "Save Rating",
    body: h(
      "div",
      { class: "stack" },
      h(
        "p",
        { class: "muted" },
        "Sets the rating this player starts from in Singles or Doubles. It is kept in their rating history and the audit log. Genuine beginners start at 2.000.",
      ),
      h("div", { class: "field" }, h("label", { for: "cpc-discipline" }, "Rating *"), select),
      h("div", { class: "field" }, h("label", { for: "cpc-points" }, "Points (2.000–8.000) *"), input),
      h(
        "div",
        { class: "field" },
        h("label", { for: "cpc-reason" }, "Reason *"),
        h("textarea", { class: "input textarea", id: "cpc-reason", name: "reason", rows: 3, maxlength: 500, required: true }),
      ),
      error,
    ),
    onConfirm: async (form) => {
      const fail = (m) => {
        error.textContent = m;
        error.hidden = false;
        return false;
      };
      const chosen = String(form.get("discipline") ?? "singles");
      const raw = String(form.get("points") ?? "").trim();
      const points = Number(raw);
      if (!/^\d(\.\d{1,3})?$/.test(raw) || points < 2 || points > 8) {
        return fail("Enter a rating from 2.000 to 8.000 with at most three decimals.");
      }
      const reason = String(form.get("reason") ?? "").trim();
      if (reason.length < 3) return fail("Give a reason of at least 3 characters.");
      try {
        await api.rpc("set_member_cpc_rating", {
          p_member_id: row.member_id,
          p_discipline: chosen,
          p_points: points,
          p_expected_version: ratingFor(chosen).version ?? 0,
          p_key: key,
          p_reason: reason,
        });
        toast("Rating saved.", { tone: "success" });
        await onDone?.();
      } catch (e) {
        return fail(messageOf(e, "That did not work. Try again."));
      }
    },
  });
}

/** Staff panel: prepare every member (unrated Singles and Doubles records), then turn ratings on or off. */
export function cpcAdminPanel({ api, onChange }) {
  const host = h("div", { class: "card cpc-admin-panel" });
  const run = async (task, done) => {
    try {
      await task();
      toast(done, { tone: "success" });
      await onChange?.();
      await draw();
    } catch (e) {
      toast(messageOf(e, "That did not work. Try again."), { tone: "danger" });
    }
  };
  async function draw() {
    let s;
    try {
      s = await api.rpc("cpc_points_status");
    } catch {
      host.replaceChildren();
      return;
    }
    const ready = s.prepared >= s.active_members;
    const actions = [];
    if (can("ranks.override") && !ready) {
      actions.push(h("button", {
        class: "btn btn-secondary", type: "button",
        onClick: () => run(() => api.rpc("initialize_member_cpc_ratings", { p_key: api.newKey() }), "Members prepared. Everyone is unrated until assessed."),
      }, "Prepare Members"));
    }
    if (can("settings.manage") && ready) {
      const turn = (on) => run(
        () => api.rpc("update_setting", { p_key: SETTING, p_value: on, p_reason: on ? "Ratings turned on" : "Ratings turned off", p_idem: api.newKey() }),
        on ? "Ratings are on." : "Ratings are off.",
      );
      actions.push(h("button", {
        class: s.enabled ? "btn btn-secondary" : "btn btn-primary", type: "button", onClick: () => turn(!s.enabled),
      }, s.enabled ? "Turn Off" : "Turn On"));
    }
    host.replaceChildren(
      h("div", { class: "cpc-admin-icon", "aria-hidden": "true" }, icon("medal")),
      h(
        "div",
        { class: "cpc-admin-copy" },
        h("div", { class: "cpc-admin-head" },
          h("strong", {}, "Singles and Doubles Ratings"),
          badge(s.enabled ? "On" : "Off", s.enabled ? "success" : "neutral")),
        h("p", { class: "sub cpc-admin-description" },
          `${s.prepared} of ${s.active_members} members prepared · ${s.rated_singles} rated in Singles · ${s.rated_doubles} rated in Doubles. ` +
            (s.enabled
              ? "New divisions use ratings; every player needs an assessed Singles or Doubles rating (the division's format) before the draw."
              : "Old rank rules remain active until the starting ratings are assessed and ratings are turned on.")),
      ),
      ...(actions.length ? [h("div", { class: "actions cpc-admin-actions" }, ...actions)] : []),
    );
  }
  draw();
  return host;
}
