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
  iconButton,
  openModal,
  pageHeader,
  selectControl,
  tabs,
  toast,
} from "./ui.js";
import { can } from "./lib/permissions.js";

const STAGE_LABEL = {
  round_robin: "Round robin",
  single_elimination: "Single elimination",
  pool_play: "Pool play",
  best_of_n_playoff: "Best-of playoff",
  split_single_elimination: "Split single elimination",
};
const MATCH_STATUS = {
  scheduled: ["Scheduled", "neutral"],
  in_progress: ["In progress", "info"],
  completed: ["Final", "success"],
  forfeited: ["Forfeit", "warning"],
  cancelled: ["Cancelled", "neutral"],
};
const STAGE_STATUS = {
  pending: "Not started",
  drawn: "Drawn",
  in_progress: "In progress",
  completed: "Completed",
  cancelled: "Cancelled",
};

/** Knockout rounds are named from the end: the Final, the Semifinals, the Quarterfinals, then Round of 16 ... */
function roundName(round, total) {
  const fromEnd = total - round;
  if (fromEnd === 0) return "Final";
  if (fromEnd === 1) return "Semifinals";
  if (fromEnd === 2) return "Quarterfinals";
  return `Round of ${2 ** (fromEnd + 1)}`;
}

function messageOf(e, fallback) {
  const own = ["22023", "42501", "23505", "CP422"].includes(e?.code) &&
    e.cause?.message;
  return own || e?.message || fallback;
}

export function createBracketPages({ api }) {
  function bracketPage() {
    const divisionId = new URLSearchParams(location.hash.split("?")[1] ?? "")
      .get("division");
    const page = h("div", { class: "page" });
    const body = h("div", { class: "bracket-body" });
    const state = {
      status: "loading",
      division: null,
      stageId: null,
      standings: [],
      matches: [],
      results: [],
      detail: "loading",
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
            "id,name,status,format,category:categories(name),event:events(name),stages:division_stages(id,stage_no,stage_type,status,scoring_rule_snapshot)",
          ).eq("id", divisionId)
        );
        const division = rows?.[0];
        if (!division) throw new Error("not found");
        division.stages.sort((a, b) => a.stage_no - b.stage_no);
        state.division = division;
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
        const [standings, matches] = await Promise.all([
          api.rpc("stage_standings", { p_stage_id: state.stageId }),
          api.rpc("stage_matches", { p_stage_id: state.stageId }),
        ]);
        state.standings = standings ?? [];
        state.matches = matches ?? [];
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
        value: value ?? "",
        "aria-label": id,
      });

    function gameRows(m, maxGames) {
      return Array.from({ length: maxGames }, (_, i) => {
        const g = m.games?.[i];
        return h(
          "div",
          { class: "score-row" },
          h("span", { class: "score-label" }, `Game ${i + 1}`),
          num(`g${i}-a`, `a${i}`, g?.a),
          h("span", { "aria-hidden": "true" }, "–"),
          num(`g${i}-b`, `b${i}`, g?.b),
        );
      });
    }
    /** Reads the filled-in rows; a half-filled row is an error, empty rows at the end are ignored. */
    function readGames(form, maxGames) {
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
        games.push({ a: Number(a), b: Number(b) });
      }
      return { games };
    }
    const maxGamesOf = () =>
      2 * (stage()?.scoring_rule_snapshot?.games_to_win ?? 1) - 1;
    const rule = () => stage()?.scoring_rule_snapshot ?? {};
    const ruleText = () =>
      `Play to ${rule().points_per_game}, win by ${rule().win_by}${
        rule().point_cap ? `, cap ${rule().point_cap}` : ""
      }. First to ${rule().games_to_win} game${
        rule().games_to_win > 1 ? "s" : ""
      } wins.`;

    function scoreModal(m) {
      const error = errorLine();
      const max = maxGamesOf();
      const canFinal = can("scores.finalize");
      return openModal({
        title: "Enter the score",
        eyebrow: `${m.a_name} v ${m.b_name}`,
        icon: "edit",
        confirmLabel: "Save score",
        body: h(
          "div",
          { class: "stack" },
          h("p", { class: "muted" }, ruleText()),
          h(
            "div",
            { class: "score-head" },
            h("span", {}, ""),
            h("strong", {}, m.a_name),
            h("span", {}, ""),
            h("strong", {}, m.b_name),
          ),
          ...gameRows(m, max),
          canFinal
            ? h(
              "div",
              { class: "check" },
              h("input", {
                type: "checkbox",
                id: "sc-final",
                name: "finalize",
                checked: true,
              }),
              h("label", { for: "sc-final" }, "Finalize the result now"),
            )
            : null,
          error,
        ),
        onConfirm: async (form) => {
          const r = readGames(form, max);
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
              toast("Result is final.", { tone: "success" });
            } else toast("Score saved.", { tone: "success" });
            await loadStage();
          } catch (e) {
            return showError(
              error,
              messageOf(e, "That did not work. Try again."),
            );
          }
        },
      });
    }

    async function finalize(m) {
      try {
        await api.rpc("finalize_match", { p_match_id: m.match_id });
        toast("Result is final.", { tone: "success" });
        await loadStage();
      } catch (e) {
        toast(messageOf(e, "That did not work. Try again."), {
          tone: "danger",
        });
      }
    }

    function forfeitModal(m) {
      const error = errorLine();
      return openModal({
        title: "Record a forfeit",
        eyebrow: `${m.a_name} v ${m.b_name}`,
        icon: "alert",
        confirmLabel: "Record forfeit",
        destructive: true,
        body: h(
          "div",
          { class: "stack" },
          h(
            "p",
            { class: "muted" },
            `The other side wins with the forfeit score (${rule().forfeit_score}–0 in each game).`,
          ),
          h(
            "div",
            { class: "field" },
            h("label", { for: "ff-side" }, "Who forfeits? *"),
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
              p_reason: reason,
            });
            toast("Forfeit recorded.", { tone: "success" });
            await loadStage();
          } catch (e) {
            return showError(
              error,
              messageOf(e, "That did not work. Try again."),
            );
          }
        },
      });
    }

    function correctModal(m) {
      const error = errorLine();
      const max = maxGamesOf();
      return openModal({
        title: "Correct the result",
        eyebrow: `${m.a_name} v ${m.b_name}`,
        icon: "refresh",
        confirmLabel: "Correct result",
        destructive: true,
        body: h(
          "div",
          { class: "stack" },
          h(
            "p",
            { class: "muted" },
            `${ruleText()} The old result is voided and kept in the history.`,
          ),
          ...gameRows(m, max),
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
          const r = readGames(form, max);
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
            toast("Result corrected.", { tone: "success" });
            await loadStage();
          } catch (e) {
            return showError(
              error,
              messageOf(e, "That did not work. Try again."),
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
              label: "Player or team",
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
      if (stage()?.stage_type === "split_single_elimination") {
        const part = (label) =>
          state.matches.filter((m) => m.group_label === label);
        const section = (title, rows, named) => {
          if (!rows.length) return null;
          const rs = [...new Set(rows.map((m) => m.round_no))].sort((a, b) =>
            a - b
          );
          return h(
            "section",
            { class: "stack" },
            h("h3", {}, title),
            ...rs.map((r) =>
              h(
                "section",
                { class: "stack" },
                named ? h("h4", {}, roundName(r - rs[0] + 1, rs.length)) : null,
                dataTable({
                  searchState: state,
                  schema,
                  rows: rows.filter((m) => m.round_no === r),
                  state: "ready",
                  ariaLabel: `${title} round ${r}`,
                }),
              )
            ),
          );
        };
        return h(
          "div",
          { class: "stack" },
          section(
            "Round 1",
            state.matches.filter((m) => !m.group_label),
            false,
          ),
          section("H bracket", part("H"), true),
          section("L bracket", part("L"), true),
        );
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
      return openModal({
        title: "Finalize this division",
        eyebrow: state.division.name,
        icon: "medal",
        confirmLabel: "Finalize division",
        destructive: true,
        body: h(
          "div",
          { class: "stack" },
          h(
            "p",
            {},
            "The final placements are recorded and the club's rank rules move each player once. Results can still be corrected afterwards, with a reason.",
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
              messageOf(e, "That did not work. Try again."),
            );
          }
        },
      });
    }

    function resultsView() {
      if (!state.results.length) return null;
      const staff = state.results.some((r) => r.rank_from);
      const columns = [
        {
          key: "place",
          label: "Place",
          align: "right",
          render: (r) => String(r.placement),
        },
        {
          key: "name",
          label: "Player or team",
          render: (r) => r.entry_name ?? "—",
        },
        {
          key: "bracket",
          label: "Bracket",
          render: (r) =>
            r.bracket_tier
              ? `${r.bracket_tier} bracket${
                r.bracket_result === "won" ? " champion" : ""
              }`
              : "—",
        },
      ];
      if (staff) {
        columns.push({
          key: "rank",
          label: "Rank",
          render: (r) =>
            h(
              "span",
              {},
              r.rank_from === r.rank_to
                ? `${r.rank_to} (no change)`
                : `${r.rank_from} → ${r.rank_to}`,
              r.rule_name ? h("span", { class: "sub" }, r.rule_name) : null,
            ),
        });
      }
      return h(
        "div",
        { class: "stack" },
        h("h2", {}, "Final placements"),
        dataTable({
          searchState: state,
          schema: { columns },
          rows: state.results,
          state: "ready",
          ariaLabel: "Final placements",
        }),
      );
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
            { class: "actions" },
            button({
              label: "Back",
              icon: "chevl",
              onClick: () => history.back(),
            }),
          ),
          h(
            "p",
            { class: "muted" },
            [
              d.event?.name,
              d.category?.name,
              d.format === "doubles" ? "Doubles" : "Singles",
              s ? STAGE_LABEL[s.stage_type] : null,
              s ? STAGE_STATUS[s.status] : null,
            ].filter(Boolean).join(" · "),
          ),
          readyToFinalize()
            ? h(
              "div",
              { class: "actions" },
              button({
                label: "Finalize division",
                icon: "medal",
                variant: "primary",
                onClick: finalizeDivisionModal,
              }),
            )
            : null,
          resultsView(),
          stageTabs,
          s?.stage_type === "single_elimination" ? championLine() : null,
          s?.stage_type === "single_elimination" ||
            s?.stage_type === "split_single_elimination"
            ? null
            : h("h2", {}, "Standings"),
          s?.stage_type === "single_elimination" ||
            s?.stage_type === "split_single_elimination"
            ? null
            : standingsView(),
          h(
            "h2",
            {},
            s?.stage_type === "single_elimination" ? "Bracket" : "Matches",
          ),
          matchesView(),
        ),
      );
    }

    page.append(
      pageHeader({
        icon: "trophy",
        eyebrow: "Bracket",
        title: "Standings and matches",
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
