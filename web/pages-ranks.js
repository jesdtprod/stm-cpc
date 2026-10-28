// Ranks page (PLAN 4.3): each category's ladder of ranks, and the rules that move members along it.
//   Ladders tab  one card per category: set up the ladder, add, rename, reorder, delete ranks, choose the starting rank
//   Rules tab    the movement rules (data, not code): conditions, action, limits, priority
// Creates are idempotent (the new row's ID is made when the form opens). Edits check the row's version. Reordering
// and the starting rank go through functions that change the whole ladder in one step; deletes need a reason. The
// database decides what is allowed and this page shows its answer in plain words.
import {
  adminHero,
  attachPagePattern,
  badge,
  button,
  dataTable,
  DEFAULT_PAGE_SIZE,
  h,
  icon,
  iconButton,
  inputWithIcon,
  openModal,
  pagination,
  searchControl,
  selectControl,
  selectField,
  switchToggle,
  tableFilter,
  toast,
  toProperCase,
  formatTemplateLabel as templateLabel,
} from "./ui.js";

const CODE_RE = /^[a-z0-9][a-z0-9_-]{0,31}$/;
const codeFrom = (name) =>
  name.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "").slice(0, 32).replace(/-+$/g, "");

const CATEGORY_SELECT = "id,code,name,sort_order,is_active,deleted_at," +
  "ladders:rank_ladders(id,overflow,is_active,deleted_at,version," +
  "ranks(id,code,name,rating_min,rating_max,sort_order,is_starting,deleted_at,version))";
const LEGACY_CATEGORY_SELECT = "id,code,name,sort_order,is_active,deleted_at," +
  "ladders:rank_ladders(id,overflow,is_active,deleted_at,version," +
  "ranks(id,code,name,sort_order,is_starting,deleted_at,version))";
const RULE_SELECT =
  "id,name,format_template_id,template:format_templates(name),conditions,action,levels,min_rank_id,max_rank_id,cooldown_days,exclude_forfeits,priority,is_active,version";

const OVERFLOW = {
  chain: "Continue into the next category",
  stop: "Stay within this category",
};
const ACTION_LABEL = { up: "Move Up", down: "Move Down", retain: "Stay" };
const liveLadder = (cat) => (cat.ladders ?? []).find((l) => !l.deleted_at);
const liveRanks = (ladder) =>
  (ladder?.ranks ?? []).filter((r) => !r.deleted_at).sort((a, b) =>
    a.sort_order - b.sort_order
  );
const ratingBand = (rank) => {
  const min = Number(rank?.rating_min);
  const max = Number(rank?.rating_max);
  return Number.isFinite(min) && Number.isFinite(max)
    ? `${min.toFixed(3)}–${max.toFixed(3)}`
    : null;
};
const isRatingBandSchemaUnavailable = (error) => {
  const cause = error?.cause ?? error;
  return ["42703", "PGRST204", "PGRST205"].includes(cause?.code ?? error?.code) &&
    /\brating_(?:min|max)\b/i.test(cause?.message ?? "");
};

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
    const page = h("div", {
      class: "page admin-dashboard admin-members-page admin-ranks-page",
    });
    attachPagePattern(page);
    const body = h("div", { class: "ranks-body" });
    const state = {
      tab: "ladders",
      cats: [],
      rules: [],
      templates: [],
      status: "loading",
      term: "",
      category: "all",
      page: 1,
      ratingBandsAvailable: true,
    };
    const search = searchControl({
      class: "input",
      id: "ranks-search",
      placeholder: "Search categories or ranks...",
      "aria-label": "Search Ranks",
      onInput: () => {
        state.term = search.value;
        state.page = 1;
        draw();
      },
    });
    const viewFilter = tableFilter({
      id: "ranks-view",
      label: "View Rank Management",
      activeId: state.tab,
      tabs: [{ id: "ladders", label: "Ladders and Ranks" }, {
        id: "rules",
        label: "Movement Rules",
      }],
      onChange: (id) => {
        state.tab = id;
        state.term = "";
        search.value = "";
        state.page = 1;
        draw();
      },
    });
    const categoryFilter = selectField({
      id: "ranks-category",
      ariaLabel: "Filter ladders by category",
      value: state.category,
      options: [{ value: "all", label: "All Categories" }],
      onChange: (event) => {
        state.category = event.target.value;
        draw();
      },
    });
    const categoryHost = h(
      "div",
      { class: "member-status-filter" },
      categoryFilter,
    );
    const matchesSearch = (value) => {
      const normalize = (text) =>
        String(text ?? "").normalize("NFKD").replace(/\p{M}/gu, "")
          .toLocaleLowerCase();
      const text = normalize(value);
      return normalize(state.term).trim().split(/\s+/).filter(Boolean).every(
        (term) => text.includes(term),
      );
    };

    // ----------------------------------------------------------------- data
    const loadCategories = async () => {
      try {
        const cats = await api.read((c) =>
          c.from("categories").select(CATEGORY_SELECT).is("deleted_at", null)
            .order("sort_order")
        );
        state.ratingBandsAvailable = true;
        return cats;
      } catch (error) {
        if (!isRatingBandSchemaUnavailable(error)) throw error;
        state.ratingBandsAvailable = false;
        return await api.read((c) =>
          c.from("categories").select(LEGACY_CATEGORY_SELECT).is("deleted_at", null)
            .order("sort_order")
        );
      }
    };

    async function refresh() {
      state.status = state.cats.length ? "refreshing" : "loading";
      draw();
      try {
        const [cats, rules, templates] = await Promise.all([
          loadCategories(),
          api.read((c) =>
            c.from("rank_rules").select(RULE_SELECT).is("deleted_at", null)
              .order("priority").order("name")
          ),
          api.read((c) =>
            c.from("format_templates").select("id,name").is("deleted_at", null)
              .eq("is_active", true).order("name")
          ),
        ]);
        state.cats = cats ?? [];
        state.rules = rules ?? [];
        state.templates = templates ?? [];
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
    const field = (id, label, input, hint, iconName) => {
      const resolvedIcon = iconName === undefined
        ? (/code/.test(id)
          ? "idCard"
          : /cool/.test(id)
          ? "clock"
          : /reason/.test(id)
          ? "file"
          : /result/.test(id)
          ? "trophy"
          : /matches/.test(id)
          ? "checkCircle"
          : /action/.test(id)
          ? "shuffle"
          : /name|min|max|place/.test(id)
          ? "medal"
          : "layers")
        : iconName;
      return h(
        "div",
        { class: "field" },
        label ? h("label", { for: id }, label) : null,
        resolvedIcon ? inputWithIcon(input, resolvedIcon) : input,
        hint
          ? h("span", { class: "field-hint", id: `${id}-hint` }, hint)
          : null,
      );
    };
    const select = (id, name, options, value) =>
      selectControl(
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
      const rankIndex = editing ? ranks.findIndex((r) => r.id === row.id) : -1;
      const sampleName = `${cat.name} Low`;
      const sampleCode = codeFrom(sampleName) || "beginner-low";
      const error = errorLine();
      const nameInput = h("input", {
        class: "input",
        id: "rk-name",
        name: "name",
        required: true,
        maxlength: 60,
        value: row?.name ?? "",
        placeholder: `e.g. ${sampleName}`,
      });
      const codeInput = h("input", {
        class: "input",
        id: "rk-code",
        name: "code",
        required: true,
        maxlength: 32,
        value: row?.code ?? "",
        readonly: editing,
        placeholder: `e.g. ${sampleCode}`,
      });
      const ratingMinInput = h("input", {
        class: "input",
        id: "rk-rating-min",
        name: "rating_min",
        type: "number",
        min: "0",
        max: "8",
        step: "0.001",
        value: row?.rating_min ?? "",
        placeholder: "e.g. 2.000",
      });
      const ratingMaxInput = h("input", {
        class: "input",
        id: "rk-rating-max",
        name: "rating_max",
        type: "number",
        min: "0",
        max: "8",
        step: "0.001",
        value: row?.rating_max ?? "",
        placeholder: "e.g. 2.249",
      });
      let touched = editing;
      codeInput.addEventListener("input", () => (touched = true));
      if (!editing) {
        nameInput.addEventListener("input", () => {
          if (!touched) codeInput.value = codeFrom(nameInput.value);
        });
      }
      const autoStart = !editing && ranks.length === 0;
      const alreadyStart = editing && Boolean(row.is_starting);
      const startingToggle = switchToggle({
        id: "rk-starting",
        name: "is_starting",
        label: h(
          "span",
          { class: "form-setting-label" },
          icon("checkCircle"),
          "Default Starting Rank",
        ),
        checked: autoStart || alreadyStart,
        disabled: autoStart || alreadyStart,
      });
      return openModal({
        title: editing ? "Edit Rank" : "New Rank",
        eyebrow: cat.name,
        icon: "medal",
        description:
          "Set the rank name, unique code and starting status within this category.",
        confirmLabel: editing ? "Save Changes" : "Add Rank",
        body: h(
          "div",
          { class: "form-grid" },
          h(
            "div",
            { class: "member-decision-subject form-grid-wide" },
            h(
              "span",
              { class: "member-avatar is-icon", "aria-hidden": "true" },
              icon(editing ? "medal" : "layers"),
            ),
            h(
              "div",
              { class: "member-meta" },
              h(
                "div",
                { class: "member-decision-name" },
                h(
                  "strong",
                  { class: "member-name" },
                  editing ? row.name : cat.name,
                ),
                editing
                  ? badge(
                    `Rank #${
                      rankIndex >= 0 ? rankIndex + 1 : 1
                    } of ${ranks.length}`,
                    "info",
                  )
                  : badge(
                    `${ranks.length} ${ranks.length === 1 ? "rank" : "ranks"}`,
                    ranks.length ? "success" : "neutral",
                  ),
                alreadyStart ? badge("Starting Rank", "success") : null,
              ),
              h(
                "span",
                { class: "sub member-subtext" },
                editing
                  ? `${cat.name} (${cat.code}) • ${
                    OVERFLOW[ladder.overflow] ?? "Rank Ladder"
                  }`
                  : `${cat.code} • ${
                    OVERFLOW[ladder.overflow] ?? "Rank Ladder"
                  }`,
              ),
            ),
          ),
          field(
            "rk-name",
            "Rank Name *",
            nameInput,
            "Shown on member profiles and brackets.",
          ),
          field(
            "rk-code",
            "Code *",
            codeInput,
            editing
              ? "The code cannot be changed after the rank is created."
              : "Lowercase letters, numbers, hyphen. Made from the name.",
            editing ? "lock" : "idCard",
          ),
          state.ratingBandsAvailable
            ? field(
              "rk-rating-min",
              "Rating Range From",
              ratingMinInput,
              "Optional club reference only; not a verified external rating.",
              "medal",
            )
            : null,
          state.ratingBandsAvailable
            ? field(
              "rk-rating-max",
              "Rating Range To",
              ratingMaxInput,
              "Use three decimal places, up to 8.000.",
              "medal",
            )
            : null,
          h(
            "div",
            { class: "form-grid-wide" },
            field(
              "rk-starting",
              "Starting Rank",
              h("div", { class: "form-setting" }, startingToggle),
              autoStart
                ? "The first rank in a ladder automatically starts as the default rank."
                : alreadyStart
                ? "This rank is currently the default starting rank for this category."
                : "Make this the initial rank assigned to new members in this category.",
              false,
            ),
          ),
          h(
            "div",
            {
              class: `modal-callout ${
                editing ? "" : "is-success "
              }form-grid-wide`,
            },
            h(
              "span",
              { class: "modal-callout-icon", "aria-hidden": "true" },
              icon(editing ? "info" : "layers"),
            ),
            h(
              "div",
              { class: "modal-callout-text" },
              h(
                "strong",
                { class: "decision-impact-title" },
                editing
                  ? "Renaming preserves rank history"
                  : autoStart
                  ? "First step on the ladder"
                  : "Added at the top of the ladder",
              ),
              h(
                "p",
                { class: "decision-impact-text" },
                editing
                  ? "Members who hold this rank and past tournament records will automatically display the updated name."
                  : "The new rank is added at the top of the ladder. Use the arrows to move it.",
              ),
            ),
          ),
          h("div", { class: "form-grid-wide" }, error),
        ),
        onConfirm: async (form) => {
          const name = String(form.get("name") ?? "").trim();
          const code = String(form.get("code") ?? "").trim();
          const minText = String(form.get("rating_min") ?? "").trim();
          const maxText = String(form.get("rating_max") ?? "").trim();
          const ratingMin = minText === "" ? null : Number(minText);
          const ratingMax = maxText === "" ? null : Number(maxText);
          const makeStarting = form.get("is_starting") === "on";
          if (!name) return showError(error, "Enter a name.");
          if (!CODE_RE.test(code)) {
            return showError(
              error,
              "The code uses lowercase letters, numbers, hyphen or underscore (up to 32).",
            );
          }
          if (state.ratingBandsAvailable && (
            (ratingMin === null) !== (ratingMax === null) ||
            (ratingMin !== null &&
              (!Number.isFinite(ratingMin) || !Number.isFinite(ratingMax) ||
                ratingMin < 0 || ratingMax > 8 || ratingMin > ratingMax))
          )) {
            return showError(
              error,
              "Enter both rating values from 0.000 to 8.000, with the first value no higher than the second.",
            );
          }
          try {
            if (editing) {
              const done = await api.read((c) =>
                c.from("ranks").update({
                  name,
                  ...(state.ratingBandsAvailable
                    ? { rating_min: ratingMin, rating_max: ratingMax }
                    : {}),
                }).eq("id", row.id).eq(
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
              if (makeStarting && !alreadyStart) {
                await api.rpc("set_starting_rank", {
                  p_rank_id: row.id,
                  p_key: api.newKey(),
                });
              }
            } else {
              await api.create("ranks", key, {
                org_id: getOrgId(),
                ladder_id: ladder.id,
                code,
                name,
                ...(state.ratingBandsAvailable
                  ? { rating_min: ratingMin, rating_max: ratingMax }
                  : {}),
                sort_order: ranks.length
                  ? ranks[ranks.length - 1].sort_order + 1
                  : 0,
                is_starting: autoStart, // the first rank starts as the starting rank
              });
              if (makeStarting && !autoStart) {
                await api.rpc("set_starting_rank", {
                  p_rank_id: key,
                  p_key: api.newKey(),
                });
              }
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
      const count = h("output", {
        class: "decision-reason-count",
        id: "rk-reason-count",
        for: "rk-reason",
      }, "0 / 500");
      return openModal({
        title,
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
              icon(table === "rank_rules" ? "layers" : "medal"),
            ),
            h(
              "div",
              { class: "member-meta" },
              h(
                "div",
                { class: "member-decision-name" },
                h("strong", { class: "member-name" }, row.name),
                row.is_starting
                  ? badge("Starting Rank", "success")
                  : (row.is_active !== undefined
                    ? badge(
                      row.is_active ? "Active" : "Paused",
                      row.is_active ? "success" : "neutral",
                    )
                    : null),
              ),
              h(
                "span",
                { class: "sub member-subtext" },
                row.code ||
                  (table === "rank_rules"
                    ? "Movement Rule"
                    : table === "rank_ladders"
                    ? "Rank Ladder"
                    : "Rank"),
              ),
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
                  "Remove this record",
                ),
                h("p", { class: "decision-impact-text" }, note),
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
                  { for: "rk-reason" },
                  "Reason",
                  h("span", { class: "decision-required" }, " *"),
                ),
                count,
              ),
              h("textarea", {
                class: "input textarea",
                id: "rk-reason",
                name: "reason",
                rows: 4,
                minlength: 3,
                maxlength: 500,
                required: true,
                placeholder:
                  "Provide context or explanation for this decision...",
                "aria-describedby": "rk-reason-help rk-reason-count",
                onInput: (event) => {
                  count.textContent = `${event.target.value.length} / 500`;
                },
              }),
              h("p", {
                class: "muted decision-reason-help",
                id: "rk-reason-help",
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
          { class: "member-cell" },
          h(
            "span",
            { class: "member-avatar is-icon", "aria-hidden": "true" },
            icon("layers"),
          ),
          h(
            "div",
            { class: "member-meta" },
            h("h2", { class: "settings-title" }, cat.name),
            h(
              "span",
              { class: "muted" },
              cat.is_active ? cat.code : "Retired Category",
            ),
          ),
        ),
        badge(
          `${ranks.length} ${ranks.length === 1 ? "rank" : "ranks"}`,
          ranks.length ? "success" : "neutral",
        ),
      );
      if (!ladder) {
        return h(
          "div",
          { class: "member-panel ladder-card" },
          head,
          h("p", { class: "muted" }, "This category has no rank ladder yet."),
          h(
            "div",
            { class: "actions ladder-actions" },
            button({
              label: "Set Up Ladder",
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
                h("span", { class: "member-name" }, r.name),
                h(
                  "span",
                  { class: "rank-meta" },
                  h("span", { class: "sub member-subtext" }, r.code),
                  ratingBand(r)
                    ? h("span", { class: "sub member-subtext" }, ratingBand(r))
                    : null,
                  r.is_starting ? badge("Starting Rank", "success") : null,
                ),
              ),
              h(
                "span",
                { class: "row-actions" },
                iconButton({
                  label: `Move ${r.name} up`,
                  icon: "chevronUp",
                  size: "sm",
                  variant: "info",
                  disabled: i === ranks.length - 1,
                  onClick: () => move(ladder, ranks, i, 1),
                }),
                iconButton({
                  label: `Move ${r.name} down`,
                  icon: "chevronDown",
                  size: "sm",
                  variant: "info",
                  disabled: i === 0,
                  onClick: () => move(ladder, ranks, i, -1),
                }),
                iconButton({
                  label: `Edit ${r.name}`,
                  icon: "edit",
                  size: "sm",
                  variant: "edit",
                  onClick: () => rankModal(cat, ladder, r),
                }),
                iconButton({
                  label: r.is_starting
                    ? `${r.name} is the starting rank`
                    : `Make ${r.name} the starting rank`,
                  icon: "check",
                  size: "sm",
                  variant: "success",
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
                  size: "sm",
                  variant: "danger",
                  onClick: () =>
                    deleteModal(r, {
                      table: "ranks",
                      title: "Delete This Rank",
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
        { class: "member-panel ladder-card" },
        head,
        field(
          `ov-${cat.id}`,
          "Boundary Behavior",
          overflowSelect,
          "How movement behaves at the highest and lowest rank.",
        ),
        h("div", { class: "ladder-order muted" }, "Highest Rank First"),
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
          { class: "actions ladder-actions" },
          button({
            label: "Add Rank",
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
                  title: "Delete This Ladder",
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
      if (c.bracket_tier) parts.push(`${c.bracket_tier} Bracket`);
      if (c.bracket_result) parts.push(toProperCase(c.bracket_result));
      if (c.placement) parts.push(`placed ${c.placement}`);
      if (c.min_matches) parts.push(`at least ${c.min_matches} matches`);
      return parts.length ? parts.join(", ") : "Any Result";
    }
    const actionText = (r) =>
      r.action === "retain"
        ? "Stay"
        : `${ACTION_LABEL[r.action]} ${r.levels} level${
          r.levels === 1 ? "" : "s"
        }`;
    const templateName = (r) => r.format_template_id
      ? templateLabel(r.template?.name ||
        state.templates.find((t) => t.id === r.format_template_id)?.name ||
        "Unavailable Template")
      : "All Formats";

    function ruleModal(row) {
      const editing = Boolean(row);
      const key = row?.id ?? api.newKey();
      const c = row?.conditions ?? {};
      const error = errorLine();
      const rankOptions = [{ value: "", label: "No Limit" }].concat(
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
        { value: "up", label: "Move Up" },
        { value: "down", label: "Move Down" },
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
      const forfeits = switchToggle({
        id: "ru-forfeits",
        name: "exclude_forfeits",
        label: h(
          "span",
          { class: "form-setting-label" },
          icon("trophy"),
          "Ignore Forfeits",
        ),
        checked: row?.exclude_forfeits ?? true,
      });
      const activeBox = switchToggle({
        id: "ru-active",
        name: "is_active",
        label: h(
          "span",
          { class: "form-setting-label" },
          icon("checkCircle"),
          "Rule Is Active",
        ),
        checked: row?.is_active ?? true,
      });
      return openModal({
        title: editing ? "Edit Rule" : "New Rule",
        eyebrow: editing ? row.name : "Rank Movement",
        icon: "layers",
        description:
          "Choose the results that trigger a rank change and set its limits.",
        size: "lg",
        confirmLabel: editing ? "Save Changes" : "Add Rule",
        body: h(
          "div",
          { class: "form-grid" },
          h(
            "div",
            { class: "form-grid-wide" },
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
                placeholder: "e.g. Bracket champion promotion",
              }),
              "Shown in the movement rules list and rank history.",
            ),
          ),
          h(
            "div",
            { class: "profile-subsection-divider form-grid-wide" },
            h(
              "span",
              { class: "profile-subsection-label" },
              "When a member's final result is",
            ),
          ),
          h("div", { class: "form-grid-wide" }, field(
            "ru-template",
            "Format Template",
            select("ru-template", "format_template_id", [
              { value: "", label: "All Formats" },
              ...state.templates.map((t) => ({
                value: t.id,
                label: templateLabel(t.name),
              })),
              ...(row?.format_template_id &&
                  !state.templates.some((t) => t.id === row.format_template_id)
                ? [{
                  value: row.format_template_id,
                  label: templateLabel(row.template?.name || "Unavailable Template (Saved)"),
                }]
                : []),
            ], row?.format_template_id),
            "Apply only to divisions created with this template. All Formats also includes older divisions with an unknown source template.",
          )),
          field(
            "ru-tier",
            "Bracket",
            select("ru-tier", "bracket_tier", [
              { value: "", label: "Any" },
              { value: "H", label: "H Bracket" },
              { value: "L", label: "L Bracket" },
            ], c.bracket_tier),
            "Filter by tournament bracket tier.",
          ),
          field(
            "ru-result",
            "Result in That Bracket",
            select("ru-result", "bracket_result", [
              { value: "", label: "Any" },
              { value: "won", label: "Won the Bracket" },
              { value: "lost", label: "Lost (Eliminated)" },
            ], c.bracket_result),
            "Outcome required in the chosen bracket.",
          ),
          field(
            "ru-place",
            "Final Placement",
            h("input", {
              class: "input",
              id: "ru-place",
              name: "placement",
              type: "number",
              min: 1,
              max: 9999,
              step: 1,
              value: c.placement ?? "",
              placeholder: "Any placement (e.g. 1)",
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
              placeholder: "e.g. 3",
            }),
            "Minimum completed matches required to qualify.",
          ),
          h(
            "div",
            { class: "profile-subsection-divider form-grid-wide" },
            h("span", { class: "profile-subsection-label" }, "Then"),
          ),
          field(
            "ru-action",
            "Rank Change",
            actionSel,
            "Direction to move on the rank ladder.",
          ),
          field(
            "ru-levels",
            "By How Many Levels",
            levels,
            "1 to 10. Stay uses 0.",
          ),
          field(
            "ru-min",
            "Never Below",
            select("ru-min", "min_rank_id", rankOptions, row?.min_rank_id),
            "Lowest rank where downward movement stops.",
          ),
          field(
            "ru-max",
            "Never Above",
            select("ru-max", "max_rank_id", rankOptions, row?.max_rank_id),
            "Highest rank where upward movement stops.",
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
              placeholder: "0",
            }),
            "Cooldown period in days (0 for none).",
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
              placeholder: "100",
            }),
            "Lower numbers are checked first.",
          ),
          field(
            "ru-forfeits",
            "Forfeits & Withdrawals",
            h("div", { class: "form-setting" }, forfeits),
            "Exclude matches ended by walkover or forfeit.",
            false,
          ),
          field(
            "ru-active",
            "Rule Status",
            h("div", { class: "form-setting" }, activeBox),
            "Apply this rule when tournament results are posted.",
            false,
          ),
          h("div", { class: "form-grid-wide" }, error),
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
            format_template_id: form.get("format_template_id") || null,
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
            if (!editing) {
              state.tab = "rules";
              state.term = "";
              search.value = "";
              state.page = 1;
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
            key: "name",
            label: "Rule",
            render: (r) =>
              h(
                "div",
                { class: "member-cell" },
                h("span", {
                  class: "member-avatar is-icon",
                  "aria-hidden": "true",
                }, icon("medal")),
                h(
                  "div",
                  { class: "member-meta" },
                  h("span", { class: "member-name" }, r.name),
                  h(
                    "span",
                    { class: "sub member-subtext" },
                    `Priority ${r.priority}`,
                  ),
                ),
              ),
          },
          {
            key: "format_template",
            label: "Format Template",
            render: templateName,
          },
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
            actionCount: 3,
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
                  label: r.is_active
                    ? `Turn off ${r.name}`
                    : `Turn on ${r.name}`,
                  icon: r.is_active ? "eye" : "check",
                  size: "sm",
                  variant: r.is_active ? "warning" : "success",
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
                  size: "sm",
                  variant: "danger",
                  onClick: () =>
                    deleteModal(r, {
                      table: "rank_rules",
                      title: "Delete This Rule",
                      note:
                        "Past rank changes keep the name of the rule that made them.",
                    }),
                }),
              ),
          },
        ],
      };
      const rows = state.rules.filter((rule) =>
        matchesSearch([
          rule.name,
          templateName(rule),
          conditionText(rule.conditions),
          actionText(rule),
          rankName(rule.min_rank_id),
          rankName(rule.max_rank_id),
          rule.is_active ? "Active" : "Off",
          rule.priority,
        ].join(" "))
      );
      state.page = Math.min(
        state.page,
        Math.max(1, Math.ceil(rows.length / DEFAULT_PAGE_SIZE)),
      );
      return h(
        "div",
        { class: "stack" },
        h(
          "div",
          { class: "member-directory-card is-auto-grid" },
          h(
            "div",
            { class: "table-host" },
            dataTable({
              pageSize: 0, // Rank rules are paged by the surrounding view.
              searchable: false,
              hasFilters: Boolean(state.term.trim()),
              onReset: () => {
                state.term = "";
                search.value = "";
                state.page = 1;
                draw();
              },
              schema,
              rows: rows.slice(
                (state.page - 1) * DEFAULT_PAGE_SIZE,
                state.page * DEFAULT_PAGE_SIZE,
              ),
              state: state.status,
              ariaLabel: "Rank Rules",
              onRetry: refresh,
              emptyTitle: state.term.trim()
                ? "No matching rules"
                : "No rules yet",
              emptyText:
                "Add a rule to say how results move members up or down.",
            }),
          ),
          state.status === "loading" || state.status === "error"
            ? null
            : pagination({
              page: state.page,
              pageSize: DEFAULT_PAGE_SIZE,
              total: rows.length,
              onPage: (next) => {
                state.page = next;
                draw();
              },
            }),
        ),
      );
    }

    // ---------------------------------------------------------------- layout
    function draw() {
      viewFilter.setOptions([
        {
          id: "ladders",
          label: "Ladders and Ranks",
          badge: state.status === "loading" ? "—" : state.cats.length,
        },
        {
          id: "rules",
          label: "Movement Rules",
          badge: state.status === "loading" ? "—" : state.rules.length,
        },
      ], state.tab);
      if (
        state.category !== "all" &&
        !state.cats.some((cat) => cat.id === state.category)
      ) {
        state.category = "all";
        categoryFilter.value = "all";
      }
      categoryFilter.setOptions([
        { value: "all", label: "All Categories" },
        ...state.cats.map((cat) => ({ value: cat.id, label: cat.name })),
      ]);
      categoryHost.hidden = state.tab !== "ladders";
      search.setAttribute(
        "placeholder",
        state.tab === "ladders"
          ? "Search categories or ranks..."
          : "Search movement rules...",
      );
      const categories = state.cats.filter((cat) =>
        (state.category === "all" || cat.id === state.category) &&
        matchesSearch(
          [
            cat.name,
            cat.code,
            ...liveRanks(liveLadder(cat)).flatMap(
              (rank) => [rank.name, rank.code],
            ),
          ].join(" "),
        )
      );
      if (state.status === "error") {
        body.replaceChildren(
          h(
            "div",
            { class: "member-panel home-error", role: "alert" },
            h("p", {}, "The ranks could not be loaded."),
            button({ label: "Try Again", icon: "refresh", onClick: refresh }),
          ),
        );
        return;
      }
      if (state.status === "loading" && state.tab === "ladders") {
        body.replaceChildren(
          h(
            "div",
            {
              class: "member-panel settings-card is-loading",
              "aria-busy": "true",
            },
            h("span", { class: "sk-line" }),
            h("span", { class: "sk-line sk-wide" }),
          ),
        );
        return;
      }
      body.replaceChildren(
        state.tab === "ladders"
          ? (categories.length
            ? h("div", { class: "rank-grid" }, ...categories.map(ladderCard))
            : h(
              "div",
              { class: "member-panel" },
              h(
                "p",
                {},
                state.cats.length
                  ? "No categories or ranks match these filters."
                  : "Add categories first, then set up their ladders.",
              ),
              state.cats.length
                ? button({
                  label: "Clear Filters",
                  icon: "x",
                  onClick: () => {
                    state.term = "";
                    state.category = "all";
                    search.value = "";
                    categoryFilter.value = "all";
                    draw();
                  },
                })
                : null,
            ))
          : rulesView(),
      );
    }

    page.append(
      adminHero({
        title: "Ranks",
        chip: "Ranks Management",
        description:
          "Each category has a ladder of ranks. Rules decide how results move members along it.",
        actions: [
          button({
            label: "New Rule",
            variant: "primary",
            icon: "plus",
            onClick: () => ruleModal(null),
          }),
        ],
      }),
      h(
        "div",
        { class: "toolbar admin-members-toolbar has-status-badges" },
        h("div", { class: "ranks-search-filters" }, search, categoryHost),
        viewFilter,
      ),
      body,
    );
    refresh();
    return page;
  }

  return { ranksPage };
}
