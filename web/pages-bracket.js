// Bracket page (PLAN 7.3): one division's stages, with the standings table and the matches of each stage.
//   * Everyone signed in can read it once the division is drawn: standings and matches come from the server
//     (stage_standings, stage_matches), already worked out, so this page only displays them.
//   * People with the scoring permissions also get the score buttons: enter a score (and finalize it), finalize,
//     record a forfeit, correct a finished result. The database checks every rule again and its messages are shown as they
//     are. Page address: #/bracket?division=<division id>.
import {
  badge,
  button,
  dataTable,
  h,
  icon,
  iconButton,
  memberHero,
  openModal,
  selectControl,
  tabs,
  toast,
} from "./ui.js";
import { can } from "./lib/permissions.js";
import { createBracketViews, MATCH_STATUS, roundName } from "./lib/bracket-views.js";
import { finishedGamesError } from "./lib/score-validation.js";

const STAGE_LABEL = {
  round_robin: "Round Robin",
  single_elimination: "Single Elimination",
  pool_play: "Pool Play",
  best_of_n_playoff: "Best-of Playoff",
  split_single_elimination: "Split Single Elimination",
};
const STAGE_STATUS = {
  pending: "Not Started",
  drawn: "Drawn",
  in_progress: "In Progress",
  completed: "Completed",
  cancelled: "Cancelled",
};

/** Knockout rounds are named from the end: the Final, the Semifinals, the Quarterfinals, then Round of 16 ... */

function messageOf(e, fallback) {
  const own = ["22023", "42501", "23505", "CP422"].includes(e?.code) &&
    e.cause?.message;
  return own || e?.message || fallback;
}

export function createBracketPages({ api }) {
  function bracketPage() {
    const divisionId = new URLSearchParams(location.hash.split("?")[1] ?? "")
      .get("division");
    const page = h("div", { class: "page bracket-page" });
    const body = h("div", { class: "bracket-body" });
    const state = {
      status: "loading",
      division: null,
      stageId: null,
      standings: [],
      matches: [],
      results: [],
      playersByTeam: new Map(),
      detail: "loading",
      scoringRules: null,
    };

    const stage = () =>
      state.division?.stages?.find((s) => s.id === state.stageId);

    async function load() {
      if (!divisionId) {
        state.status = "error";
        return draw();
      }
      try {
        const rows = await api.read((c) =>
          c.from("divisions").select(
            "id,name,status,format,category:categories(name),event:events(name),stages:division_stages(id,stage_no,stage_type,status,scoring_rule_snapshot,round_scoring)",
          ).eq("id", divisionId)
        );
        const division = rows?.[0];
        if (!division) throw new Error("not found");
        division.stages.sort((a, b) => a.stage_no - b.stage_no);
        state.division = division;
        if (can("events.manage") && division.stages.some((x) => x.stage_type === "split_single_elimination")) {
          state.scoringRules ??= await api.read((c) =>
            c.from("scoring_rules").select("id,name").is("deleted_at", null).eq("is_active", true).order("name")
          ).catch(() => []);
        }
        state.stageId ??= (division.stages.find((s) =>
          ["drawn", "in_progress"].includes(s.status)
        ) ?? division.stages[0])?.id;
        state.status = "ready";
        draw();
        if (division.status === "finalized") {
          state.results = await api.rpc("division_results_view", {
            p_division_id: division.id,
          }) ?? [];
        }
        await loadStage();
      } catch {
        state.status = "error";
        draw();
      }
    }

    async function loadStage() {
      if (!state.stageId) return;
      state.detail = state.matches.length ? "refreshing" : "loading";
      draw();
      try {
        const [standings, matches, rosters] = await Promise.all([
          api.rpc("stage_standings", { p_stage_id: state.stageId }),
          api.rpc("stage_matches", { p_stage_id: state.stageId }),
          Promise.resolve(api.rpc("public_event_rosters")).catch(() => []),
        ]);
        state.standings = standings ?? [];
        state.matches = matches ?? [];
        const playersByTeam = new Map();
        for (const r of rosters ?? []) {
          if (r.division_id && state.division?.id && r.division_id !== state.division.id) continue;
          const teamKey = String(r.team_name ?? "").trim().toUpperCase();
          const players = [r.p1_name, r.p2_name].filter(Boolean).join(" & ");
          if (teamKey && players && players.toUpperCase() !== teamKey) {
            playersByTeam.set(teamKey, players);
          }
        }
        state.playersByTeam = playersByTeam;
        state.detail = "ready";
      } catch {
        state.detail = "error";
      }
      draw();
    }

    // ------------------------------------------------------------ forms
    const errorLine = () =>
      h("p", { class: "field-error form-error", role: "alert", hidden: true });
    const showError = (el, message) => {
      el.textContent = message;
      el.hidden = false;
      return false;
    };
    const num = (id, name, value) =>
      h("input", {
        class: "input score-input",
        id,
        name,
        type: "number",
        min: 0,
        max: 99,
        step: 1,
        inputmode: "numeric",
        onKeyDown: (event) => {
          if (!event.ctrlKey && !event.metaKey && ["-", "+", ".", ",", "e", "E"].includes(event.key)) event.preventDefault();
        },
        onBeforeInput: (event) => {
          if (event.data && /[^0-9]/.test(event.data)) event.preventDefault();
        },
        onPaste: (event) => {
          if (!/^[0-9]+$/.test(event.clipboardData?.getData("text") ?? "")) event.preventDefault();
        },
        value: value ?? "",
        "aria-label": id,
      });

    function gameRows(m, maxGames) {
      return Array.from({ length: maxGames }, (_, i) => {
        const g = m.games?.[i];
        return h(
          "div",
          { class: "score-row" },
          num(`g${i}-a`, `a${i}`, g?.a),
          h(
            "span",
            { class: "score-label" },
            h("span", { class: "score-label-tag" }, "GAME"),
            String(i + 1).padStart(2, "0"),
          ),
          num(`g${i}-b`, `b${i}`, g?.b),
        );
      });
    }
    /** Reads the filled-in rows; a half-filled row is an error, empty rows at the end are ignored. */
    function readGames(form, maxGames, match) {
      const games = [];
      for (let i = 0; i < maxGames; i++) {
        const a = String(form.get(`a${i}`) ?? "").trim();
        const b = String(form.get(`b${i}`) ?? "").trim();
        if (a === "" && b === "") continue;
        if (a === "" || b === "") {
          return { error: `Game ${i + 1} needs both scores.` };
        }
        if (games.length !== i) {
          return { error: "Fill the games in order, without gaps." };
        }
        if (!/^[0-9]+$/.test(a) || !/^[0-9]+$/.test(b)) {
          return { error: `Game ${i + 1}: enter whole-number scores from 0 to 99.` };
        }
        games.push({ a: Number(a), b: Number(b) });
      }
      return { games, error: finishedGamesError(games, rule(match)) };
    }
    // Split Single Elimination: a bracket round (counted back from the final) can have its own rule; the database decides
    // the same way (core.match_scoring_rule). Round 1 and anything not set use the stage rule.
    const ROUND_LABEL = { 0: "final", 1: "semifinal", 2: "quarterfinal" };
    const rule = (m) => {
      const st = stage();
      const base = st?.scoring_rule_snapshot ?? {};
      if (!m || st?.stage_type !== "split_single_elimination" || !["H", "L"].includes(m.group_label) || !(m.round_no > 1)) {
        return base;
      }
      const last = Math.max(...state.matches.filter((x) => x.group_label === m.group_label).map((x) => x.round_no));
      return st.round_scoring?.[m.group_label]?.[ROUND_LABEL[last - m.round_no]] ?? base;
    };
    const maxGamesOf = (m) => 2 * (rule(m).games_to_win ?? 1) - 1;
    const ruleText = (m) =>
      `Play to ${rule(m).points_per_game}, win by ${rule(m).win_by}${
        rule(m).point_cap ? `, cap ${rule(m).point_cap}` : ""
      }. First to ${rule(m).games_to_win} game${
        rule(m).games_to_win > 1 ? "s" : ""
      } wins.`;

    function scoreBoardCard(m, max) {
      const playersOf = (teamName, direct) =>
        direct ?? (teamName ? state.playersByTeam.get(String(teamName).trim().toUpperCase()) ?? null : null);
      const playersA = playersOf(m.a_name, m.a_players);
      const playersB = playersOf(m.b_name, m.b_players);
      return h(
        "div",
        { class: "score-board-card" },
        h(
          "div",
          { class: "score-head" },
          h(
            "div",
            { class: "score-team-pod" },
            h("span", { class: "score-team-side" }, "Side A"),
            h("strong", {}, m.a_name ?? "To be decided"),
            playersA ? h("span", { class: "sub score-team-players" }, playersA) : null,
          ),
          h("span", { class: "bt-vs score-head-vs", "aria-hidden": "true" }, "VS"),
          h(
            "div",
            { class: "score-team-pod" },
            h("span", { class: "score-team-side" }, "Side B"),
            h("strong", {}, m.b_name ?? "To be decided"),
            playersB ? h("span", { class: "sub score-team-players" }, playersB) : null,
          ),
        ),
        h("div", { class: "score-games-list" }, ...gameRows(m, max)),
      );
    }

    function scoreModal(m) {
      const error = errorLine();
      const max = maxGamesOf(m);
      const canFinal = can("scores.finalize");
      const r = rule(m);
      let dialog = null;
      // Ending the match without a score: Forfeit, Disqualify or Default, one click away inside this form.
      const alternatives = canFinal && m.entry_a_id && m.entry_b_id
        ? h(
          "div",
          { class: "score-alt-actions" },
          h(
            "div",
            { class: "score-alt-head" },
            h("span", { class: "score-alt-title" }, "Or end the match without a score"),
            h("span", { class: "score-alt-badge" }, "Admin Outcome"),
          ),
          h(
            "div",
            { class: "score-alt-buttons" },
            ...[
              ["Forfeit", "Forfeit", "x", "is-forfeit"],
              ["Disqualify", "Disqualification", "alert", "is-disqualify"],
              ["Default", "Default", "clock", "is-default"],
            ].map(([label, kind, ic, cls]) =>
              h(
                "button",
                {
                  type: "button",
                  class: `btn btn-secondary btn-sm score-alt-btn ${cls}`,
                  onClick: () => {
                    dialog?.close();
                    forfeitModal(m, kind);
                  },
                },
                icon(ic),
                h("span", {}, label),
              )
            ),
          ),
        )
        : null;
      dialog = openModal({
        title: "Enter the score",
        eyebrow: `${m.a_name} v ${m.b_name}`,
        icon: "edit",
        confirmLabel: "Save Score",
        body: h(
          "div",
          { class: "stack score-modal-stack" },
          h(
            "div",
            { class: "score-rule-banner" },
            h("span", { class: "score-rule-icon", "aria-hidden": "true" }, icon("trophy")),
            h(
              "div",
              { class: "score-rule-copy" },
              h("span", { class: "score-rule-title" }, r.name ?? "Match Scoring Rule"),
              h("p", { class: "muted" }, ruleText(m)),
            ),
            r.points_per_game
              ? h("span", { class: "score-rule-pill" }, `To ${r.points_per_game} · Win by ${r.win_by ?? 2}`)
              : null,
          ),
          scoreBoardCard(m, max),
          canFinal
            ? h(
              "label",
              { class: "check score-finalize-card", for: "sc-final" },
              h("input", {
                type: "checkbox",
                id: "sc-final",
                name: "finalize",
                checked: true,
              }),
              h(
                "span",
                { class: "score-finalize-copy" },
                h("strong", {}, "Finalize the result now"),
                h("span", { class: "sub" }, "Lock the official match winner and advance teams in the bracket."),
              ),
              h("span", { class: "score-finalize-pill" }, "Recommended"),
            )
            : null,
          alternatives,
          error,
        ),
        onConfirm: async (form) => {
          const r = readGames(form, max, m);
          if (r.error) return showError(error, r.error);
          if (!r.games.length) {
            return showError(error, "Enter at least one game.");
          }
          try {
            await api.rpc("enter_score", {
              p_match_id: m.match_id,
              p_games: r.games,
            });
            if (canFinal && form.get("finalize") === "on") {
              await api.rpc("finalize_match", { p_match_id: m.match_id });
              toast("Match result finalized.", { tone: "success" });
            } else toast("Match score saved.", { tone: "success" });
            await loadStage();
          } catch (e) {
            return showError(
              error,
              messageOf(e, "Unable to complete this action. Please try again."),
            );
          }
        },
      });
      return dialog;
    }

    async function finalize(m) {
      try {
        await api.rpc("finalize_match", { p_match_id: m.match_id });
        toast("Match result finalized.", { tone: "success" });
        await loadStage();
      } catch (e) {
        toast(messageOf(e, "Unable to complete this action. Please try again."), {
          tone: "danger",
        });
      }
    }

    // Forfeit, Disqualification and Default all end the match the same way (the other side wins with the forfeit score); the
    // kind is kept at the start of the reason so the match list and the history show which one it was.
    const FORFEIT_KINDS = {
      Forfeit: { title: "Record a Forfeit", ask: "Who forfeits?", confirm: "Record Forfeit", done: "Match forfeit recorded." },
      Disqualification: { title: "Disqualify a Side", ask: "Who is disqualified?", confirm: "Disqualify", done: "Disqualification recorded." },
      Default: { title: "Record a Default", ask: "Which side defaults?", confirm: "Record Default", done: "Default recorded." },
    };
    function forfeitModal(m, kind = "Forfeit") {
      const error = errorLine();
      const text = FORFEIT_KINDS[kind] ?? FORFEIT_KINDS.Forfeit;
      return openModal({
        title: text.title,
        eyebrow: `${m.a_name} v ${m.b_name}`,
        icon: "alert",
        confirmLabel: text.confirm,
        destructive: true,
        body: h(
          "div",
          { class: "stack" },
          h(
            "p",
            { class: "muted" },
            `The other side wins with the forfeit score (${rule(m).forfeit_score}–0 in each game).`,
          ),
          h(
            "div",
            { class: "field" },
            h("label", { for: "ff-side" }, `${text.ask} *`),
            selectControl(
              { class: "input select-input", id: "ff-side", name: "side" },
              h("option", { value: m.entry_a_id }, m.a_name),
              h("option", { value: m.entry_b_id }, m.b_name),
            ),
          ),
          h(
            "div",
            { class: "field" },
            h("label", { for: "ff-reason" }, "Reason *"),
            h("textarea", {
              class: "input textarea",
              id: "ff-reason",
              name: "reason",
              rows: 2,
              maxlength: 500,
              required: true,
            }),
          ),
          error,
        ),
        onConfirm: async (form) => {
          const reason = String(form.get("reason") ?? "").trim();
          if (reason.length < 3) {
            return showError(error, "Give a reason of at least 3 characters.");
          }
          try {
            await api.rpc("forfeit_match", {
              p_match_id: m.match_id,
              p_forfeiting_entry_id: String(form.get("side")),
              p_reason: kind === "Forfeit" ? reason : `${kind}: ${reason}`,
            });
            toast(text.done, { tone: "success" });
            await loadStage();
          } catch (e) {
            return showError(
              error,
              messageOf(e, "Unable to complete this action. Please try again."),
            );
          }
        },
      });
    }

    function correctModal(m) {
      const error = errorLine();
      const max = maxGamesOf(m);
      const r = rule(m);
      return openModal({
        title: "Correct the Result",
        eyebrow: `${m.a_name} v ${m.b_name}`,
        icon: "refresh",
        confirmLabel: "Correct Result",
        destructive: true,
        body: h(
          "div",
          { class: "stack score-modal-stack" },
          h(
            "div",
            { class: "score-rule-banner" },
            h("span", { class: "score-rule-icon", "aria-hidden": "true" }, icon("refresh")),
            h(
              "div",
              { class: "score-rule-copy" },
              h("span", { class: "score-rule-title" }, r.name ?? "Match Scoring Rule"),
              h(
                "p",
                { class: "muted" },
                `${ruleText(m)} The old result is voided and kept in the history.`,
              ),
            ),
            r.points_per_game
              ? h("span", { class: "score-rule-pill" }, `To ${r.points_per_game} · Win by ${r.win_by ?? 2}`)
              : null,
          ),
          scoreBoardCard(m, max),
          h(
            "div",
            { class: "field" },
            h("label", { for: "co-reason" }, "Reason *"),
            h("textarea", {
              class: "input textarea",
              id: "co-reason",
              name: "reason",
              rows: 2,
              maxlength: 500,
              required: true,
            }),
          ),
          error,
        ),
        onConfirm: async (form) => {
          const r = readGames(form, max, m);
          if (r.error) return showError(error, r.error);
          if (!r.games.length) {
            return showError(error, "Enter the corrected games.");
          }
          const reason = String(form.get("reason") ?? "").trim();
          if (reason.length < 3) {
            return showError(error, "Give a reason of at least 3 characters.");
          }
          try {
            await api.rpc("correct_match", {
              p_match_id: m.match_id,
              p_reason: reason,
              p_games: r.games,
            });
            toast("Match result corrected.", { tone: "success" });
            // a finalized division is re-evaluated: show its new placements
            if (state.division?.status === "finalized") await load();
            else await loadStage();
          } catch (e) {
            return showError(
              error,
              messageOf(e, "Unable to complete this action. Please try again."),
            );
          }
        },
      });
    }

    // ------------------------------------------------------------ views
    const scoreText = (m) =>
      (m.games ?? []).map((g) => `${g.a}–${g.b}`).join(", ") || "—";

    function standingsView() {
      const groups = [
        ...new Set(
          state.standings.map((r) => r.group_label).filter(Boolean),
        ),
      ];
      if (groups.length) {
        return h(
          "div",
          { class: "stack" },
          ...groups.map((g) =>
            h(
              "section",
              { class: "stack" },
              h("h3", {}, `Bracket ${g}`),
              standingsTable(
                state.standings.filter((r) => r.group_label === g),
              ),
            )
          ),
        );
      }
      return standingsTable(state.standings);
    }

    function standingsTable(rows) {
      const showTie = state.standings.some((r) => r.tied);
      return dataTable({
        searchState: state,
        schema: {
          columns: [
            {
              key: "place",
              label: "Place",
              align: "right",
              render: (r) => `${r.place}${r.tied ? " (tied)" : ""}`,
            },
            {
              key: "name",
              label: "Player or Team",
              render: (r) => r.entry_name ?? "—",
            },
            {
              key: "played",
              label: "Played",
              align: "right",
              render: (r) => String(r.played),
            },
            {
              key: "wins",
              label: "Won",
              align: "right",
              render: (r) => String(r.wins),
            },
            {
              key: "losses",
              label: "Lost",
              align: "right",
              render: (r) => String(r.losses),
            },
            {
              key: "games",
              label: "Games",
              align: "right",
              render: (r) => `${r.games_won}–${r.games_lost}`,
            },
            {
              key: "points",
              label: "Points",
              align: "right",
              render: (r) => `${r.points_for}–${r.points_against}`,
            },
          ],
        },
        rows,
        state: state.detail === "refreshing" ? "ready" : state.detail,
        ariaLabel: "Standings",
        searchKey: `standings:${rows[0]?.group_label ?? "all"}`,
        onRetry: loadStage,
        emptyTitle: "No standings yet",
        emptyText: showTie
          ? ""
          : "The table appears once the stage has matches.",
      });
    }

    function actionsFor(m) {
      const live = ["scheduled", "in_progress"].includes(m.status) &&
        m.entry_a_id && m.entry_b_id;
      return h(
        "span",
        { class: "row-actions" },
        live && can("scores.enter")
          ? iconButton({
            label: `Enter score: ${m.a_name} v ${m.b_name}`,
            icon: "edit",
            variant: "edit",
            onClick: () => scoreModal(m),
          })
          : null,
        m.status === "in_progress" && can("scores.finalize")
          ? iconButton({
            label: `Finalize: ${m.a_name} v ${m.b_name}`,
            icon: "check",
            variant: "success",
            onClick: () => finalize(m),
          })
          : null,
        live && can("scores.finalize")
          ? iconButton({
            label: `Forfeit: ${m.a_name} v ${m.b_name}`,
            icon: "x",
            variant: "danger",
            onClick: () => forfeitModal(m),
          })
          : null,
        ["completed", "forfeited"].includes(m.status) && can("scores.correct")
          ? iconButton({
            label: `Correct: ${m.a_name} v ${m.b_name}`,
            icon: "refresh",
            variant: "warning",
            onClick: () => correctModal(m),
          })
          : null,
      );
    }

    // ------------------------------------------------------------ bracket tree (initial round + H / L brackets)
    // The drawings live in lib/bracket-views.js (shared with the public bracketing page); this page adds what a click does.
    const { bracketTree, splitView } = createBracketViews({
      getMatches: () => state.matches,
      getDivisionName: () => state.division?.name,
      getPlayers: (name) => state.playersByTeam.get(String(name).trim().toUpperCase()) ?? null,
      clickable: (card, m) => clickable(card, m),
    });

    // What can be done to a match from its card: the same actions as the old icon buttons, chosen in one place.
    function matchActions(m) {
      const live = ["scheduled", "in_progress"].includes(m.status) && m.entry_a_id && m.entry_b_id;
      const list = [];
      if (live && can("scores.enter")) {
        list.push({ label: "Add Score", icon: "edit", hint: "Enter the games played", run: () => scoreModal(m) });
      }
      if (m.status === "in_progress" && can("scores.finalize")) {
        list.push({ label: "Finalize Result", icon: "check", hint: "Make the entered score final", run: () => finalize(m) });
      }
      if (live && can("scores.finalize")) {
        list.push({ label: "Forfeit", icon: "x", hint: "One side gives up the match", run: () => forfeitModal(m, "Forfeit") });
        list.push({ label: "Disqualify", icon: "alert", hint: "One side is disqualified", run: () => forfeitModal(m, "Disqualification") });
        list.push({ label: "Default", icon: "clock", hint: "One side did not play (no show)", run: () => forfeitModal(m, "Default") });
      }
      if (["completed", "forfeited"].includes(m.status) && can("scores.correct")) {
        list.push({ label: "Correct Result", icon: "refresh", hint: "Change a finished result", run: () => correctModal(m) });
      }
      return list;
    }

    /** Click on a match: a short list of what can be done to it. */
    function matchActionModal(m) {
      const list = matchActions(m);
      if (!list.length) return null;
      // Score entry opens straight away; Forfeit, Disqualify and Default are buttons inside that form.
      if (list[0].label === "Add Score") return scoreModal(m);
      let dialog = null;
      dialog = openModal({
        title: `Match ${m.round_no}.${m.match_no}`,
        eyebrow: `${m.a_name ?? "To be decided"} v ${m.b_name ?? "To be decided"}`,
        icon: "trophy",
        confirmLabel: null,
        cancelLabel: "Close",
        body: h(
          "div",
          { class: "match-action-list", role: "group", "aria-label": "Match actions" },
          ...list.map((a) =>
            h(
              "button",
              {
                type: "button",
                class: "match-action-option",
                onClick: () => {
                  dialog?.close();
                  a.run();
                },
              },
              h("span", { class: "match-action-icon", "aria-hidden": "true" }, icon(a.icon)),
              h("span", { class: "match-action-text" }, h("strong", {}, a.label), h("span", { class: "sub" }, a.hint)),
            )
          ),
        ),
      });
      return dialog;
    }

    /** Makes a match card a button (hand cursor, Enter/Space) when there is something to do. */
    function clickable(card, m) {
      if (!matchActions(m).length) return card;
      card.classList.add("is-clickable");
      card.setAttribute("role", "button");
      card.setAttribute("tabindex", "0");
      card.setAttribute("aria-label", `Match ${m.round_no}.${m.match_no}: ${m.a_name ?? "To be decided"} v ${m.b_name ?? "To be decided"}. Choose an action`);
      card.addEventListener("click", () => matchActionModal(m));
      card.addEventListener("keydown", (event) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          matchActionModal(m);
        }
      });
      return card;
    }

    function matchesView() {
      const rounds = [...new Set(state.matches.map((m) => m.round_no))];
      const schema = {
        columns: [
          {
            key: "no",
            label: "Round",
            align: "right",
            render: (m) => `${m.round_no}.${m.match_no}`,
          },
          {
            key: "a",
            label: "Side A",
            render: (m) =>
              h(
                "span",
                {
                  class: m.winner_entry_id === m.entry_a_id ? "match-win" : "",
                },
                m.a_name ?? "To be decided",
                m.a_label ? h("span", { class: "sub" }, m.a_label) : null,
              ),
          },
          {
            key: "score",
            label: "Score",
            align: "center",
            render: (m) => scoreText(m),
          },
          {
            key: "b",
            label: "Side B",
            render: (m) =>
              h(
                "span",
                {
                  class: m.winner_entry_id === m.entry_b_id ? "match-win" : "",
                },
                m.b_name ?? "To be decided",
                m.b_label ? h("span", { class: "sub" }, m.b_label) : null,
              ),
          },
          {
            key: "status",
            label: "Status",
            render: (m) =>
              h(
                "span",
                {},
                badge(...(MATCH_STATUS[m.status] ?? [m.status, "neutral"])),
                m.status_reason
                  ? h("span", { class: "sub" }, m.status_reason)
                  : null,
              ),
          },
          {
            key: "actions",
            label: "Action",
            align: "center",
            actionCount: 4,
            render: actionsFor,
          },
        ],
      };
      if (!state.matches.length) {
        return dataTable({
          searchState: state,
          schema,
          rows: [],
          state: state.detail === "refreshing" ? "ready" : state.detail,
          ariaLabel: "Matches",
          onRetry: loadStage,
          emptyTitle: "No matches yet",
          emptyText: "Matches appear once the draw has been made.",
        });
      }
      if (stage()?.stage_type === "split_single_elimination") return splitView();
      if (
        stage()?.stage_type === "single_elimination" &&
        !state.matches.some((m) => m.group_label)
      ) {
        return h("div", { class: "bt-stack" }, bracketTree(state.matches, "Bracket", "gold"));
      }
      const groups = [
        ...new Set(state.matches.map((m) => m.group_label).filter(Boolean)),
      ];
      if (groups.length) {
        return h(
          "div",
          { class: "stack" },
          ...groups.map((g) =>
            h(
              "section",
              { class: "stack" },
              h("h3", {}, `Bracket ${g}`),
              dataTable({
                searchState: state,
                schema,
                rows: state.matches.filter((m) => m.group_label === g),
                state: "ready",
                ariaLabel: `Bracket ${g} matches`,
              }),
            )
          ),
        );
      }
      return h(
        "div",
        { class: "stack" },
        ...rounds.map((r) =>
          h(
            "section",
            { class: "stack" },
            h(
              "h3",
              {},
              stage()?.stage_type === "single_elimination"
                ? roundName(r, rounds.length)
                : `Round ${r}`,
            ),
            dataTable({
              searchState: state,
              schema,
              rows: state.matches.filter((m) => m.round_no === r),
              state: "ready",
              ariaLabel: `Round ${r} matches`,
            }),
          )
        ),
      );
    }

    const readyToFinalize = () =>
      state.division?.status === "in_progress" &&
      state.division.stages.every((x) =>
        ["completed", "cancelled"].includes(x.status)
      ) &&
      can("scores.finalize");

    function finalizeDivisionModal() {
      const error = errorLine();
      const d = state.division;
      const totalMatches = state.matches.filter((m) => m.status === "completed" || m.status === "forfeited").length;
      return openModal({
        title: "Finalize This Division",
        eyebrow: d?.name ?? "Division",
        icon: "medal",
        confirmLabel: "Finalize Division",
        destructive: true,
        body: h(
          "div",
          { class: "stack finalize-modal-stack" },
          h(
            "div",
            { class: "finalize-overview-card" },
            h(
              "div",
              { class: "finalize-overview-top" },
              h("span", { class: "finalize-overview-icon", "aria-hidden": "true" }, icon("trophy")),
              h(
                "div",
                { class: "finalize-overview-titles" },
                h("span", { class: "finalize-overview-event" }, state.event?.name ?? "Tournament"),
                h("h4", { class: "finalize-overview-division" }, d?.name ?? "Division"),
              ),
              h("span", { class: "finalize-status-pill" }, "All Matches Final"),
            ),
            h(
              "div",
              { class: "finalize-overview-chips" },
              h("span", { class: "finalize-chip" }, d?.format === "doubles" ? "Doubles" : "Singles"),
              d?.category?.name ? h("span", { class: "finalize-chip" }, d.category.name) : null,
              totalMatches ? h("span", { class: "finalize-chip is-accent" }, `${totalMatches} Matches Completed`) : null,
            ),
          ),
          h(
            "div",
            { class: "finalize-impact-grid" },
            h(
              "div",
              { class: "finalize-impact-card" },
              h("span", { class: "finalize-impact-icon", "aria-hidden": "true" }, icon("medal")),
              h(
                "div",
                { class: "finalize-impact-text" },
                h("strong", {}, "Record Placements"),
                h("p", { class: "sub" }, "Locks official division standings, podium finishes, and champions into club history."),
              ),
            ),
            h(
              "div",
              { class: "finalize-impact-card" },
              h("span", { class: "finalize-impact-icon", "aria-hidden": "true" }, icon("layers")),
              h(
                "div",
                { class: "finalize-impact-text" },
                h("strong", {}, "Update Club Ranks"),
                h("p", { class: "sub" }, "Applies the club's ranking ladder rules, moving eligible participants according to their final finish."),
              ),
            ),
          ),
          h(
            "div",
            { class: "modal-callout is-warning finalize-callout" },
            h("span", { class: "modal-callout-icon", "aria-hidden": "true" }, icon("info")),
            h(
              "div",
              { class: "modal-callout-text" },
              h("strong", {}, "Audit Trail Preservation"),
              h("p", { class: "sub" }, "Results can still be corrected afterwards if a scoring dispute arises, but every correction requires a documented reason and recalculates affected standings."),
            ),
          ),
          error,
        ),
        onConfirm: async () => {
          try {
            await api.rpc("finalize_division", {
              p_division_id: state.division.id,
            });
            toast("Division finalized.", { tone: "success" });
            state.stageId = null;
            await load();
          } catch (e) {
            return showError(
              error,
              messageOf(e, "Unable to complete this action. Please try again."),
            );
          }
        },
      });
    }

    /** The winner of the last round once the final is over. */
    function championLine() {
      const last = Math.max(0, ...state.matches.map((m) => m.round_no));
      const final = state.matches.find((m) => m.round_no === last);
      if (!final || !["completed", "forfeited"].includes(final.status)) {
        return null;
      }
      const name = final.winner_entry_id === final.entry_a_id
        ? final.a_name
        : final.b_name;
      return h(
        "p",
        { class: "card" },
        "Champion: ",
        h("strong", {}, name ?? "—"),
      );
    }

    // Undraw: takes the draw back so the division is open for registration and roster changes again. Only while the draw has
    // been made but no match has started (the database refuses it otherwise); a reason is required and kept with the history.
    const firstStage = () => state.division?.stages?.find((x) => x.stage_no === 1);
    const showUndraw = () => can("draws.redo") && state.division?.status === "drawn" && firstStage()?.status === "drawn";

    function undrawModal() {
      const first = firstStage();
      if (!showUndraw() || !first) return null;
      const key = api.newKey();
      const error = errorLine();
      const reason = h("textarea", {
        id: "rb-reason", name: "rb-reason", class: "input textarea", rows: 3, minlength: 3, maxlength: 500, required: true,
        placeholder: "Why is the draw being taken back?",
      });
      return openModal({
        title: "Undraw",
        eyebrow: state.division?.name,
        icon: "alert",
        tone: "warning",
        confirmLabel: "Undraw",
        body: h(
          "div",
          { class: "stack" },
          h("p", { class: "sub" }, "The draw is taken back and the division opens for registration and roster changes again. Its scheduled matches are cancelled, and the old draw is kept in the history. Make a new draw when the roster is final."),
          h("div", { class: "field" }, h("label", { for: "rb-reason" }, "Reason *"), reason),
          error,
        ),
        onConfirm: async () => {
          error.hidden = true;
          const text = reason.value.trim();
          if (text.length < 3) return showError(error, "Enter a reason of 3 to 500 characters.");
          try {
            await api.rpc("undraw_division", { p_division_id: state.division.id, p_reason: text, p_key: key });
            toast("Division draw withdrawn. The division is open for roster changes.", { tone: "success" });
            // Back to the event's divisions (the events page reopens the event that was being viewed).
            location.hash = "#/admin/events";
          } catch (e) {
            return showError(error, messageOf(e, "The draw could not be taken back. Try again."));
          }
        },
      });
    }

    // Scoring by Round (Split Single Elimination, events.manage): a rule for the H and the L bracket quarterfinals,
    // semifinals and finals. Set after Round 1 and before the quarterfinals start; the database locks it after that.
    const showRoundScoring = () => stage()?.stage_type === "split_single_elimination" && can("events.manage");

    function roundScoringModal() {
      const s = stage();
      if (!showRoundScoring() || !s) return null;
      const rules = state.scoringRules ?? [];
      const locked = state.matches.some((m) => ["H", "L"].includes(m.group_label) && !["scheduled", "void"].includes(m.status));
      const base = s.scoring_rule_snapshot?.name ?? "the division rule";
      const idByName = new Map(rules.map((r) => [r.name, r.id]));
      const selects = {};
      const field = (group, round, label) => {
        const id = `rs-${group}-${round}`;
        const savedRule = idByName.get(s.round_scoring?.[group]?.[round]?.name) ?? "";
        const select = selectControl(
          { class: "input select-input", id, name: id, disabled: locked },
          h("option", { value: "", selected: savedRule === "" }, `Division rule (${base})`),
          ...rules.map((r) => h("option", { value: r.id, selected: r.id === savedRule }, r.name)),
        );
        selects[`${group}.${round}`] = select;
        return h("div", { class: "field" }, h("label", { for: id }, label), select);
      };
      const bracket = (group, title) =>
        h(
          "div",
          { class: "form-section round-scoring-bracket" },
          h("div", { class: "round-scoring-bracket-head" },
            h("span", { class: "section-icon is-sm", "aria-hidden": "true" }, icon("layers")),
            h("h3", {}, title),
          ),
          h("p", { class: "sub" }, "Set the scoring rule for each round."),
          field(group, "quarterfinal", "Quarterfinals"),
          field(group, "semifinal", "Semifinals"),
          field(group, "final", "Finals"),
        );
      const error = errorLine();
      return openModal({
        title: "Scoring by Round",
        eyebrow: STAGE_LABEL[s.stage_type],
        icon: "settings",
        size: "lg",
        description: state.division?.name,
        confirmLabel: locked ? null : "Save Round Scoring",
        cancelLabel: locked ? "Close" : "Cancel",
        body: h(
          "div",
          { class: "stack round-scoring-form" },
          h(
            "div",
            { class: "round-scoring-summary" },
            h("div", { class: "round-scoring-summary-heading" },
              h("strong", {}, "Round 1 scoring"),
              badge(locked ? "Locked" : "Editable", locked ? "warning" : "info"),
            ),
            h("strong", { class: "round-scoring-base-rule" }, base),
            h("p", { class: "sub" }, locked
              ? "Bracket play has started. Scoring rules can no longer be changed."
              : "Choose scoring rules before the bracket quarterfinals begin."),
            h("p", { class: "sub" }, "Rounds set to Division rule use the Round 1 scoring rule."),
          ),
          h("div", { class: "round-scoring-grid" }, bracket("H", "H Bracket"), bracket("L", "L Bracket")),
          error,
        ),
        onConfirm: async () => {
          error.hidden = true;
          const rulesOut = { H: {}, L: {} };
          for (const [key, select] of Object.entries(selects)) {
            const [group, round] = key.split(".");
            if (select.value) rulesOut[group][round] = select.value;
          }
          try {
            await api.rpc("set_stage_round_scoring", { p_stage_id: s.id, p_rules: rulesOut, p_key: api.newKey() });
            toast("Round scoring settings updated.", { tone: "success" });
            await load();
          } catch (e) {
            return showError(
              error,
              ["22023", "42501"].includes(e?.code) ? e.cause?.message || e.message : "The round scoring could not be saved. Try again.",
            );
          }
        },
      });
    }

    function draw() {
      if (state.status === "error") {
        body.replaceChildren(
          dataTable({
            searchState: state,
            schema: {
              columns: [{ key: "n", label: "Bracket", render: () => "" }],
            },
            rows: [],
            state: "error",
            onRetry: load,
            ariaLabel: "Bracket",
          }),
        );
        return;
      }
      if (state.status === "loading" || !state.division) {
        body.replaceChildren(
          dataTable({
            searchState: state,
            schema: {
              columns: [{ key: "n", label: "Bracket", render: () => "" }],
            },
            rows: [],
            state: "loading",
            ariaLabel: "Bracket",
          }),
        );
        return;
      }
      const d = state.division;
      const s = stage();
      const stageTabs = d.stages.length > 1
        ? tabs({
          activeId: state.stageId,
          tabs: d.stages.map((x) => ({
            id: x.id,
            label: `${x.stage_no}. ${
              STAGE_LABEL[x.stage_type] ?? x.stage_type
            }`,
          })),
          onChange: (id) => {
            state.stageId = id;
            state.matches = [];
            state.standings = [];
            loadStage();
          },
        })
        : null;
      body.replaceChildren(
        h(
          "div",
          { class: "stack" },
          h(
            "div",
            { class: "bt-toolbar-card" },
            h(
              "div",
              { class: "bt-toolbar-top" },
              h(
                "div",
                { class: "actions bt-toolbar-actions" },
                button({
                  label: "Back",
                  icon: "chevl",
                  onClick: () => history.back(),
                }),
                showUndraw()
                  ? button({
                    label: "Undraw",
                    icon: "refresh",
                    variant: "secondary",
                    onClick: undrawModal,
                  })
                  : null,
                showRoundScoring()
                  ? iconButton({
                    label: "Scoring by Round",
                    icon: "settings",
                    variant: "secondary",
                    onClick: roundScoringModal,
                  })
                  : null,
                readyToFinalize()
                  ? button({
                    label: "Finalize Division",
                    icon: "medal",
                    variant: "primary",
                    onClick: finalizeDivisionModal,
                  })
                  : null,
              ),
              h(
                "div",
                { class: "bt-toolbar-pills" },
                d.category?.name ? badge(d.category.name, "info") : null,
                badge(d.format === "doubles" ? "Doubles" : "Singles", "neutral"),
                s ? badge(STAGE_LABEL[s.stage_type] ?? s.stage_type, "warning") : null,
                s ? badge(STAGE_STATUS[s.status] ?? s.status, s.status === "completed" ? "success" : "info") : null,
              ),
            ),
            h(
              "p",
              { class: "muted bt-toolbar-meta" },
              [
                d.event?.name,
                d.category?.name,
                d.format === "doubles" ? "Doubles" : "Singles",
                s ? STAGE_LABEL[s.stage_type] : null,
                s ? STAGE_STATUS[s.status] : null,
              ].filter(Boolean).join(" · "),
            ),
          ),
          stageTabs,
          s?.stage_type === "single_elimination" ? championLine() : null,
          s?.stage_type === "single_elimination" ||
            s?.stage_type === "split_single_elimination"
            ? null
            : h("h2", { class: "bt-section-heading" }, icon("trophy"), "Standings"),
          s?.stage_type === "single_elimination" ||
            s?.stage_type === "split_single_elimination"
            ? null
            : standingsView(),
          h(
            "h2",
            { class: "bt-section-heading" },
            icon("layers"),
            s?.stage_type === "single_elimination" ? "Bracket" : "Matches",
          ),
          matchesView(),
        ),
      );
    }

    page.append(
      memberHero({
        iconName: "trophy",
        eyebrow: "Bracket",
        title: "Standings and Matches",
        chip: "Match Results",
        titleBadge: true,
        description:
          "Results are worked out by the club's system from the finished matches.",
      }),
      body,
    );
    load();
    return page;
  }

  return { bracketPage };
}
