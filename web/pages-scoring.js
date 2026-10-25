// Scoring rules page (PLAN 7.1): how a match is scored, and how a tied table is split.
//   * A rule sets games to win, points per game, win by, an optional point cap, the forfeit score and the tiebreak order.
//   * A division copies the rule it uses when it is created, so editing or deleting a rule never changes a running event.
//   * The database checks every value; this page shows its answer in plain words. Edits check the row's version and
//     deletes need a reason.
import {
  adminHero,
  attachPagePattern,
  badge,
  button,
  dataTable,
  h,
  icon,
  iconButton,
  inputWithIcon,
  openModal,
  selectControl,
  toast,
} from "./ui.js";

const TIEBREAKS = [
  { value: "head_to_head", label: "Head-to-head (among those tied)" },
  { value: "game_diff", label: "Game Difference" },
  { value: "point_diff", label: "Point Difference" },
  { value: "points_for", label: "Points Scored" },
  { value: "coin_toss", label: "Coin toss (random, final)" },
];
const TIEBREAK_LABEL = {
  match_wins: "Wins",
  ...Object.fromEntries(
    TIEBREAKS.map((t) => [t.value, t.label.split(" (")[0]]),
  ),
};
const SELECT =
  "id,name,games_to_win,points_per_game,win_by,point_cap,forfeit_score,tiebreak_order,is_active,version";

function messageOf(e, fallback) {
  if (e?.code === "23505" || e?.kind === "duplicate") {
    return "A scoring rule with that name already exists. Choose a different name.";
  }
  const own = ["22023", "42501", "23503", "23514", "CP422", "CP409"].includes(
    e?.code,
  ) && e.cause?.message;
  return own || e?.message || fallback;
}

export function createScoringPages({ api, getOrgId }) {
  function scoringPage() {
    const page = h("div", {
      class: "page admin-dashboard admin-members-page admin-scoring-page",
    });
    attachPagePattern(page);
    const body = h("div", { class: "scoring-body" });
    const state = { status: "loading", rules: [] };

    async function refresh() {
      state.status = state.rules.length ? "refreshing" : "loading";
      draw();
      try {
        state.rules = await api.read((c) =>
          c.from("scoring_rules").select(SELECT).is("deleted_at", null).order(
            "name",
          )
        ) ?? [];
        state.status = "ready";
      } catch {
        state.status = "error";
      }
      draw();
    }

    const errorLine = () =>
      h("p", { class: "field-error form-error", role: "alert", hidden: true });
    const showError = (el, message) => {
      el.textContent = message;
      el.hidden = false;
      return false;
    };
    const field = (id, label, control, hint, iconName) =>
      h(
        "div",
        { class: "field" },
        label ? h("label", { for: id }, label) : null,
        iconName ? inputWithIcon(control, iconName) : control,
        hint
          ? h("span", { class: "field-hint", id: `${id}-hint` }, hint)
          : null,
      );
    const input = (id, name, props = {}) =>
      h("input", { class: "input", id, name, ...props });

    function ruleModal(row) {
      const editing = Boolean(row);
      const key = row?.id ?? api.newKey();
      const error = errorLine();
      const chosen = (row?.tiebreak_order ?? [
        "match_wins",
        "head_to_head",
        "point_diff",
      ]).filter((t) => t !== "match_wins");
      const slots = [0, 1, 2, 3].map((i) =>
        selectControl(
          { class: "input select-input", id: `sc-tb-${i}`, name: `tb${i}` },
          h("option", { value: "" }, "— None —"),
          ...TIEBREAKS.map((t) =>
            h("option", {
              value: t.value,
              selected: chosen[i] === t.value,
            }, t.label)
          ),
        )
      );
      return openModal({
        title: editing ? "Edit Scoring Rule" : "New Scoring Rule",
        eyebrow: editing ? row.name : "Scoring Rules",
        icon: "medal",
        description:
          "Configure match scoring and the order used to resolve tied standings.",
        size: "lg",
        confirmLabel: editing ? "Save Changes" : "Add Rule",
        body: h(
          "div",
          { class: "form-grid" },
          editing
            ? h(
              "div",
              { class: "member-decision-subject form-grid-wide" },
              h("span", {
                class: "member-avatar is-icon",
                "aria-hidden": "true",
              }, icon("medal")),
              h(
                "div",
                { class: "member-meta" },
                h(
                  "div",
                  { class: "member-decision-name" },
                  h("strong", { class: "member-name" }, row.name),
                  badge(
                    row.is_active ? "Active" : "Inactive",
                    row.is_active ? "success" : "neutral",
                  ),
                ),
                h("span", { class: "sub member-subtext" }, describe(row)),
              ),
            )
            : null,
          h(
            "div",
            { class: "form-grid-wide" },
            field(
              "sc-name",
              "Rule Name *",
              input("sc-name", "name", {
                required: true,
                maxlength: 80,
                value: row?.name ?? "",
                placeholder: "e.g. Best of 3 to 11",
              }),
              null,
              "medal",
            ),
          ),
          h(
            "section",
            { class: "form-section", "aria-label": "Match Scoring" },
            h(
              "div",
              { class: "form-section-head" },
              h(
                "span",
                { class: "form-section-icon", "aria-hidden": "true" },
                icon("trophy"),
              ),
              h(
                "div",
                {},
                h("h3", { class: "form-section-title" }, "Match Scoring"),
                h(
                  "p",
                  { class: "form-section-description" },
                  "Set the match length and winning score.",
                ),
              ),
            ),
            h(
              "div",
              { class: "form-grid" },
              field(
                "sc-games",
                "Games to Win *",
                input("sc-games", "games_to_win", {
                  type: "number",
                  min: 1,
                  max: 5,
                  step: 1,
                  required: true,
                  value: row?.games_to_win ?? 1,
                }),
                "1 = single, 2 = best of 3, 3 = best of 5.",
                "trophy",
              ),
              field(
                "sc-points",
                "Points per Game *",
                input("sc-points", "points_per_game", {
                  type: "number",
                  min: 1,
                  max: 99,
                  step: 1,
                  required: true,
                  value: row?.points_per_game ?? 11,
                }),
                null,
                "layers",
              ),
              field(
                "sc-winby",
                "Win by *",
                input("sc-winby", "win_by", {
                  type: "number",
                  min: 1,
                  max: 5,
                  step: 1,
                  required: true,
                  value: row?.win_by ?? 2,
                }),
                "Required lead in points.",
                "checkCircle",
              ),
              field(
                "sc-cap",
                "Point Cap",
                input("sc-cap", "point_cap", {
                  type: "number",
                  min: 1,
                  max: 99,
                  step: 1,
                  value: row?.point_cap ?? "",
                  placeholder: "No Cap",
                }),
                "Optional. Leave empty for no cap.",
                "lock",
              ),
              h(
                "div",
                { class: "form-grid-wide" },
                field(
                  "sc-forfeit",
                  "Forfeit Score *",
                  input("sc-forfeit", "forfeit_score", {
                    type: "number",
                    min: 0,
                    max: 99,
                    step: 1,
                    required: true,
                    value: row?.forfeit_score ?? 11,
                  }),
                  "Winner's points per game; the opponent receives 0.",
                  "alertCircle",
                ),
              ),
            ),
          ),
          h(
            "section",
            { class: "form-section", "aria-label": "Tiebreak Order" },
            h(
              "div",
              { class: "form-section-head" },
              h(
                "span",
                { class: "form-section-icon", "aria-hidden": "true" },
                icon("shuffle"),
              ),
              h(
                "div",
                {},
                h("h3", { class: "form-section-title" }, "Tiebreak Order"),
                h(
                  "p",
                  { class: "form-section-description" },
                  "Match wins come first, followed by these criteria.",
                ),
              ),
            ),
            h(
              "div",
              { class: "form-section-fields" },
              ...slots.map((slot, index) =>
                field(
                  `sc-tb-${index}`,
                  `${index + 1}. ${
                    ["First", "Second", "Third", "Fourth"][index]
                  } Tiebreak`,
                  slot,
                  null,
                  "shuffle",
                )
              ),
              h(
                "p",
                { class: "field-hint" },
                "Each criterion can be used once. Choose None to skip a position.",
              ),
            ),
          ),
          h("div", { class: "form-grid-wide" }, error),
        ),
        onConfirm: async (form) => {
          const name = String(form.get("name") ?? "").trim();
          const num = (k) => Number(form.get(k));
          if (!name) return showError(error, "Enter a name.");
          for (
            const [k, lo, hi, label] of [
              ["games_to_win", 1, 5, "Games to Win"],
              ["points_per_game", 1, 99, "Points per Game"],
              ["win_by", 1, 5, "Win By"],
              ["forfeit_score", 0, 99, "Forfeit Score"],
            ]
          ) {
            const v = num(k);
            if (!Number.isInteger(v) || v < lo || v > hi) {
              return showError(
                error,
                `${label} is a whole number from ${lo} to ${hi}.`,
              );
            }
          }
          const capText = String(form.get("point_cap") ?? "").trim();
          const cap = capText === "" ? null : Number(capText);
          if (
            cap !== null &&
            (!Number.isInteger(cap) || cap < num("points_per_game") || cap > 99)
          ) {
            return showError(
              error,
              "The point cap is a whole number, at least the points per game.",
            );
          }
          const picked = [0, 1, 2, 3].map((i) =>
            String(form.get(`tb${i}`) ?? "")
          )
            .filter(Boolean);
          if (new Set(picked).size !== picked.length) {
            return showError(error, "Choose each tiebreak only once.");
          }
          const fields = {
            name,
            games_to_win: num("games_to_win"),
            points_per_game: num("points_per_game"),
            win_by: num("win_by"),
            point_cap: cap,
            forfeit_score: num("forfeit_score"),
            tiebreak_order: ["match_wins", ...picked],
          };
          try {
            if (editing) {
              const done = await api.read((c) =>
                c.from("scoring_rules").update(fields).eq("id", row.id).eq(
                  "version",
                  row.version,
                ).select("id")
              );
              if (!done?.length) {
                return showError(
                  error,
                  "Someone else changed this rule. Close this window and open it again.",
                );
              }
            } else {
              await api.create("scoring_rules", key, {
                org_id: getOrgId(),
                ...fields,
              });
            }
            toast(editing ? "Rule saved." : "Rule added.", { tone: "success" });
            await refresh();
          } catch (e) {
            return showError(
              error,
              messageOf(e, "That did not work. Please try again."),
            );
          }
        },
      });
    }

    function deleteModal(row) {
      const key = api.newKey();
      const error = errorLine();
      const count = h("output", {
        class: "decision-reason-count",
        id: "sc-reason-count",
        for: "sc-reason",
      }, "0 / 500");
      return openModal({
        title: "Delete This Scoring Rule",
        eyebrow: row.name,
        icon: "alert",
        destructive: true,
        confirmLabel: "Delete",
        body: h(
          "div",
          { class: "member-decision" },
          h(
            "div",
            { class: "member-decision-subject" },
            h(
              "span",
              { class: "member-avatar is-icon", "aria-hidden": "true" },
              icon("medal"),
            ),
            h(
              "div",
              { class: "member-meta" },
              h(
                "div",
                { class: "member-decision-name" },
                h("strong", { class: "member-name" }, row.name),
                badge(
                  row.is_active ? "Active" : "Inactive",
                  row.is_active ? "success" : "neutral",
                ),
              ),
              h("span", { class: "sub member-subtext" }, describe(row)),
            ),
          ),
          h(
            "div",
            { class: "stack" },
            h(
              "div",
              { class: "modal-callout is-danger" },
              h(
                "span",
                { class: "modal-callout-icon", "aria-hidden": "true" },
                icon("trash"),
              ),
              h(
                "div",
                { class: "modal-callout-text" },
                h(
                  "strong",
                  { class: "decision-impact-title" },
                  "Rule will be removed",
                ),
                h(
                  "p",
                  { class: "decision-impact-text" },
                  "Divisions already using this rule keep their own copy. It will no longer be offered for new divisions.",
                ),
              ),
            ),
            h(
              "div",
              { class: "field" },
              h(
                "div",
                { class: "decision-field-heading" },
                h(
                  "label",
                  { for: "sc-reason" },
                  "Reason",
                  h("span", { class: "decision-required" }, " *"),
                ),
                count,
              ),
              h("textarea", {
                class: "input textarea",
                id: "sc-reason",
                name: "reason",
                rows: 4,
                minlength: 3,
                maxlength: 500,
                required: true,
                placeholder:
                  "Provide context or explanation for this decision...",
                "aria-describedby": "sc-reason-help sc-reason-count",
                onInput: (event) => {
                  count.textContent = `${event.target.value.length} / 500`;
                },
              }),
              h("p", {
                class: "muted decision-reason-help",
                id: "sc-reason-help",
              }, "At least 3 characters. Maximum 500 characters."),
            ),
          ),
          error,
        ),
        onConfirm: async (form) => {
          const reason = String(form.get("reason") ?? "").trim();
          if (reason.length < 3) {
            return showError(
              error,
              "Please give a reason (at least 3 characters).",
            );
          }
          try {
            await api.rpc("soft_delete", {
              p_table: "scoring_rules",
              p_id: row.id,
              p_reason: reason,
              p_key: key,
            });
            toast("Deleted.", { tone: "success" });
            await refresh();
          } catch (e) {
            return showError(
              error,
              messageOf(e, "That did not work. Please try again."),
            );
          }
        },
      });
    }

    const describe = (r) =>
      r.games_to_win === 1
        ? "Single Game"
        : `Best of ${2 * r.games_to_win - 1}`;

    function draw() {
      body.replaceChildren(
        h(
          "div",
          { class: "member-directory-card is-auto-grid" },
          h(
            "div",
            { class: "table-host" },
            dataTable({
              searchState: state,
              schema: {
                columns: [
                  {
                    key: "name",
                    label: "Rule",
                    render: (r) =>
                      h(
                        "span",
                        {},
                        r.name,
                        h("span", { class: "sub" }, describe(r)),
                      ),
                  },
                  {
                    key: "game",
                    label: "Each Game",
                    render: (r) =>
                      `To ${r.points_per_game}, win by ${r.win_by}${
                        r.point_cap ? `, cap ${r.point_cap}` : ""
                      }`,
                  },
                  {
                    key: "forfeit",
                    label: "Forfeit",
                    align: "right",
                    render: (r) => `${r.forfeit_score}–0`,
                  },
                  {
                    key: "ties",
                    label: "Ties Are Split by",
                    render: (r) =>
                      r.tiebreak_order.map((t) => TIEBREAK_LABEL[t] ?? t).join(
                        ", ",
                      ),
                  },
                  {
                    key: "status",
                    label: "Status",
                    render: (r) =>
                      r.is_active
                        ? badge("Active", "success")
                        : badge("Inactive", "neutral"),
                  },
                  {
                    key: "actions",
                    label: "Action",
                    align: "center",
                    render: (r) =>
                      h(
                        "span",
                        { class: "row-actions" },
                        iconButton({
                          label: `Edit ${r.name}`,
                          icon: "edit",
                          size: "sm",
                          variant: "edit",
                          onClick: () => ruleModal(r),
                        }),
                        iconButton({
                          label: `Delete ${r.name}`,
                          icon: "trash",
                          size: "sm",
                          variant: "danger",
                          onClick: () => deleteModal(r),
                        }),
                      ),
                  },
                ],
              },
              rows: state.rules,
              state: state.status,
              ariaLabel: "Scoring Rules",
              onRetry: refresh,
              emptyTitle: "No scoring rules yet",
              emptyText:
                "Add a rule so divisions know how their matches are scored.",
            }),
          ),
        ),
      );
    }

    page.append(
      adminHero({
        title: "Scoring Rules",
        chip: "Scoring Management",
        description:
          "How a match is scored and how ties in a table are split. Divisions keep a copy of the rule they were created with.",
        actions: [
          button({
            label: "New Scoring Rule",
            icon: "plus",
            variant: "primary",
            onClick: () => ruleModal(null),
          }),
        ],
      }),
      body,
    );
    refresh();
    return page;
  }

  return { scoringPage };
}
