// Settings page (PLAN 4.1). Every change goes through update_setting, which checks settings.manage, validates the
// value against the key's rule, takes an idempotency key and writes the audit row. The checks here (ranges, required
// text) only save a round trip: the database refuses anything outside the rules, whatever this page sends.
import {
  adminHero,
  alertBox,
  attachPagePattern,
  badge,
  button,
  checkbox,
  field,
  h,
  icon,
  selectField,
  switchToggle,
  tabs,
  textareaField,
  toast,
} from "./ui.js";

const METHODS = [
  { value: "cash", label: "Cash" },
  { value: "gcash", label: "GCash" },
  { value: "maya", label: "Maya" },
  { value: "bank_transfer", label: "Bank Transfer" },
];

// type: switch | int | money | text | textarea | methods | rule | readonly
const GROUPS = [
  {
    id: "general",
    label: "General",
    title: "Club Details",
    eyebrow: "CLUB INFORMATION",
    icon: "settings",
    description: "Club profile, public name, and standardized business time zone.",
    items: [
      { key: "club.name", type: "text", label: "Club Name", max: 80 },
      {
        key: "timezone",
        type: "readonly",
        label: "Business Time Zone",
        hint: "Every date and time in the app uses this zone. It is fixed.",
      },
    ],
  },
  {
    id: "members",
    label: "Members",
    title: "Members and Sign-up",
    eyebrow: "MEMBERSHIP RULES",
    icon: "user",
    description: "New member registration rules, initial password policies, and ID formats.",
    items: [
      {
        key: "members.signup_enabled",
        type: "switch",
        label: "Allow new people to sign up",
        title: "Member Applications",
        icon: "userPlus",
        hint: "Allow new people to submit registration applications through the Join Club portal.",
      },
      {
        key: "members.auto_approve_imported",
        type: "switch",
        label: "Approve imported members automatically",
        title: "Auto-Approve Imported",
        icon: "checkCircle",
        hint: "Automatically approve imported roster members upon their first account sign-in.",
      },
      {
        key: "members.temp_password_days",
        type: "int",
        label: "First password expires after",
        suffix: "days",
        min: 0,
        max: 365,
        hint: "0 means the first password never expires.",
      },
      {
        key: "members.id_prefix",
        type: "readonly",
        label: "Member ID Prefix",
        hint: "Set up with the club. It is fixed.",
      },
      {
        key: "members.id_pattern",
        type: "readonly",
        label: "Member ID Format",
        hint: "Set up with the club. It is fixed.",
      },
    ],
  },
  {
    id: "booking",
    label: "Bookings",
    title: "Court Bookings",
    eyebrow: "COURT SCHEDULING",
    icon: "calendarCheck",
    description: "Reservation approvals, advance windows, slot durations, and cancellation policies.",
    items: [
      {
        key: "booking.approval_required",
        type: "switch",
        label: "Admin approval is required",
        title: "Admin Approval Required",
        icon: "calendarCheck",
        hint: "When off, reservations are instantly confirmed if the court slot is open.",
      },
      {
        key: "booking.slot_minutes",
        type: "int",
        label: "Slot Length",
        suffix: "minutes",
        min: 15,
        max: 240,
      },
      {
        key: "booking.advance_days",
        type: "int",
        label: "Members can book up to",
        suffix: "days ahead",
        min: 1,
        max: 365,
      },
      {
        key: "booking.max_participants",
        type: "int",
        label: "Players per booking (at most)",
        min: 1,
        max: 20,
      },
      {
        key: "booking.request_expiry_hours",
        type: "int",
        label: "An unapproved request expires after",
        suffix: "hours",
        min: 1,
        max: 168,
      },
      {
        key: "booking.cancel_cutoff_hours",
        type: "int",
        label: "Free Cancellation Until",
        suffix: "hours before",
        min: 0,
        max: 168,
      },
      {
        key: "booking.cancel_fee",
        type: "money",
        label: "Late Cancellation Fee",
        prefix: "PHP",
      },
      {
        key: "booking.no_show_fee",
        type: "money",
        label: "No-show Fee",
        prefix: "PHP",
      },
    ],
  },
  {
    id: "payments",
    label: "Payments",
    title: "Payments",
    eyebrow: "PAYMENTS & METHODS",
    icon: "currency",
    description: "Accepted payment channels and mandatory proof-of-payment requirements.",
    items: [
      {
        key: "payments.required.court_booking",
        type: "switch",
        label: "Payment is required for court bookings",
        title: "Required for Bookings",
        icon: "calendar",
        hint: "A court reservation remains pending until proof of payment is verified.",
      },
      {
        key: "payments.required.event_registration",
        type: "switch",
        label: "Payment is required for event registrations",
        title: "Required for Events",
        icon: "trophy",
        hint: "Division tournament entries require payment verification before confirmation.",
      },
      {
        key: "payments.proof_required_non_cash",
        type: "switch",
        label: "Proof of payment is required for non-cash methods",
        title: "Require Digital Proof",
        icon: "file",
        hint: "GCash, Maya, and bank transfers require an uploaded receipt or reference.",
      },
      {
        key: "payments.methods",
        type: "methods",
        label: "Accepted Payment Methods",
      },
      {
        key: "payments.instructions",
        type: "textarea",
        label: "Payment Instructions Shown to Members",
        max: 1000,
        hint:
          "For example the GCash number or bank account name. Up to 1,000 characters.",
      },
    ],
  },
  {
    id: "events",
    label: "Events",
    title: "Events and Tournaments",
    eyebrow: "TOURNAMENT RULES",
    icon: "trophy",
    description: "Division registration approval, waitlist settings, and default match scoring.",
    items: [
      {
        key: "events.registration_approval_required",
        type: "switch",
        label: "Admin approval is required to join an event",
        title: "Registration Approval Required",
        icon: "checkCircle",
        hint: "Staff must review and approve player tournament registrations.",
      },
      {
        key: "events.waitlist_enabled",
        type: "switch",
        label: "Allow a waitlist when an event is full",
        title: "Enable Waitlist",
        icon: "clock",
        hint: "Allow players to join a standby queue when division slots are filled.",
      },
      {
        key: "events.default_scoring_rule",
        type: "rule",
        label: "Default Scoring Rule",
      },
    ],
  },
  {
    id: "ranks",
    label: "Ranks",
    title: "Ranks",
    eyebrow: "RANKING ENGINE",
    icon: "medal",
    description: "Automated ladder movement and skill level progression following events.",
    items: [
      {
        key: "ranks.movement_enabled",
        type: "switch",
        label: "Ranks Move Up and Down After Events",
        title: "Dynamic Rank Ladder Movement",
        icon: "medal",
        hint:
          "Movement is applied once per member when a division is finalized.",
      },
    ],
  },
  {
    id: "public",
    label: "Public Pages",
    title: "Public Pages",
    eyebrow: "PUBLIC VISIBILITY",
    icon: "eye",
    description: "Configure leaderboard and podium visibility for non-signed-in visitors.",
    items: [
      {
        key: "public.results_enabled",
        type: "switch",
        label: "Show finished divisions' podiums to everyone",
        title: "Public Tournament Podiums",
        icon: "trophy",
        hint:
          "Visitors who are not signed in see the top three of each recently finished division, with display names only.",
      },
      {
        key: "public.leaderboard_enabled",
        type: "switch",
        label: "Show the leaderboard to everyone",
        title: "Public Club Leaderboard",
        icon: "eye",
        hint:
          "Visitors who are not signed in see each ranked player's display name, category and rank. Nothing else.",
      },
      {
        key: "public.members_enabled",
        type: "switch",
        label: "Show the member list to everyone",
        title: "Public Member List",
        icon: "user",
        hint:
          "Visitors see each member's display name, photo and Club Rank on the Members page. Never member IDs or contact details.",
      },
    ],
  },
  {
    id: "member_menu",
    label: "Member Menu",
    title: "Member Menu",
    eyebrow: "PORTAL NAVIGATION",
    icon: "layers",
    description: "Configure navigation links and module visibility for club members.",
    items: [
      {
        key: "member_menu.book",
        type: "switch",
        label: "Show Book a Court",
        title: "Book a Court",
        icon: "calendar",
        hint: "Allow members to book courts and reserve time slots from the portal.",
      },
      {
        key: "member_menu.bookings",
        type: "switch",
        label: "Show My Bookings",
        title: "My Bookings",
        icon: "clock",
        hint: "Allow members to view, manage, and track their court booking history.",
      },
      {
        key: "member_menu.events",
        type: "switch",
        label: "Show Events",
        title: "Events & Tournaments",
        icon: "trophy",
        hint: "Allow members to browse club events, register for divisions, and view brackets.",
      },
      {
        key: "member_menu.ranking",
        type: "switch",
        label: "Show Ranking",
        title: "Club Ranking",
        icon: "medal",
        hint: "Allow members to view skill category ladders, leaderboards, and member positions.",
      },
    ],
  },
  {
    id: "security",
    label: "Security",
    title: "Security",
    eyebrow: "SESSION & SECURITY",
    icon: "lock",
    description: "Account idle timeout rules and administrative session protection.",
    items: [
      {
        key: "session.idle_minutes",
        type: "int",
        label: "Sign people out after",
        suffix: "minutes without activity",
        min: 5,
        max: 120,
        hint: "Applies the next time someone signs in.",
      },
    ],
  },
];

const ITEMS = GROUPS.flatMap((g) => g.items);
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

export function createSettingsPages({ api }) {
  async function load() {
    const [rows, rules] = await Promise.all([
      api.read((c) =>
        c.from("settings").select("key,value").is("unit_id", null).is(
          "deleted_at",
          null,
        )
      ),
      api.read((c) =>
        c.from("scoring_rules").select("name").is("deleted_at", null).order(
          "name",
        )
      ),
    ]);
    return {
      values: Object.fromEntries((rows ?? []).map((r) => [r.key, r.value])),
      rules: (rules ?? []).map((r) => r.name),
    };
  }

  function settingsPage() {
    const page = h("div", {
      class: "page admin-dashboard admin-members-page admin-settings-page",
    });
    attachPagePattern(page);
    const body = h("div", { class: "settings-body" });
    let data = null;
    let activeId = GROUPS[0].id;
    // One idempotency key per (setting, value): pressing Save again after a network failure repeats the same request.
    const keys = new Map();

    page.append(
      adminHero({
        title: "Settings",
        chip: "Club Settings",
        description:
          "Rules for sign-up, bookings, payments, events and security. Every change is recorded.",
        actions: [
          button({
            label: "Refresh",
            icon: "refresh",
            variant: "secondary",
            onClick: () => start(),
          }),
        ],
      }),
      body,
    );

    function drawLoading() {
      body.replaceChildren(
        h(
          "div",
          {
            class: "member-panel settings-card is-loading",
            "aria-busy": "true",
          },
          h("span", { class: "sk-line" }),
          h("span", { class: "sk-line sk-wide" }),
          h("span", { class: "sk-line" }),
        ),
      );
    }

    function drawError(error) {
      body.replaceChildren(
        h(
          "div",
          { class: "member-panel home-error", role: "alert" },
          h("p", {}, error?.message ?? "The settings could not be loaded."),
          button({ label: "Try Again", icon: "refresh", onClick: start }),
        ),
      );
    }

    function show(group) {
      body.lastElementChild.replaceWith(drawGroup(group));
    }

    function drawGroup(group) {
      const current = { ...data.values };
      const edited = {}; // key -> new JSON value, only for fields the user changed
      const bad = {}; // key -> message from the quick checks
      const panelId = `panel-${group.id}`;
      const saveBtn = button({
        label: "Save Changes",
        variant: "primary",
        icon: "check",
        disabled: true,
        onClick: save,
      });
      const resetBtn = button({
        label: "Discard",
        variant: "ghost",
        disabled: true,
        onClick: () => show(group),
      });
      const status = h("div", { class: "settings-status", role: "status" });
      const changeCount = h("span", {
        class: "settings-change-count", role: "status", "aria-live": "polite",
      }, "No unsaved changes");

      function touch(key, value) {
        const item = ITEMS.find((i) => i.key === key);
        if (same(value, current[key])) delete edited[key];
        else edited[key] = value;
        delete bad[key];
        const count = Object.keys(edited).length;
        const dirty = count > 0;
        changeCount.textContent = count
          ? `${count} unsaved ${count === 1 ? "change" : "changes"}`
          : "No unsaved changes";
        changeCount.classList.toggle("is-dirty", dirty);
        saveBtn.disabled = !dirty;
        resetBtn.disabled = !dirty;
        status.replaceChildren();
        return item;
      }

      function switchTile(item) {
        const id = `set-${item.key.replace(/[^a-z0-9]/g, "-")}`;
        const val = edited[item.key] !== undefined ? edited[item.key] : current[item.key];
        const checked = val === true;
        const isMemberMenu = group.id === "member_menu";
        const activeText = item.activeText || (isMemberMenu ? "Visible" : "Enabled");
        const inactiveText = item.inactiveText || (isMemberMenu ? "Hidden" : "Disabled");

        const statusPill = badge(checked ? activeText : inactiveText, checked ? "success" : "neutral");
        statusPill.classList.add("setting-switch-status-pill");

        const toggle = switchToggle({
          id,
          label: "",
          checked,
          onChange: (on) => {
            touch(item.key, on);
            statusPill.textContent = on ? activeText : inactiveText;
            statusPill.className = `badge badge-${on ? "success" : "neutral"} setting-switch-status-pill`;
            tile.classList.toggle("is-active", on);
          },
        });

        const iconEl = icon(item.icon || "layers");
        const tile = h(
          "div",
          { class: `setting-switch-tile${checked ? " is-active" : ""}` },
          h(
            "div",
            { class: "setting-switch-tile-header" },
            h("div", { class: "setting-switch-tile-icon" }, iconEl),
            h(
              "div",
              { class: "setting-switch-tile-info" },
              h(
                "div",
                { class: "setting-switch-tile-heading" },
                h("label", { class: "setting-switch-tile-title", for: id }, item.title || item.label),
                statusPill,
              ),
              item.hint ? h("p", { class: "setting-switch-tile-hint" }, item.hint) : null,
            ),
            h("div", { class: "setting-switch-tile-action" }, toggle),
          ),
        );
        return tile;
      }

      function control(item) {
        const id = `set-${item.key.replace(/[^a-z0-9]/g, "-")}`;
        const value = current[item.key];
        switch (item.type) {
          case "switch":
            return switchTile(item);
          case "int":
          case "money":
            return field({
              id,
              label: item.label,
              type: "number",
              value: value ?? "",
              min: item.type === "money" ? 0 : item.min,
              max: item.type === "money" ? 100000 : item.max,
              step: item.type === "money" ? "0.01" : "1",
              prefix: item.prefix,
              suffix: item.suffix,
              hint: item.hint,
              onInput: (e) => {
                const text = e.target.value.trim();
                touch(item.key, text === "" ? null : Number(text));
              },
            });
          case "text":
            return field({
              id,
              label: item.label,
              value: value ?? "",
              hint: item.hint,
              onInput: (e) => touch(item.key, e.target.value),
            });
          case "textarea":
            return textareaField({
              id,
              label: item.label,
              value: value ?? "",
              rows: 3,
              hint: item.hint,
              onInput: (e) => touch(item.key, e.target.value),
            });
          case "rule":
            return selectField({
              id,
              label: item.label,
              value,
              options: data.rules.includes(value)
                ? data.rules
                : [value, ...data.rules].filter((v) => v != null),
              hint: item.hint,
              onChange: (e) => touch(item.key, e.target.value),
            });
          case "methods": {
            const chosen = new Set(Array.isArray(value) ? value : []);
            return h(
              "fieldset",
              { class: "settings-methods" },
              h("legend", {}, item.label),
              h("div", { class: "settings-method-options" },
                ...METHODS.map((m) =>
                  checkbox({
                    id: `${id}-${m.value}`,
                    label: m.label,
                    checked: chosen.has(m.value),
                    onChange: (on) => {
                      if (on) chosen.add(m.value);
                      else chosen.delete(m.value);
                      touch(
                        item.key,
                        METHODS.map((x) => x.value).filter((v) => chosen.has(v)),
                      );
                    },
                  })
                ),
              ),
            );
          }
          default:
            return h(
              "div",
              { class: "settings-readonly" },
              h("div", { class: "settings-readonly-label" }, item.label),
              h(
                "div",
                { class: "settings-readonly-value" },
                String(value ?? "—"),
              ),
              item.hint ? h("div", { class: "muted" }, item.hint) : null,
            );
        }
      }

      function regularField(item) {
        const isWide = item.type === "textarea" || item.type === "methods";
        return h(
          "div",
          { class: `settings-item${isWide ? " is-wide" : ""}` },
          control(item),
        );
      }

      function quickCheck() {
        const problems = [];
        for (const [key, value] of Object.entries(edited)) {
          const item = ITEMS.find((i) => i.key === key);
          if (item.type === "int" || item.type === "money") {
            const ok = typeof value === "number" && Number.isFinite(value) &&
              (item.type === "money" ||
                (Number.isInteger(value) && value >= item.min &&
                  value <= item.max)) &&
              (item.type !== "money" ||
                (value >= 0 && value <= 100000 &&
                  Math.round(value * 100) === value * 100));
            if (!ok) {
              problems.push(
                item.type === "money"
                  ? `${item.label}: enter an amount from 0 to 100,000 with at most two decimals.`
                  : `${item.label}: enter a whole number from ${item.min} to ${item.max}.`,
              );
            }
          } else if (item.type === "text" && !String(value).trim()) {
            problems.push(`${item.label} cannot be empty.`);
          } else if (
            item.type === "methods" && (!value.length)
          ) {
            problems.push("Choose at least one payment method.");
          }
        }
        return problems;
      }

      async function save() {
        const problems = quickCheck();
        if (problems.length) {
          status.replaceChildren(
            alertBox({
              tone: "error",
              title: "Check these values",
              message: problems.join(" "),
            }),
          );
          return;
        }
        saveBtn.disabled = true;
        resetBtn.disabled = true;
        const why = document.getElementById("setting-reason")?.value.trim() ||
          null;
        const failures = [];
        let saved = 0;
        for (const [key, value] of Object.entries(edited)) {
          const intent = `${key}=${JSON.stringify(value)}|${why}`;
          if (!keys.has(intent)) keys.set(intent, api.newKey());
          try {
            await api.rpc("update_setting", {
              p_key: key,
              p_value: value,
              p_reason: why,
              p_idem: keys.get(intent),
            });
            data.values[key] = value;
            saved++;
          } catch (e) {
            const own = ["22023", "42501", "CP422", "CP409"].includes(e.code) &&
              e.cause?.message;
            const label = ITEMS.find((i) => i.key === key)?.label ?? key;
            failures.push(`${label}: ${own || e.message}`);
          }
        }
        if (saved && group.id === "member_menu") {
          dispatchEvent(new CustomEvent("cpc:member-menu"));
        }
        if (saved) {
          toast(
            saved === 1 ? "Setting saved." : `${saved} settings saved.`,
            { tone: "success" },
          );
        }
        if (failures.length) {
          status.replaceChildren(
            alertBox({
              tone: "error",
              title: "Some changes were not saved",
              message: failures.join(" "),
            }),
          );
          saveBtn.disabled = false;
          resetBtn.disabled = false;
          return;
        }
        show(group);
      }

      const header = h(
        "div",
        { class: "settings-card-header" },
        h("div", { class: "section-icon settings-header-icon-squircle", "aria-hidden": "true" }, icon(group.icon || "settings")),
        h(
          "div",
          { class: "settings-header-meta" },
          h("span", { class: "settings-eyebrow" }, group.eyebrow || "SYSTEM PREFERENCES"),
          h("h2", { class: "settings-title" }, group.title),
          group.description ? h("p", { class: "settings-subtitle" }, group.description) : null,
        ),
        h(
          "div",
          { class: "settings-header-badge" },
          badge(
            group.badgeText || `${group.items.length} ${group.id === "member_menu" ? "Modules" : group.items.length === 1 ? "Option" : "Options"}`,
            "info",
          ),
        ),
      );

      const switches = group.items.filter((it) => it.type === "switch");
      const fields = group.items.filter((it) => it.type !== "switch");

      const switchGrid = switches.length > 0
        ? h("div", { class: "settings-switch-grid" }, ...switches.map(switchTile))
        : null;

      const fieldsGrid = fields.length > 0
        ? h("div", { class: "settings-fields-grid" }, ...fields.map(regularField))
        : null;

      const reasonBox = h(
        "div",
        { class: "settings-audit-box" },
        h(
          "div",
          { class: "settings-audit-box-header" },
          icon("file"),
          h("label", { class: "settings-audit-box-title", for: "setting-reason" }, "Reason for Change"),
          h("span", { class: "settings-audit-box-tag" }, "Optional"),
        ),
        textareaField({
          id: "setting-reason",
          label: "",
          placeholder: "Add a short note about this change...",
          rows: 2,
          hint: "Help other admins understand why these settings were updated.",
        }),
      );

      const footer = h(
        "div",
        { class: "actions settings-actions" },
        h(
          "div",
          { class: "settings-audit-notice" },
          icon("info"),
          h("div", { class: "settings-footer-copy" },
            changeCount,
            h("span", {}, "Saved changes are recorded in the club audit trail."),
          ),
        ),
        h(
          "div",
          { class: "settings-action-buttons" },
          resetBtn,
          saveBtn,
        ),
      );

      const form = h(
        "form",
        {
          class: "member-panel settings-card",
          id: panelId,
          role: "tabpanel",
          "aria-labelledby": `tab-${group.id}`,
          onSubmit: (e) => {
            e.preventDefault();
            if (!saveBtn.disabled) save();
          },
        },
        header,
        switchGrid,
        fieldsGrid,
        reasonBox,
        status,
        footer,
      );
      return form;
    }

    function draw() {
      const group = GROUPS.find((g) => g.id === activeId) ?? GROUPS[0];
      body.replaceChildren(
        tabs({
          activeId,
          tabs: GROUPS.map((g) => ({ id: g.id, label: g.label })),
          onChange: (id) => {
            activeId = id;
            const next = GROUPS.find((g) => g.id === id);
            show(next);
          },
        }),
        drawGroup(group),
      );
    }

    async function start() {
      drawLoading();
      try {
        data = await load();
        draw();
      } catch (e) {
        drawError(e);
      }
    }
    start();
    return page;
  }

  return { settingsPage };
}
