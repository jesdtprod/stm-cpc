// Ranks page (PLAN 4.3): each category's ladder of ranks, and the rules that move members along it.
//   Ladders tab  one card per category: set up the ladder, add, rename, reorder, delete ranks, choose the starting rank
//   Rules tab    the movement rules (data, not code): conditions, action, limits, priority
// Creates are idempotent (the new row's ID is made when the form opens). Edits check the row's version. Reordering
// and the starting rank go through functions that change the whole ladder in one step; deletes need a reason. The
// database decides what is allowed and this page shows its answer in plain words.
import {
  badge,
  button,
  dataTable,
  h,
  iconButton,
  openModal,
  pageHeader,
  tabs,
  toast,
} from "./ui.js";

const CODE_RE = /^[a-z0-9][a-z0-9_-]{0,31}$/;
const codeFrom = (name) =>
  name.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "").slice(0, 32).replace(/-+$/g, "");

const CATEGORY_SELECT = "id,code,name,sort_order,is_active,deleted_at," +
  "ladders:rank_ladders(id,overflow,is_active,deleted_at,version," +
  "ranks(id,code,name,sort_order,is_starting,deleted_at,version))";
const RULE_SELECT =
  "id,name,conditions,action,levels,min_rank_id,max_rank_id,cooldown_days,exclude_forfeits,priority,is_active,version";

const OVERFLOW = {
  chain: "Moving past the top or bottom continues into the next category",
  stop: "Movement stops at the top and bottom of this category",
};
const ACTION_LABEL = { up: "Move up", down: "Move down", retain: "Stay" };

const liveLadder = (cat) => (cat.ladders ?? []).find((l) => !l.deleted_at);
const liveRanks = (ladder) =>
  (ladder?.ranks ?? []).filter((r) => !r.deleted_at).sort((a, b) =>
    a.sort_order - b.sort_order
  );

/** The database's own messages are written for people; anything else gets a plain fallback. */
function messageOf(e, fallback) {
  const own = ["22023", "42501", "23503", "23505", "CP422", "CP409"].includes(
    e?.code,
  ) && e.cause?.message;
  if (e?.code === "23505" || e?.kind === "duplicate") {
    return "That code, name or position is already used in this ladder. Choose a different one.";
  }
  return own || e?.message || fallback;
}

export function createRanksPages({ api, getOrgId }) {
  function ranksPage() {
    const page = h("div", { class: "page" });
    const tabsHost = h("div", {});
    const body = h("div", { class: "ranks-body" });
    const state = {
      tab: "ladders",
      cats: [],
      rules: [],
      status: "loading",
    };

    // ----------------------------------------------------------------- data
    async function refresh() {
      state.status = state.cats.length ? "refreshing" : "loading";
      draw();
      try {
        const [cats, rules] = await Promise.all([
          api.read((c) =>
            c.from("categories").select(CATEGORY_SELECT).is("deleted_at", null)
              .order("sort_order")
          ),
          api.read((c) =>
            c.from("rank_rules").select(RULE_SELECT).is("deleted_at", null)
              .order("priority").order("name")
          ),
        ]);
        state.cats = cats ?? [];
        state.rules = rules ?? [];
        state.status = "ready";
      } catch {
        state.status = "error";
      }
      draw();
    }

    const allRanks = () =>
      state.cats.flatMap((cat) =>
        liveRanks(liveLadder(cat)).map((r) => ({
          ...r,
          label: `${cat.name}: ${r.name}`,
        }))
      );

    // ---------------------------------------------------------------- modals
    function errorLine() {
      return h("p", {
        class: "field-error form-error",
        role: "alert",
        hidden: true,
      });
    }
    const showError = (el, message) => {
      el.textContent = message;
      el.hidden = false;
      return false;
    };
    const field = (id, label, input, hint) =>
      h(
        "div",
        { class: "field" },
        label ? h("label", { for: id }, label) : null,
        input,
        hint
          ? h("span", { class: "field-hint", id: `${id}-hint` }, hint)
          : null,
      );
    const select = (id, name, options, value) =>
      h(
        "select",
        { class: "input select-input", id, name },
        ...options.map((o) =>
          h(
            "option",
            {
              value: o.value,
              selected: String(o.value) === String(value ?? ""),
            },
            o.label,
          )
        ),
      );

    function rankModal(cat, ladder, row) {
      const editing = Boolean(row);
      const key = row?.id ?? api.newKey();
      const ranks = liveRanks(ladder);
      const error = errorLine();
      const nameInput = h("input", {
        class: "input",
        id: "rk-name",
        name: "name",
        required: true,
        maxlength: 60,
        value: row?.name ?? "",
      });
      const codeInput = h("input", {
        class: "input",
        id: "rk-code",
        name: "code",
        required: true,
        maxlength: 32,
        value: row?.code ?? "",
        readonly: editing,
      });
      let touched = editing;
      codeInput.addEventListener("input", () => (touched = true));
      if (!editing) {
        nameInput.addEventListener("input", () => {
          if (!touched) codeInput.value = codeFrom(nameInput.value);
        });
      }
      return openModal({
        title: editing ? "Edit rank" : "New rank",
        eyebrow: cat.name,
        icon: "layers",
        confirmLabel: editing ? "Save changes" : "Add rank",
        body: h(
          "div",
          { class: "stack" },
          field("rk-name", "Name *", nameInput),
          field(
            "rk-code",
            "Code *",
            codeInput,
            editing
              ? "The code cannot be changed after the rank is created."
              : "Lowercase letters, numbers, hyphen. Made from the name.",
          ),
          editing ? null : h(
            "p",
            { class: "muted" },
            "The new rank is added at the top of the ladder. Use the arrows to move it.",
          ),
          error,
        ),
        onConfirm: async (form) => {
          const name = String(form.get("name") ?? "").trim();
          const code = String(form.get("code") ?? "").trim();
          if (!name) return showError(error, "Enter a name.");
          if (!CODE_RE.test(code)) {
            return showError(
              error,
              "The code uses lowercase letters, numbers, hyphen or underscore (up to 32).",
            );
          }
          try {
            if (editing) {
              const done = await api.read((c) =>
                c.from("ranks").update({ name }).eq("id", row.id).eq(
                  "version",
                  row.version,
                ).select("id")
              );
              if (!done?.length) {
                return showError(
                  error,
                  "Someone else changed this rank. Close this window and open it again.",
                );
              }
            } else {
              await api.create("ranks", key, {
                org_id: getOrgId(),
                ladder_id: ladder.id,
                code,
                name,
                sort_order: ranks.length
                  ? ranks[ranks.length - 1].sort_order + 1
                  : 0,
                is_starting: ranks.length === 0, // the first rank starts as the starting rank
              });
            }
            toast(editing ? "Rank saved." : "Rank added.", { tone: "success" });
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

    function deleteModal(row, { table, title, note }) {
      const key = api.newKey();
      const error = errorLine();
      return openModal({
        title,
        eyebrow: row.name,
        icon: "alert",
        destructive: true,
        confirmLabel: "Delete",
        body: h(
          "div",
          { class: "stack" },
          h("p", {}, note),
          field(
            "rk-reason",
            "Reason *",
            h("textarea", {
              class: "input textarea",
              id: "rk-reason",
              name: "reason",
              rows: 3,
              maxlength: 500,
              required: true,
            }),
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
              p_table: table,
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

    async function run(task, okMessage) {
      try {
        await task();
        if (okMessage) toast(okMessage, { tone: "success" });
        await refresh();
      } catch (e) {
        toast(messageOf(e, "That did not work."), { tone: "error" });
      }
    }

    const setUpLadder = (cat) =>
      run(
        () =>
          api.create("rank_ladders", api.newKey(), {
            org_id: getOrgId(),
            category_id: cat.id,
            overflow: "chain",
          }),
        "Ladder set up.",
      );

    const changeOverflow = (ladder, overflow) =>
      run(async () => {
        const done = await api.read((c) =>
          c.from("rank_ladders").update({ overflow }).eq("id", ladder.id).eq(
            "version",
            ladder.version,
          ).select("id")
        );
        if (!done?.length) {
          throw new Error("Someone else changed this ladder. Reload the page.");
        }
      }, "Saved.");

    function move(ladder, ranks, index, delta) {
      const ids = ranks.map((r) => r.id);
      const to = index + delta;
      if (to < 0 || to >= ids.length) return;
      [ids[index], ids[to]] = [ids[to], ids[index]];
      return run(
        () =>
          api.rpc("reorder_ranks", {
            p_ladder_id: ladder.id,
            p_rank_ids: ids,
            p_key: api.newKey(),
          }),
        "Order saved.",
      );
    }

    // ----------------------------------------------------------- ladders tab
    function ladderCard(cat) {
      const ladder = liveLadder(cat);
      const ranks = liveRanks(ladder);
      const head = h(
        "div",
        { class: "ladder-head" },
        h(
          "div",
          {},
          h("h2", { class: "settings-title" }, cat.name),
          h(
            "span",
            { class: "muted" },
            cat.is_active
              ? `Category order ${cat.sort_order}`
              : "Retired category",
          ),
        ),
      );
      if (!ladder) {
        return h(
          "div",
          { class: "card ladder-card" },
          head,
          h("p", { class: "muted" }, "This category has no rank ladder yet."),
          h(
            "div",
            { class: "actions" },
            button({
              label: "Set up ladder",
              icon: "plus",
              variant: "primary",
              onClick: () => setUpLadder(cat),
            }),
          ),
        );
      }
      const hasStart = ranks.some((r) => r.is_starting);
      const overflowSelect = select(
        `ov-${cat.id}`,
        "overflow",
        Object.entries(OVERFLOW).map(([value, label]) => ({ value, label })),
        ladder.overflow,
      );
      overflowSelect.addEventListener(
        "change",
        () => changeOverflow(ladder, overflowSelect.value),
      );
      const list = ranks.length
        ? h(
          "ol",
          {
            class: "rank-list",
            "aria-label": `${cat.name} ranks, highest first`,
          },
          ...ranks.map((r, i) => [r, i]).reverse().map(([r, i]) =>
            h(
              "li",
              { class: "rank-item" },
              h("span", { class: "rank-pos" }, String(i + 1)),
              h(
                "span",
                { class: "rank-name" },
                r.name,
                h("span", { class: "sub" }, r.code),
              ),
              r.is_starting ? badge("Starting rank", "success") : null,
              h(
                "span",
                { class: "row-actions" },
                iconButton({
                  label: `Move ${r.name} up`,
                  icon: "chevronUp",
                  disabled: i === ranks.length - 1,
                  onClick: () => move(ladder, ranks, i, 1),
                }),
                iconButton({
                  label: `Move ${r.name} down`,
                  icon: "chevronDown",
                  disabled: i === 0,
                  onClick: () => move(ladder, ranks, i, -1),
                }),
                iconButton({
                  label: `Edit ${r.name}`,
                  icon: "edit",
                  onClick: () => rankModal(cat, ladder, r),
                }),
                iconButton({
                  label: r.is_starting
                    ? `${r.name} is the starting rank`
                    : `Make ${r.name} the starting rank`,
                  icon: "check",
                  disabled: r.is_starting,
                  onClick: () =>
                    run(
                      () =>
                        api.rpc("set_starting_rank", {
                          p_rank_id: r.id,
                          p_key: api.newKey(),
                        }),
                      "Starting rank changed.",
                    ),
                }),
                iconButton({
                  label: `Delete ${r.name}`,
                  icon: "trash",
                  variant: "danger",
                  onClick: () =>
                    deleteModal(r, {
                      table: "ranks",
                      title: "Delete this rank",
                      note:
                        "Members who hold this rank must be moved first; the database refuses otherwise.",
                    }),
                }),
              ),
            )
          ),
        )
        : h("p", { class: "muted" }, "No ranks yet. Add the first one.");
      return h(
        "div",
        { class: "card ladder-card" },
        head,
        field(
          `ov-${cat.id}`,
          "At the top and bottom of the ladder",
          overflowSelect,
        ),
        h("div", { class: "ladder-order muted" }, "Highest rank first"),
        list,
        ranks.length && !hasStart
          ? h(
            "p",
            { class: "field-error" },
            "No starting rank is chosen. New members have nowhere to start.",
          )
          : null,
        h(
          "div",
          { class: "actions" },
          button({
            label: "Add rank",
            icon: "plus",
            onClick: () => rankModal(cat, ladder, null),
          }),
          ranks.length === 0
            ? iconButton({
              label: `Delete the ${cat.name} ladder`,
              icon: "trash",
              variant: "danger",
              onClick: () =>
                deleteModal({ id: ladder.id, name: `${cat.name} ladder` }, {
                  table: "rank_ladders",
                  title: "Delete this ladder",
                  note:
                    "The category stays. You can set up a ladder again later.",
                }),
            })
            : null,
        ),
      );
    }

    // ------------------------------------------------------------- rules tab
    function conditionText(c) {
      const parts = [];
      if (c.bracket_tier) parts.push(`${c.bracket_tier} bracket`);
      if (c.bracket_result) parts.push(c.bracket_result);
      if (c.placement) parts.push(`placed ${c.placement}`);
      if (c.min_matches) parts.push(`at least ${c.min_matches} matches`);
      return parts.length ? parts.join(", ") : "Any result";
    }
    const actionText = (r) =>
      r.action === "retain"
        ? "Stay"
        : `${ACTION_LABEL[r.action]} ${r.levels} level${
          r.levels === 1 ? "" : "s"
        }`;

    function ruleModal(row) {
      const editing = Boolean(row);
      const key = row?.id ?? api.newKey();
      const c = row?.conditions ?? {};
      const error = errorLine();
      const rankOptions = [{ value: "", label: "No limit" }].concat(
        allRanks().map((r) => ({ value: r.id, label: r.label })),
      );
      const levels = h("input", {
        class: "input",
        id: "ru-levels",
        name: "levels",
        type: "number",
        min: 0,
        max: 10,
        step: 1,
        value: row?.levels ?? 1,
      });
      const actionSel = select("ru-action", "action", [
        { value: "up", label: "Move up" },
        { value: "down", label: "Move down" },
        { value: "retain", label: "Stay (no change)" },
      ], row?.action ?? "up");
      const sync = () => {
        const stay = actionSel.value === "retain";
        levels.disabled = stay;
        if (stay) levels.value = "0";
        else if (Number(levels.value) < 1) levels.value = "1";
      };
      actionSel.addEventListener("change", sync);
      queueMicrotask(sync);
      const forfeits = h("input", {
        type: "checkbox",
        id: "ru-forfeits",
        name: "exclude_forfeits",
        checked: row?.exclude_forfeits ?? true,
      });
      const activeBox = h("input", {
        type: "checkbox",
        id: "ru-active",
        name: "is_active",
        checked: row?.is_active ?? true,
      });
      return openModal({
        title: editing ? "Edit rule" : "New rule",
        eyebrow: editing ? row.name : "Rank movement",
        icon: "layers",
        size: "lg",
        confirmLabel: editing ? "Save changes" : "Add rule",
        body: h(
          "div",
          { class: "stack" },
          field(
            "ru-name",
            "Name *",
            h("input", {
              class: "input",
              id: "ru-name",
              name: "name",
              required: true,
              maxlength: 80,
              value: row?.name ?? "",
            }),
          ),
          h(
            "h3",
            { class: "settings-title" },
            "When a member's final result is",
          ),
          field(
            "ru-tier",
            "Bracket",
            select("ru-tier", "bracket_tier", [
              { value: "", label: "Any" },
              { value: "H", label: "H bracket" },
              { value: "L", label: "L bracket" },
            ], c.bracket_tier),
          ),
          field(
            "ru-result",
            "Result in that bracket",
            select("ru-result", "bracket_result", [
              { value: "", label: "Any" },
              { value: "won", label: "Won the bracket" },
              { value: "lost", label: "Lost (eliminated)" },
            ], c.bracket_result),
          ),
          field(
            "ru-place",
            "Final placement",
            h("input", {
              class: "input",
              id: "ru-place",
              name: "placement",
              type: "number",
              min: 1,
              max: 9999,
              step: 1,
              value: c.placement ?? "",
            }),
            "Leave empty for any placement. 1 is the champion.",
          ),
          field(
            "ru-matches",
            "At least this many matches played",
            h("input", {
              class: "input",
              id: "ru-matches",
              name: "min_matches",
              type: "number",
              min: 0,
              max: 999,
              step: 1,
              value: c.min_matches ?? "",
            }),
          ),
          h("h3", { class: "settings-title" }, "Then"),
          field("ru-action", "Rank change", actionSel),
          field(
            "ru-levels",
            "By how many levels",
            levels,
            "1 to 10. Stay uses 0.",
          ),
          field(
            "ru-min",
            "Never below",
            select("ru-min", "min_rank_id", rankOptions, row?.min_rank_id),
          ),
          field(
            "ru-max",
            "Never above",
            select("ru-max", "max_rank_id", rankOptions, row?.max_rank_id),
          ),
          field(
            "ru-cool",
            "Wait before this rule can apply again (days)",
            h("input", {
              class: "input",
              id: "ru-cool",
              name: "cooldown_days",
              type: "number",
              min: 0,
              max: 3650,
              step: 1,
              value: row?.cooldown_days ?? 0,
            }),
          ),
          field(
            "ru-prio",
            "Priority",
            h("input", {
              class: "input",
              id: "ru-prio",
              name: "priority",
              type: "number",
              min: 0,
              max: 100000,
              step: 1,
              value: row?.priority ?? 100,
            }),
            "Lower numbers are checked first.",
          ),
          h(
            "div",
            { class: "check" },
            forfeits,
            h(
              "label",
              { for: "ru-forfeits" },
              "Ignore withdrawals and forfeits",
            ),
          ),
          h(
            "div",
            { class: "check" },
            activeBox,
            h("label", { for: "ru-active" }, "Rule is active"),
          ),
          error,
        ),
        onConfirm: async (form) => {
          const name = String(form.get("name") ?? "").trim();
          if (!name) return showError(error, "Enter a name.");
          const num = (k) => {
            const v = String(form.get(k) ?? "").trim();
            return v === "" ? null : Number(v);
          };
          const conditions = {};
          const tier = form.get("bracket_tier");
          const result = form.get("bracket_result");
          if (tier) conditions.bracket_tier = tier;
          if (result) conditions.bracket_result = result;
          if (num("placement") != null) conditions.placement = num("placement");
          if (num("min_matches")) conditions.min_matches = num("min_matches");
          const action = String(form.get("action"));
          const lv = action === "retain" ? 0 : num("levels");
          if (
            action !== "retain" &&
            !(Number.isInteger(lv) && lv >= 1 && lv <= 10)
          ) {
            return showError(error, "Levels is a whole number from 1 to 10.");
          }
          for (
            const k of ["placement", "min_matches", "cooldown_days", "priority"]
          ) {
            const v = num(k);
            if (v != null && (!Number.isInteger(v) || v < 0)) {
              return showError(
                error,
                "Numbers must be whole numbers, 0 or more.",
              );
            }
          }
          const fields = {
            name,
            conditions,
            action,
            levels: lv,
            min_rank_id: form.get("min_rank_id") || null,
            max_rank_id: form.get("max_rank_id") || null,
            cooldown_days: num("cooldown_days") ?? 0,
            priority: num("priority") ?? 100,
            exclude_forfeits: form.get("exclude_forfeits") === "on",
            is_active: form.get("is_active") === "on",
          };
          try {
            if (editing) {
              const done = await api.read((cl) =>
                cl.from("rank_rules").update(fields).eq("id", row.id).eq(
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
              await api.create("rank_rules", key, {
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

    const rankName = (id) => allRanks().find((r) => r.id === id)?.label ?? "—";

    function rulesView() {
      const schema = {
        columns: [
          {
            key: "prio",
            label: "Priority",
            align: "right",
            render: (r) => String(r.priority),
          },
          { key: "name", label: "Rule", render: (r) => r.name },
          {
            key: "when",
            label: "When",
            render: (r) => conditionText(r.conditions),
          },
          { key: "then", label: "Then", render: (r) => actionText(r) },
          {
            key: "limits",
            label: "Limits",
            render: (r) => {
              const parts = [];
              if (r.min_rank_id) {
                parts.push(`not below ${rankName(r.min_rank_id)}`);
              }
              if (r.max_rank_id) {
                parts.push(`not above ${rankName(r.max_rank_id)}`);
              }
              if (r.cooldown_days) parts.push(`${r.cooldown_days}-day wait`);
              return parts.join(", ") || "—";
            },
          },
          {
            key: "status",
            label: "Status",
            render: (r) =>
              r.is_active
                ? badge("Active", "success")
                : badge("Off", "neutral"),
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
                  onClick: () => ruleModal(r),
                }),
                iconButton({
                  label: r.is_active
                    ? `Turn off ${r.name}`
                    : `Turn on ${r.name}`,
                  icon: r.is_active ? "eye" : "check",
                  onClick: () =>
                    run(async () => {
                      const done = await api.read((c) =>
                        c.from("rank_rules").update({ is_active: !r.is_active })
                          .eq("id", r.id).eq("version", r.version).select("id")
                      );
                      if (!done?.length) {
                        throw new Error(
                          "Someone else changed this rule. Reload the page.",
                        );
                      }
                    }, r.is_active ? "Rule turned off." : "Rule turned on."),
                }),
                iconButton({
                  label: `Delete ${r.name}`,
                  icon: "trash",
                  variant: "danger",
                  onClick: () =>
                    deleteModal(r, {
                      table: "rank_rules",
                      title: "Delete this rule",
                      note:
                        "Past rank changes keep the name of the rule that made them.",
                    }),
                }),
              ),
          },
        ],
      };
      return h(
        "div",
        { class: "stack" },
        h(
          "p",
          { class: "muted" },
          "Rules are checked in priority order after a division is finalized, once per member. Ranks never change from a single match.",
        ),
        dataTable({
          schema,
          rows: state.rules,
          state: state.status,
          ariaLabel: "Rank rules",
          onRetry: refresh,
          emptyTitle: "No rules yet",
          emptyText: "Add a rule to say how results move members up or down.",
        }),
      );
    }

    // ---------------------------------------------------------------- layout
    function draw() {
      tabsHost.replaceChildren(tabs({
        activeId: state.tab,
        tabs: [
          { id: "ladders", label: "Ladders and ranks" },
          { id: "rules", label: "Movement rules" },
        ],
        onChange: (id) => {
          state.tab = id;
          draw();
        },
      }));
      if (state.status === "error") {
        body.replaceChildren(
          h(
            "div",
            { class: "card home-error", role: "alert" },
            h("p", {}, "The ranks could not be loaded."),
            button({ label: "Try again", icon: "refresh", onClick: refresh }),
          ),
        );
        return;
      }
      if (state.status === "loading") {
        body.replaceChildren(
          h(
            "div",
            { class: "card settings-card is-loading", "aria-busy": "true" },
            h("span", { class: "sk-line" }),
            h("span", { class: "sk-line sk-wide" }),
          ),
        );
        return;
      }
      body.replaceChildren(
        state.tab === "ladders"
          ? (state.cats.length
            ? h("div", { class: "stack" }, ...state.cats.map(ladderCard))
            : h(
              "div",
              { class: "card" },
              h("p", {}, "Add categories first, then set up their ladders."),
            ))
          : rulesView(),
      );
    }

    page.append(
      pageHeader({
        icon: "layers",
        eyebrow: "Admin",
        title: "Ranks",
        description:
          "Each category has a ladder of ranks. Rules decide how results move members along it.",
        actions: [
          button({
            label: "New rule",
            variant: "primary",
            icon: "plus",
            onClick: () => {
              state.tab = "rules";
              draw();
              ruleModal(null);
            },
          }),
        ],
      }),
      tabsHost,
      body,
    );
    refresh();
    return page;
  }

  return { ranksPage };
}
