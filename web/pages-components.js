// Complete, interactive UI Component Library and Design System Playground.
// Serves as the single source of truth for UI consistency across the CPC web app.
// All dynamic content is escaped by construction via h() / textContent.

import {
  accordion,
  alertBox,
  autocompleteField,
  avatar,
  badge,
  banner,
  breadcrumbs,
  button,
  buttonGroup,
  calendarDropdown,
  card,
  checkbox,
  confirmModal,
  dataTable,
  dateField,
  dateRangePicker,
  dateTimeField,
  divider,
  dropdownAction,
  dropdownMenu,
  emptyState,
  field,
  fileUploadField,
  h,
  icon,
  iconButton,
  kpiCard,
  multiSelect,
  openDrawer,
  openModal,
  pageHeader,
  pagination,
  popover,
  progressBar,
  radioGroup,
  searchableSelect,
  segmentedControl,
  selectField,
  sidebarNav,
  skeleton,
  sliderField,
  spinner,
  statCard,
  statusIndicator,
  stepper,
  switchToggle,
  tabs,
  textareaField,
  timeField,
  toast,
  toolbar,
  tooltip,
  validationSummary,
} from "./ui.js";

import { validate } from "./lib/validate.js";
import { localPasswordProblems } from "./lib/password-hints.js";
import { businessDate } from "./lib/dates.js";
import { formatMoney } from "./lib/money.js";
import { renderTurnstile } from "./lib/turnstile.js";

export function componentsPage() {
  const host = h("div", { class: "page components-playground" });
  let activeTheme = document.documentElement.getAttribute("data-theme") ||
    "dark";

  // Search state across components
  let searchQuery = "";
  let activeSection = "sec-foundations";
  const registeredCards = [];

  const filterCards = (query) => {
    searchQuery = query.toLowerCase().trim();
    let visibleCount = 0;
    for (const item of registeredCards) {
      const match = !searchQuery ||
        item.name.toLowerCase().includes(searchQuery) ||
        item.keywords.some((k) => k.toLowerCase().includes(searchQuery));
      item.el.hidden = !match;
      if (match) visibleCount++;
    }
    for (const section of host.querySelectorAll(".component-section")) {
      section.hidden = searchQuery
        ? !section.querySelector(".component-card:not([hidden])")
        : section.id !== activeSection;
    }
    for (const grid of host.querySelectorAll(".component-grid")) {
      let unpaired = null;
      for (const card of grid.children) {
        card.classList.remove("component-card-last");
        if (card.hidden) continue;
        if (card.classList.contains("component-card-wide")) {
          unpaired?.classList.add("component-card-last");
          unpaired = null;
        } else {
          unpaired = unpaired ? null : card;
        }
      }
      unpaired?.classList.add("component-card-last");
    }
    for (const pill of stickyNav.querySelectorAll(".playground-pill")) {
      const selected = !searchQuery && pill.dataset.section === activeSection;
      pill.classList.toggle("is-active", selected);
      if (selected) pill.setAttribute("aria-current", "true");
      else pill.removeAttribute("aria-current");
    }
    searchResultsCount.textContent = searchQuery
      ? `${visibleCount} components found`
      : "";
    noResults.hidden = !searchQuery || visibleCount > 0;
  };

  const registerComponentCard = (
    { name, keywords = [], guidance, variants = "", demoEl },
  ) => {
    const cardEl = h(
      "div",
      {
        class: `component-card${
          demoEl?.querySelector?.('[role="table"]')
            ? " component-card-wide"
            : ""
        }`,
        "data-component": name,
      },
      h(
        "div",
        { class: "component-card-head" },
        h(
          "div",
          {},
          h("h3", { class: "component-title" }, name),
          guidance
            ? h("p", { class: "component-guidance muted" }, guidance)
            : null,
        ),
        variants ? badge(variants, "neutral") : null,
      ),
      h("div", { class: "component-demo" }, demoEl),
    );
    registeredCards.push({ name, keywords, el: cardEl });
    return cardEl;
  };

  // Theme toggle button
  const toggleThemeBtn = button({
    label: activeTheme === "dark" ? "Light Mode" : "Dark Mode",
    variant: "outline",
    size: "sm",
    icon: activeTheme === "dark" ? "sun" : "moon",
    onClick: () => {
      activeTheme = activeTheme === "dark" ? "light" : "dark";
      document.documentElement.setAttribute("data-theme", activeTheme);
      const label = activeTheme === "dark" ? "Light Mode" : "Dark Mode";
      toggleThemeBtn.replaceChildren(
        icon(activeTheme === "dark" ? "sun" : "moon"),
        document.createTextNode(label),
      );
      toggleThemeBtn.title = label;
      toast(`Switched to ${activeTheme} theme`, { tone: "info" });
    },
  });

  // Top Page Header
  const header = pageHeader({
    icon: "grid",
    eyebrow: "Design System & Reference",
    title: "UI Component Library",
    description:
      "Browse a category or search all components. Preview the shared controls, layouts, and states used across the club app.",
    actions: [toggleThemeBtn],
  });

  // Section quick nav items
  const SECTIONS = [
    { id: "sec-foundations", label: "Foundations", icon: "layers" },
    { id: "sec-buttons", label: "Buttons & Actions", icon: "check" },
    { id: "sec-inputs", label: "Inputs & Validation", icon: "edit" },
    { id: "sec-feedback", label: "Feedback & Toasts", icon: "alert" },
    { id: "sec-modals", label: "Modals & Overlays", icon: "grid" },
    { id: "sec-navigation", label: "Navigation", icon: "home" },
    { id: "sec-datadisplay", label: "Data Display", icon: "inbox" },
    { id: "sec-completeform", label: "Complete Form", icon: "checkCircle" },
  ];

  const searchInput = h("input", {
    type: "search",
    class: "input",
    placeholder: "Search components…",
    "aria-label": "Search components",
    onInput: (e) => filterCards(e.target.value),
  });

  const searchResultsCount = h("span", {
    id: "search-results-count",
    class: "muted demo-result-count",
    role: "status",
  });

  const stickyNav = h(
    "nav",
    { class: "playground-nav", "aria-label": "Design system sections" },
    h(
      "div",
      { class: "playground-nav-pills" },
      ...SECTIONS.map((sec) =>
        h("button", {
          type: "button",
          class: "playground-pill",
          "data-section": sec.id,
          "aria-controls": sec.id,
          onClick: () => {
            activeSection = sec.id;
            searchInput.value = "";
            filterCards("");
          },
        }, sec.label)
      ),
    ),
    h(
      "div",
      { class: "playground-search-wrap" },
      searchInput,
      searchResultsCount,
    ),
  );

  const noResults = emptyState({
    title: "No components found",
    description: "Try another name, such as button, date, or table.",
    action: button({
      label: "Clear search",
      onClick: () => {
        searchInput.value = "";
        filterCards("");
        searchInput.focus();
      },
    }),
  });
  noResults.hidden = true;

  // ==========================================
  // SECTION 1: DESIGN FOUNDATIONS
  // ==========================================
  const buildFoundationsSection = () => {
    const COLOR_SWATCHES = [
      {
        token: "--primary",
        label: "Club Emerald",
        val: "#15803d",
        bg: "var(--primary)",
      },
      {
        token: "--primary-hover",
        label: "Emerald Highlight",
        val: "#16a34a",
        bg: "var(--primary-hover)",
      },
      {
        token: "--accent",
        label: "Pickleball Gold",
        val: "#f59e0b",
        bg: "var(--accent)",
      },
      {
        token: "--bg",
        label: "Deep Pine Dark",
        val: "#071510",
        bg: "var(--bg)",
      },
      {
        token: "--surface",
        label: "Card Forest Surface",
        val: "#0e2219",
        bg: "var(--surface)",
      },
      {
        token: "--surface-2",
        label: "Raised Pine Surface",
        val: "#142e22",
        bg: "var(--surface-2)",
      },
      {
        token: "--surface-3",
        label: "High Pine Surface",
        val: "#1b3b2c",
        bg: "var(--surface-3)",
      },
      {
        token: "--border",
        label: "Pine Subtle Border",
        val: "#234836",
        bg: "var(--border)",
      },
      {
        token: "--text",
        label: "Primary Text",
        val: "#f2f7f4",
        bg: "var(--text)",
      },
      {
        token: "--text-2",
        label: "Sage Muted Text",
        val: "#9db5a7",
        bg: "var(--text-2)",
      },
      {
        token: "--success",
        label: "Success Emerald",
        val: "#10b981",
        bg: "var(--success)",
      },
      {
        token: "--warning",
        label: "Pickleball Amber",
        val: "#f59e0b",
        bg: "var(--warning)",
      },
      {
        token: "--danger",
        label: "Destructive Red",
        val: "#f87171",
        bg: "var(--danger)",
      },
      {
        token: "--danger-bg",
        label: "Danger Dark Tint",
        val: "#451216",
        bg: "var(--danger-bg)",
      },
    ];

    const swatchGrid = h(
      "div",
      { class: "swatch-grid" },
      ...COLOR_SWATCHES.map((sw) => {
        const item = h(
          "div",
          {
            class: "swatch-card",
            title: `Click to copy ${sw.token}`,
            onClick: () => {
              if (navigator.clipboard) {
                navigator.clipboard.writeText(`var(${sw.token})`);
                toast(`Copied var(${sw.token}) to clipboard`, {
                  tone: "success",
                });
              }
            },
          },
          h("div", { class: `swatch-color swatch-${sw.token.slice(2)}` }),
          h("div", { class: "swatch-token" }, sw.token),
          h("div", { class: "swatch-val" }, sw.val),
        );
        return item;
      }),
    );

    const typographyTable = h(
      "table",
      { class: "token-table" },
      h(
        "thead",
        {},
        h(
          "tr",
          {},
          h("th", {}, "Role"),
          h("th", {}, "Size / Weight"),
          h("th", {}, "Example Specimen"),
        ),
      ),
      h(
        "tbody",
        {},
        h(
          "tr",
          {},
          h("td", {}, h("strong", {}, "Heading 1")),
          h("td", { class: "muted" }, "22px / 700 Bold"),
          h(
            "td",
            {},
            h("h1", { class: "demo-reset-margin" }, "Capitol Pickleball Club"),
          ),
        ),
        h(
          "tr",
          {},
          h("td", {}, h("strong", {}, "Heading 2")),
          h("td", { class: "muted" }, "18px / 700 Bold"),
          h(
            "td",
            {},
            h(
              "h2",
              { class: "demo-reset-margin" },
              "Court Reservations & Schedules",
            ),
          ),
        ),
        h(
          "tr",
          {},
          h("td", {}, h("strong", {}, "Heading 3 / Card Title")),
          h("td", { class: "muted" }, "16px / 700 Bold"),
          h(
            "td",
            {},
            h("h3", { class: "demo-reset-margin" }, "Match Division Standings"),
          ),
        ),
        h(
          "tr",
          {},
          h("td", {}, h("strong", {}, "Body Text")),
          h("td", { class: "muted" }, "14px / 400 Regular"),
          h(
            "td",
            {},
            "Member ratings update after official division finalization.",
          ),
        ),
        h(
          "tr",
          {},
          h("td", {}, h("strong", {}, "Important / Buttons")),
          h("td", { class: "muted" }, "13–14px / 600 Semi-Bold"),
          h(
            "td",
            {},
            h("span", { class: "demo-semibold" }, "Save Booking"),
          ),
        ),
        h(
          "tr",
          {},
          h("td", {}, h("strong", {}, "Eyebrow / Table Head")),
          h("td", { class: "muted" }, "11–12px / 700 Uppercase"),
          h(
            "td",
            {},
            h("span", { class: "eyebrow" }, "FOUNDATION SPECIFICATION"),
          ),
        ),
        h(
          "tr",
          {},
          h("td", {}, h("strong", {}, "Secondary / Captions")),
          h("td", { class: "muted" }, "12px / 400 Muted"),
          h(
            "td",
            { class: "muted" },
            "Last active today at 04:30 PM (Asia/Manila)",
          ),
        ),
        h(
          "tr",
          {},
          h("td", {}, h("strong", {}, "Hyperlink")),
          h("td", { class: "muted" }, "14px / Color: var(--accent)"),
          h(
            "td",
            {},
            h("a", { href: "#/" }, "View club tournament guidelines →"),
          ),
        ),
      ),
    );

    const SPACING_TOKENS = [
      { name: "--s1", px: 4 },
      { name: "--s2", px: 8 },
      { name: "--s3", px: 12 },
      { name: "--s4", px: 16 },
      { name: "--s5", px: 24 },
      { name: "--s6", px: 32 },
    ];

    const spacingBars = h(
      "div",
      { class: "spacing-scale-bars" },
      ...SPACING_TOKENS.map((sp) =>
        h(
          "div",
          { class: "spacing-bar-item" },
          h("span", { class: "spacing-bar-label" }, `${sp.name} (${sp.px}px)`),
          h("div", {
            class: `spacing-bar-visual spacing-${sp.px}`,
          }),
        )
      ),
    );

    const SYSTEM_ICONS = [
      "home",
      "grid",
      "search",
      "x",
      "plus",
      "edit",
      "trash",
      "check",
      "alert",
      "inbox",
      "refresh",
      "chevl",
      "chevr",
      "chevronDown",
      "chevronUp",
      "info",
      "eye",
      "eyeOff",
      "calendar",
      "clock",
      "upload",
      "download",
      "copy",
      "user",
      "mail",
      "phone",
      "link",
      "checkCircle",
      "alertCircle",
      "alertTriangle",
      "sun",
      "moon",
      "filter",
      "layers",
      "file",
    ];

    const iconGrid = h(
      "div",
      { class: "icon-grid" },
      ...SYSTEM_ICONS.map((name) =>
        h(
          "button",
          {
            class: "icon-card",
            type: "button",
            "aria-label": `Copy ${name} icon`,
            title: `icon("${name}") - click to copy`,
            onClick: () => {
              if (navigator.clipboard) {
                navigator.clipboard.writeText(`icon("${name}")`).then(
                  () => toast(`Copied icon("${name}")`, { tone: "success" }),
                  () =>
                    toast("Could not copy the icon. Try again.", {
                      tone: "error",
                    }),
                );
              }
            },
          },
          icon(name),
          h("span", {}, name),
        )
      ),
    );

    function securityCheckDemo() {
      const status = h(
        "p",
        { class: "muted", role: "status" },
        "Loading the security check…",
      );
      const box = h("div", {});
      const wrapper = h(
        "div",
        { class: "demo-stack-sm" },
        box,
        status,
      );
      setTimeout(() => {
        renderTurnstile(box, {
          action: "demo",
          onToken: (token) => {
            status.textContent =
              `Check passed (token received, ${token.length} characters).`;
          },
          onExpire: () => {
            status.textContent = "The check expired. It will refresh.";
          },
          onError: (message) => {
            status.textContent = message;
          },
        }).catch((e) => {
          status.textContent = e.message;
        });
      }, 0);
      return wrapper;
    }

    const section = h(
      "section",
      { class: "component-section", id: "sec-foundations" },
      h(
        "div",
        { class: "component-section-head" },
        h("h2", {}, "1. Design Foundations"),
        badge("Shared Tokens", "info"),
      ),
      h(
        "div",
        { class: "component-grid" },
        registerComponentCard({
          name: "Color Palette & Tokens",
          keywords: ["color", "palette", "tokens", "hex", "swatch", "theme"],
          guidance:
            "Click any color swatch to copy the CSS variable. Meets WCAG 2.2 AA ≥ 4.5:1 contrast.",
          variants: "14 Tokens",
          demoEl: swatchGrid,
        }),
        registerComponentCard({
          name: "Typography Hierarchy",
          keywords: [
            "typography",
            "font",
            "h1",
            "h2",
            "h3",
            "body",
            "heading",
            "caption",
          ],
          guidance:
            "Inter Variable font family with strict size and weight standards per UI_DESIGN.md.",
          variants: "7 Styles",
          demoEl: typographyTable,
        }),
        registerComponentCard({
          name: "Spacing, Radii & Dimensions",
          keywords: [
            "spacing",
            "padding",
            "margin",
            "radius",
            "control",
            "height",
            "shadow",
          ],
          guidance:
            "Standard spacing scale (4, 8, 12, 16, 24, 32px), control heights (32, 42, 48px), and radii (10px, 14px, 16px).",
          variants: "Tokens --s1 to --s6",
          demoEl: h(
            "div",
            { class: "demo-stack" },
            spacingBars,
            divider({ label: "Radii & Control Heights" }),
            h(
              "div",
              { class: "demo-row-sm" },
              badge("--r-control: 10px", "neutral"),
              badge("--r-card: 14px", "neutral"),
              badge("--r-modal: 16px", "neutral"),
              badge("--control-h: 42px", "info"),
              badge("--control-h-sm: 32px", "info"),
              badge("--control-h-lg: 48px", "info"),
            ),
          ),
        }),
        registerComponentCard({
          name: "System Icon Library",
          keywords: ["icons", "svg", "glyph", "symbol", "iconography"],
          guidance:
            "Unified 24x24 stroke icons. Scalable, accessible, and self-contained vector paths.",
          variants: "35 Icons",
          demoEl: iconGrid,
        }),
        registerComponentCard({
          name: "Security Check (Turnstile)",
          keywords: ["turnstile", "captcha", "security", "bot", "protection"],
          guidance:
            "Cloudflare Turnstile integration used for automated bot protection on sign-in and public forms.",
          variants: "Production Managed Widget",
          demoEl: securityCheckDemo(),
        }),
      ),
    );
    return section;
  };

  // ==========================================
  // SECTION 2: BUTTONS AND ACTIONS
  // ==========================================
  const buildButtonsSection = () => {
    // Variants demo
    const variantsRow = h(
      "div",
      { class: "demo-stack" },
      h(
        "div",
        {
          class: "demo-row-sm-center",
        },
        button({
          label: "Primary",
          variant: "primary",
          onClick: () => toast("Primary button clicked", { tone: "info" }),
        }),
        button({
          label: "Secondary",
          variant: "secondary",
          onClick: () => toast("Secondary button clicked", { tone: "info" }),
        }),
        button({
          label: "Outline",
          variant: "outline",
          onClick: () => toast("Outline button clicked", { tone: "info" }),
        }),
      ),
      h(
        "div",
        {
          class: "demo-row-sm-center",
        },
        button({
          label: "Ghost",
          variant: "ghost",
          onClick: () => toast("Ghost button clicked", { tone: "info" }),
        }),
        button({
          label: "Link",
          variant: "link",
          onClick: () => toast("Link button clicked", { tone: "info" }),
        }),
        button({
          label: "Destructive",
          variant: "danger",
          onClick: () => toast("Destructive button clicked", { tone: "error" }),
        }),
      ),
    );

    // Sizes demo
    const sizesRow = h(
      "div",
      { class: "demo-stack" },
      h(
        "div",
        {
          class: "demo-row-between",
        },
        h(
          "span",
          { class: "muted demo-caption" },
          "Small (32px):",
        ),
        button({ label: "Small Action", variant: "primary", size: "sm" }),
      ),
      h(
        "div",
        {
          class: "demo-row-between",
        },
        h(
          "span",
          { class: "muted demo-caption" },
          "Default (42px):",
        ),
        button({ label: "Default Action", variant: "primary" }),
      ),
      h(
        "div",
        {
          class: "demo-row-between",
        },
        h(
          "span",
          { class: "muted demo-caption" },
          "Large (48px):",
        ),
        button({ label: "Large Action", variant: "primary", size: "lg" }),
      ),
    );

    // Icons demo
    const iconsRow = h(
      "div",
      { class: "demo-stack" },
      h(
        "div",
        {
          class: "demo-row",
        },
        button({ label: "Text Only", variant: "secondary" }),
        button({ label: "Icon Left", variant: "primary", icon: "plus" }),
        button({
          label: "Icon Right",
          variant: "secondary",
          icon: "chevronRight",
          iconPosition: "right",
        }),
      ),
      h(
        "div",
        {
          class: "demo-row-divider",
        },
        h(
          "span",
          { class: "muted demo-caption" },
          "Row Actions (Table Context):",
        ),
        iconButton({
          label: "Edit Record",
          icon: "edit",
          onClick: () => toast("Edit record action", { tone: "info" }),
        }),
        iconButton({
          label: "Delete Record",
          icon: "trash",
          variant: "danger",
          onClick: () => toast("Delete action", { tone: "error" }),
        }),
      ),
    );

    // Interactive States demo (Hover, Focus, Pressed, Disabled, Loading with spinner)
    const testLoadingBtn = button({
      label: "Click to Load",
      variant: "primary",
      onClick: async () => {
        testLoadingBtn.dataset.pending = "true";
        testLoadingBtn.disabled = true;
        await new Promise((r) => setTimeout(r, 1500));
        delete testLoadingBtn.dataset.pending;
        testLoadingBtn.disabled = false;
        toast("Async action finished!", { tone: "success" });
      },
    });

    const statesRow = h(
      "div",
      { class: "demo-stack" },
      h(
        "div",
        {
          class: "demo-row",
        },
        button({ label: "Normal State", variant: "secondary" }),
        button({
          label: "Disabled State",
          variant: "secondary",
          disabled: true,
        }),
      ),
      h(
        "div",
        {
          class: "demo-row",
        },
        button({
          label: "Permanent Loading",
          variant: "primary",
          loading: true,
        }),
        testLoadingBtn,
      ),
    );

    // Button group & Dropdown action demo
    const grp = buttonGroup([
      button({ label: "Day", variant: "secondary", size: "sm" }),
      button({ label: "Week", variant: "secondary", size: "sm" }),
      button({ label: "Month", variant: "primary", size: "sm" }),
    ]);

    const dropdownDemo = dropdownAction({
      label: "More Actions",
      icon: "sliders",
      items: [
        {
          label: "Export to CSV",
          icon: "download",
          onClick: () => toast("Exporting CSV…", { tone: "info" }),
        },
        {
          label: "Print Bracket",
          icon: "file",
          onClick: () => toast("Sending to printer…", { tone: "info" }),
        },
        { divider: true },
        {
          label: "Cancel Event",
          icon: "trash",
          danger: true,
          onClick: () => toast("Event cancelled", { tone: "error" }),
        },
      ],
    });

    const groupAndDropdownRow = h(
      "div",
      { class: "demo-stack-lg" },
      h(
        "div",
        { class: "demo-stack-sm" },
        h(
          "span",
          { class: "muted demo-caption" },
          "Segmented Button Group:",
        ),
        grp,
      ),
      h(
        "div",
        {
          class: "demo-stack-divider",
        },
        h(
          "span",
          { class: "muted demo-caption" },
          "Dropdown Action Menu:",
        ),
        dropdownDemo,
      ),
    );

    const section = h(
      "section",
      { class: "component-section", id: "sec-buttons" },
      h(
        "div",
        { class: "component-section-head" },
        h("h2", {}, "2. Buttons & Actions"),
        badge("Interactive", "success"),
      ),
      h(
        "div",
        { class: "component-grid" },
        registerComponentCard({
          name: "Button Variants",
          keywords: [
            "button",
            "primary",
            "secondary",
            "outline",
            "ghost",
            "link",
            "danger",
            "destructive",
          ],
          guidance:
            "Semantic variants with consistent tokens, active states, and focus rings.",
          variants: "6 Variants",
          demoEl: variantsRow,
        }),
        registerComponentCard({
          name: "Button Sizes",
          keywords: ["size", "sm", "default", "lg", "height", "42px"],
          guidance:
            "Small (32px), Default (42px touch-friendly), and Large (48px prominent).",
          variants: "3 Sizes",
          demoEl: sizesRow,
        }),
        registerComponentCard({
          name: "Icons & Accessible Row Actions",
          keywords: [
            "icon",
            "icon-only",
            "tooltip",
            "aria-label",
            "iconButton",
          ],
          guidance:
            "Row actions must be icon-only with accessible labels and title tooltips.",
          variants: "Text, Combined, Icon-only",
          demoEl: iconsRow,
        }),
        registerComponentCard({
          name: "Loading & Disabled States",
          keywords: ["loading", "spinner", "pending", "disabled", "state"],
          guidance:
            "Buttons show a subtle circular spinner without shifting layout during submission.",
          variants: "Default, Disabled, Pending",
          demoEl: statesRow,
        }),
        registerComponentCard({
          name: "Button Groups & Dropdown Actions",
          keywords: [
            "group",
            "dropdown",
            "buttonGroup",
            "dropdownAction",
            "menu",
          ],
          guidance:
            "Seamless button groups and accessible dropdown action menus.",
          variants: "Group, Dropdown Menu",
          demoEl: groupAndDropdownRow,
        }),
      ),
    );
    return section;
  };

  // ==========================================
  // SECTION 3: FORM INPUTS AND VALIDATION
  // ==========================================
  const buildInputsSection = () => {
    // Live Validation State
    const valState = {
      email: "player@cpc.ph",
      mobile: "09171234567",
      amount: "1250.00",
      password: "",
      confirm: "",
    };

    // 1. Email validation
    const validateEmail = (val) => {
      val = (val ?? "").trim();
      valState.email = val;
      if (!val) {
        emailFieldEl.setError("Email address is required.");
        return false;
      }
      const isValid = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(val);
      if (!isValid) {
        emailFieldEl.setError(
          "Please enter a valid email format (e.g., player@cpc.ph).",
        );
        return false;
      }
      emailFieldEl.setSuccess("✓ Valid email address format.");
      return true;
    };

    const emailFieldEl = field({
      id: "val-email",
      label: "Email Address",
      type: "email",
      value: valState.email,
      placeholder: "player@cpc.ph",
      required: true,
      iconLeading: "mail",
      hint: "Must be a valid email format.",
      onInput: (e) => validateEmail(e.target.value),
    });

    // 2. Philippine Mobile Number (Contact No)
    const validateMobile = (val) => {
      val = (val ?? "").trim();
      valState.mobile = val;
      if (!val) {
        mobileFieldEl.setError("Contact number is required.");
        return false;
      }
      if (!val.startsWith("09")) {
        mobileFieldEl.setError("Philippine contact number must start with 09.");
        return false;
      }
      if (!/^\d+$/.test(val)) {
        mobileFieldEl.setError(
          "Contact number must contain only numeric digits.",
        );
        return false;
      }
      if (val.length !== 11) {
        mobileFieldEl.setError(
          `Must contain exactly 11 digits (currently ${val.length}/11).`,
        );
        return false;
      }
      mobileFieldEl.setSuccess("✓ Valid 11-digit Philippine mobile number.");
      return true;
    };

    const mobileFieldEl = field({
      id: "val-mobile",
      label: "Contact Number (Philippine Mobile)",
      type: "tel",
      value: valState.mobile,
      placeholder: "09171234567",
      required: true,
      iconLeading: "phone",
      hint: "Philippine local mobile: exactly 11 digits starting with 09.",
      onInput: (e) => validateMobile(e.target.value),
    });

    // 3. Amount / Registration Fee
    const validateAmount = (val) => {
      val = (val ?? "").trim().replace(/^₱\s*/, "");
      valState.amount = val;
      if (!val) {
        currencyField.setError("Registration amount is required.");
        return false;
      }
      const num = Number(val);
      if (isNaN(num)) {
        currencyField.setError("Please enter a valid numeric currency amount.");
        return false;
      }
      if (!/^\d+(\.\d{1,2})?$/.test(val)) {
        currencyField.setError(
          "Amount can have at most 2 decimal places (e.g. 1250.00).",
        );
        return false;
      }
      if (num < 100) {
        currencyField.setError("Minimum registration fee is ₱100.00.");
        return false;
      }
      if (num > 50000) {
        currencyField.setError("Maximum registration fee limit is ₱50,000.00.");
        return false;
      }
      currencyField.setSuccess(
        `✓ Valid fee amount: ₱${
          num.toLocaleString("en-US", {
            minimumFractionDigits: 2,
            maximumFractionDigits: 2,
          })
        }`,
      );
      return true;
    };

    const currencyField = field({
      id: "val-fee",
      label: "Registration Amount (PHP)",
      type: "text",
      value: valState.amount,
      prefix: "₱",
      required: true,
      hint: "Valid range: ₱100.00 to ₱50,000.00.",
      onInput: (e) => validateAmount(e.target.value),
    });

    const validationActionRow = h(
      "div",
      {
        class: "demo-row-divider-sm",
      },
      button({
        label: "Check All Inputs",
        variant: "primary",
        size: "sm",
        icon: "checkCircle",
        onClick: () => {
          const emailOk = validateEmail(emailFieldEl.inputEl.value);
          const mobileOk = validateMobile(mobileFieldEl.inputEl.value);
          const amountOk = validateAmount(currencyField.inputEl.value);
          if (emailOk && mobileOk && amountOk) {
            toast("All 3 input fields passed validation successfully!", {
              tone: "success",
              title: "Validation Passed",
            });
          } else {
            toast("Please fix the highlighted field errors.", {
              tone: "error",
              title: "Validation Failed",
            });
          }
        },
      }),
      button({
        label: "Simulate Errors",
        variant: "outline",
        size: "sm",
        icon: "alertTriangle",
        onClick: () => {
          emailFieldEl.inputEl.value = "invalid-email-format";
          mobileFieldEl.inputEl.value = "0812345";
          currencyField.inputEl.value = "45.00";
          validateEmail("invalid-email-format");
          validateMobile("0812345");
          validateAmount("45.00");
          toast("Simulated invalid inputs to showcase error messages.", {
            tone: "warning",
            title: "Simulated Input Errors",
          });
        },
      }),
      button({
        label: "Reset to Valid",
        variant: "ghost",
        size: "sm",
        icon: "refresh",
        onClick: () => {
          emailFieldEl.inputEl.value = "player@cpc.ph";
          mobileFieldEl.inputEl.value = "09171234567";
          currencyField.inputEl.value = "1250.00";
          validateEmail("player@cpc.ph");
          validateMobile("09171234567");
          validateAmount("1250.00");
          toast("Fields restored to valid sample data.", {
            tone: "info",
            title: "Defaults Restored",
          });
        },
      }),
    );

    // Run initial validation check
    setTimeout(() => {
      validateEmail(valState.email);
      validateMobile(valState.mobile);
      validateAmount(valState.amount);
    }, 50);

    const pwFieldEl = field({
      id: "val-pw",
      label: "Password",
      type: "password",
      value: valState.password,
      placeholder: "Minimum 12 characters",
      required: true,
      showToggle: true,
      hint: "Requires at least 12 characters.",
      onChange: (e) => {
        valState.password = e.target.value;
        const problems = localPasswordProblems(
          valState.password,
          valState.confirm,
        );
        pwFieldEl.setError(problems[0] || "");
      },
    });

    const confirmPwFieldEl = field({
      id: "val-confirm-pw",
      label: "Confirm Password",
      type: "password",
      value: valState.confirm,
      placeholder: "Re-enter password",
      required: true,
      showToggle: true,
      hint: "Must match the password entered above.",
      onChange: (e) => {
        valState.confirm = e.target.value;
        const mismatch = valState.password !== valState.confirm;
        confirmPwFieldEl.setError(mismatch ? "Passwords do not match." : "");
      },
    });

    const textarea = textareaField({
      id: "val-notes",
      label: "Special Requirements & Dietary Notes",
      placeholder:
        "Enter any special requests, partner preferences, or medical notes…",
      hint: "Optional information for tournament organizers.",
    });

    const select = selectField({
      id: "val-category",
      label: "Skill Category Level",
      options: [
        { value: "novice_low", label: "Novice Low (1.0 - 2.0)" },
        { value: "novice_high", label: "Novice High (2.5)" },
        { value: "intermediate_low", label: "Intermediate Low (3.0)" },
        { value: "intermediate_high", label: "Intermediate High (3.5)" },
        { value: "advanced", label: "Advanced Open (4.0+)" },
      ],
      value: "intermediate_low",
      hint: "Select your verified CPC skill bracket.",
    });

    const searchable = searchableSelect({
      id: "val-club-branch",
      label: "Home Court Facility",
      options: [
        "Capitol Court 1 - Indoor Wood",
        "Capitol Court 2 - Indoor Wood",
        "Capitol Court 3 - Outdoor Acrylic",
        "Capitol Court 4 - Outdoor Acrylic",
        "North Annex Court A",
        "North Annex Court B",
      ],
      value: "Capitol Court 1 - Indoor Wood",
      hint: "Search and select preferred court facility.",
      onSelect: (val) => toast(`Selected: ${val}`, { tone: "info" }),
    });

    const multi = multiSelect({
      id: "val-event-divisions",
      label: "Registered Divisions",
      options: [
        "Men's Singles 3.0",
        "Women's Singles 3.0",
        "Mixed Doubles 3.5",
        "Men's Doubles Open",
        "Senior 50+ Doubles",
      ],
      values: ["Mixed Doubles 3.5", "Men's Doubles Open"],
      hint: "Choose one or more tournament divisions.",
      onChange: (vals) =>
        toast(`Divisions: ${vals.join(", ")}`, { tone: "info" }),
    });

    const autocomplete = autocompleteField({
      id: "val-partner-name",
      label: "Doubles Partner Search",
      suggestions: [
        "Juan Dela Cruz (CPC-2026-00001)",
        "Maria Santos (CPC-2026-00002)",
        "Jose Rizal (CPC-2026-00003)",
        "Andres Bonifacio (CPC-2026-00004)",
        "Gabriela Silang (CPC-2026-00005)",
      ],
      placeholder: "Type partner's name or Member ID…",
      hint: "Instant lookup of verified club members.",
      onSelect: (item) =>
        toast(`Partner selected: ${item}`, { tone: "success" }),
    });

    const check = checkbox({
      id: "val-terms",
      label: "I agree to club tournament rules, waiver and liability terms",
      checked: true,
      hint: "Mandatory participation consent.",
    });

    const radio = radioGroup({
      name: "val-bracket-format",
      label: "Tournament Bracket Format",
      options: [
        {
          value: "round_robin",
          label: "Round Robin (Everyone plays everyone)",
        },
        { value: "pool_play", label: "Regular Pool Play into Elimination" },
        {
          value: "split_single",
          label: "Split Single Elimination (High / Low)",
        },
      ],
      value: "pool_play",
      hint: "Bracket pipeline format.",
      onChange: (val) => toast(`Format set to: ${val}`, { tone: "info" }),
    });

    const sw = switchToggle({
      id: "val-sms-notifications",
      label: "Match Schedule SMS Alerts",
      checked: true,
      hint: "Receive instant court-call SMS 15 minutes before your match.",
      onChange: (checked) =>
        toast(`SMS alerts ${checked ? "enabled" : "disabled"}`, {
          tone: "info",
        }),
    });

    const seg = segmentedControl({
      name: "court-surface",
      label: "Surface Preference",
      options: ["Indoor Wood", "Outdoor Acrylic", "Covered Cushion"],
      value: "Indoor Wood",
      onChange: (val) => toast(`Preference: ${val}`, { tone: "info" }),
    });

    const slider = sliderField({
      id: "val-warmup-minutes",
      label: "Warm-up Duration",
      min: 5,
      max: 30,
      step: 5,
      value: 15,
      unit: " mins",
      hint: "Designated pre-game warm-up time.",
      onChange: (val) => toast(`Warm-up: ${val} mins`, { tone: "info" }),
    });

    const smoothCalendar = calendarDropdown({
      id: "val-smooth-calendar",
      label: "Smooth Dropdown Calendar (Single & Range)",
      range: true,
      startValue: businessDate(),
      endValue: businessDate(),
      hint:
        "Custom animated popover calendar with month pager, range connector highlight, and quick presets.",
      onChange: ({ start, end }) => {
        toast(`Selected Dates: ${start} → ${end}`, {
          tone: "info",
          title: "Calendar Selection",
        });
      },
    });

    const date = dateField({
      id: "val-match-date",
      label: "Tournament Date",
      value: businessDate(),
      hint: "Business date in Asia/Manila.",
    });

    const dateRange = dateRangePicker({
      id: "val-range",
      label: "Booking Window Range",
      startValue: businessDate(),
      endValue: businessDate(),
      hint: "Inclusive dates with quick preset chips.",
      onChange: ({ start, end }) =>
        toast(`Range: ${start} to ${end}`, { tone: "info" }),
    });

    const time = timeField({
      id: "val-match-time",
      label: "Court Start Time",
      value: "08:00",
      hint: "24-hour court block schedule.",
    });

    const dateTime = dateTimeField({
      id: "val-datetime",
      label: "Check-in Timestamp",
      value: `${businessDate()}T08:00`,
      hint: "Scheduled player arrival instant.",
    });

    const fileUpload = fileUploadField({
      id: "val-payment-proof",
      label: "Payment Proof / Receipt Upload",
      accept: "image/png,image/jpeg,.pdf",
      maxSizeMb: 5,
      hint: "Upload bank transfer or GCash screenshot for admin approval.",
      onFiles: (files) => {
        if (files.length) {
          toast(`Attached: ${files[0].name}`, { tone: "success" });
        }
      },
    });

    // States demonstration card
    const statesCard = h(
      "div",
      { class: "demo-stack" },
      field({
        id: "st-default",
        label: "Default State",
        placeholder: "Standard input",
      }),
      field({
        id: "st-filled",
        label: "Filled State",
        value: "Juan Dela Cruz",
      }),
      field({
        id: "st-invalid",
        label: "Invalid State with Error",
        value: "invalid-email",
        error: "Enter a valid email address.",
      }),
      field({
        id: "st-disabled",
        label: "Disabled State",
        value: "Locked value",
        disabled: true,
      }),
      field({
        id: "st-readonly",
        label: "Read-only State",
        value: "CPC-2026-00001 (Auto-generated)",
        readonly: true,
      }),
    );

    const section = h(
      "section",
      { class: "component-section", id: "sec-inputs" },
      h(
        "div",
        { class: "component-section-head" },
        h("h2", {}, "3. Form Inputs & Validation"),
        badge("Working Validation", "success"),
      ),
      h(
        "div",
        { class: "component-grid" },
        registerComponentCard({
          name: "Standard Text & Affix Inputs",
          keywords: [
            "text",
            "input",
            "prefix",
            "suffix",
            "currency",
            "fee",
            "email",
            "contact",
            "validation",
          ],
          guidance:
            "Live validation for Email, Philippine Contact Number (09XXXXXXXXX), and Currency amount.",
          variants: "Email, Phone, Currency",
          demoEl: h(
            "div",
            { class: "demo-stack" },
            emailFieldEl,
            mobileFieldEl,
            currencyField,
            validationActionRow,
          ),
        }),
        registerComponentCard({
          name: "Password with Visibility Toggle",
          keywords: ["password", "toggle", "eye", "security", "hints"],
          guidance:
            "Interactive password visibility toggle with live client-side validation hints.",
          variants: "Password, Confirm",
          demoEl: h(
            "div",
            { class: "demo-stack" },
            pwFieldEl,
            confirmPwFieldEl,
          ),
        }),
        registerComponentCard({
          name: "Dropdown, Searchable Select & Multi-Select",
          keywords: [
            "select",
            "dropdown",
            "searchable",
            "multi-select",
            "tags",
          ],
          guidance:
            "Standard native select, searchable filter select, and tag-based multi-select.",
          variants: "Select, Searchable, Multi",
          demoEl: h(
            "div",
            { class: "demo-stack" },
            select,
            searchable,
            multi,
          ),
        }),
        registerComponentCard({
          name: "Autocomplete Lookup",
          keywords: ["autocomplete", "search", "suggestions", "partner"],
          guidance:
            "Live autocomplete popup suggestions while typing member names or IDs.",
          variants: "Autocomplete",
          demoEl: autocomplete,
        }),
        registerComponentCard({
          name: "Checkboxes, Radios, Switch & Segmented",
          keywords: ["checkbox", "radio", "switch", "segmented", "toggle"],
          guidance:
            "Styled accessible selection controls for options and binary states.",
          variants: "Check, Radio, Switch, Segmented",
          demoEl: h(
            "div",
            { class: "demo-stack" },
            check,
            radio,
            sw,
            seg,
          ),
        }),
        registerComponentCard({
          name: "Slider & Numeric Range",
          keywords: ["slider", "range", "numeric", "number"],
          guidance: "Slider control with live numeric badge indicator.",
          variants: "Slider",
          demoEl: slider,
        }),
        registerComponentCard({
          name: "Smooth Dropdown Calendar",
          keywords: [
            "calendar",
            "dropdown",
            "picker",
            "smooth",
            "popover",
            "range",
            "date",
          ],
          guidance:
            "Custom animated popover calendar with month pager, range connector highlight, and quick presets.",
          variants: "Single Date, Date Range",
          demoEl: smoothCalendar,
        }),
        registerComponentCard({
          name: "Date, Time & Date Range Pickers",
          keywords: ["date", "time", "dateRange", "presets", "calendar"],
          guidance:
            "Business dates in Asia/Manila with quick preset chips (This Month, Last 30 Days, All Time).",
          variants: "Date, Time, DateTime, Range",
          demoEl: h(
            "div",
            { class: "demo-stack" },
            date,
            dateRange,
            time,
            dateTime,
          ),
        }),
        registerComponentCard({
          name: "File Upload & Drag-and-Drop",
          keywords: ["file", "upload", "dropzone", "preview", "receipt"],
          guidance:
            "Dropzone with thumbnail preview, size limit check, progress simulation, and delete action.",
          variants: "Dropzone, Preview",
          demoEl: fileUpload,
        }),
        registerComponentCard({
          name: "Multiline Textarea",
          keywords: ["textarea", "multiline", "notes"],
          guidance: "Comfortable vertical resizing, hints, and error support.",
          variants: "Textarea",
          demoEl: textarea,
        }),
        registerComponentCard({
          name: "Field States Comparison",
          keywords: [
            "states",
            "focused",
            "filled",
            "invalid",
            "disabled",
            "readonly",
          ],
          guidance:
            "Comparison of default, filled, invalid with error message, disabled, and read-only states.",
          variants: "All States",
          demoEl: statesCard,
        }),
      ),
    );
    return section;
  };

  // ==========================================
  // SECTION 4: NOTIFICATIONS AND FEEDBACK
  // ==========================================
  const buildFeedbackSection = () => {
    // Toast triggers
    const toastTriggers = h(
      "div",
      { class: "demo-row-sm" },
      button({
        label: "Success Toast",
        variant: "secondary",
        icon: "checkCircle",
        onClick: () =>
          toast("Court booking confirmed for 6:00 PM!", {
            tone: "success",
            title: "Reservation Approved",
          }),
      }),
      button({
        label: "Error Toast",
        variant: "danger",
        icon: "alertCircle",
        onClick: () =>
          toast("Payment receipt verification failed.", {
            tone: "error",
            title: "Verification Error",
          }),
      }),
      button({
        label: "Warning Toast",
        variant: "secondary",
        icon: "alertTriangle",
        onClick: () =>
          toast("Court lighting closes in 15 minutes.", {
            tone: "warning",
            title: "Court Notice",
          }),
      }),
      button({
        label: "Info Toast",
        variant: "outline",
        icon: "info",
        onClick: () =>
          toast("Tournament bracket draw starts at 2:00 PM.", {
            tone: "info",
            title: "Event Notice",
          }),
      }),
    );

    // Alerts demo
    const alertsDemo = h(
      "div",
      { class: "demo-stack" },
      alertBox({
        tone: "success",
        title: "Membership Approved",
        message:
          "Your member profile is now active. You may now book courts and enter tournaments.",
      }),
      alertBox({
        tone: "warning",
        title: "Weather Advisory",
        message: "Outdoor acrylic courts are currently suspended due to rain.",
        dismissible: true,
      }),
      alertBox({
        tone: "error",
        title: "Account Lockout Warning",
        message:
          "Five consecutive failed attempts will temporarily lock sign-in.",
      }),
      alertBox({
        tone: "info",
        title: "System Maintenance",
        message:
          "Routine maintenance scheduled on Monday at 02:00 AM (Asia/Manila).",
      }),
    );

    // Banner demo
    const bannerDemo = h(
      "div",
      { class: "demo-stack-sm" },
      banner({
        tone: "info",
        message: "Early bird registration for the CPC Summer Open is now open!",
        actionLabel: "Register Now",
        onAction: () => toast("Opening registration…", { tone: "info" }),
      }),
      banner({
        tone: "warning",
        message: "Court 3 net maintenance in progress until 12:00 PM.",
        dismissible: true,
      }),
    );

    // Validation summary demo
    const valSummaryDemo = validationSummary({
      title: "Please review the following 3 issues before submitting:",
      errors: [
        "Philippine mobile number must start with 09 and contain 11 digits.",
        "Password must be at least 12 characters in length.",
        "You must agree to the club rules and tournament waiver.",
      ],
    });

    // Progress bar demo (deterministic + indeterminate)
    let curProgress = 65;
    const progressEl = progressBar({
      value: curProgress,
      label: "Tournament Stage Progress (Quarterfinals)",
      tone: "primary",
    });
    const progressBtns = h(
      "div",
      { class: "demo-row-top" },
      button({
        label: "−10%",
        size: "sm",
        variant: "secondary",
        onClick: () => {
          curProgress = Math.max(0, curProgress - 10);
          progressEl.replaceWith(
            progressBar({
              value: curProgress,
              label: "Tournament Stage Progress",
              tone: "primary",
            }),
          );
        },
      }),
      button({
        label: "+10%",
        size: "sm",
        variant: "secondary",
        onClick: () => {
          curProgress = Math.min(100, curProgress + 10);
          progressEl.replaceWith(
            progressBar({
              value: curProgress,
              label: "Tournament Stage Progress",
              tone: "primary",
            }),
          );
        },
      }),
    );

    const indeterminateBar = progressBar({
      indeterminate: true,
      label: "Processing tournament seeds…",
      tone: "accent",
    });

    // Spinners demo
    const spinnersDemo = h(
      "div",
      {
        class: "demo-row-lg",
      },
      spinner({ size: "sm", label: "Small (16px)" }),
      spinner({ size: "md", label: "Medium (24px)" }),
      spinner({ size: "lg", label: "Large (36px)" }),
      spinner({ size: "md", tone: "accent", label: "Accent Tone" }),
    );

    // Skeletons demo
    let showSkeleton = true;
    const skeletonTarget = h(
      "div",
      {},
      h(
        "div",
        {
          class: "demo-row-bottom",
        },
        skeleton({ variant: "avatar" }),
        h(
          "div",
          { class: "demo-flex-stack" },
          skeleton({ variant: "title", width: "40%" }),
          skeleton({ variant: "text", width: "70%" }),
        ),
      ),
      skeleton({ variant: "card", height: "80px" }),
    );

    const skeletonToggleBtn = button({
      label: "Toggle Skeleton / Content",
      variant: "outline",
      size: "sm",
      icon: "refresh",
      onClick: () => {
        showSkeleton = !showSkeleton;
        if (showSkeleton) {
          skeletonTarget.replaceChildren(
            h(
              "div",
              {
                class: "demo-row-bottom",
              },
              skeleton({ variant: "avatar" }),
              h(
                "div",
                { class: "demo-flex-stack" },
                skeleton({ variant: "title", width: "40%" }),
                skeleton({ variant: "text", width: "70%" }),
              ),
            ),
            skeleton({ variant: "card", height: "80px" }),
          );
        } else {
          skeletonTarget.replaceChildren(
            h(
              "div",
              {
                class: "demo-row-bottom",
              },
              avatar({ name: "Juan Dela Cruz", size: "md", status: "online" }),
              h(
                "div",
                { class: "demo-flex-fill" },
                h(
                  "h4",
                  { class: "demo-small-title" },
                  "Juan Dela Cruz",
                ),
                h(
                  "p",
                  { class: "muted" },
                  "Member ID: CPC-2026-00001 · Rank: Intermediate High",
                ),
              ),
            ),
            card({
              title: "Upcoming Match",
              subtitle: "Court 1 · 04:00 PM today",
              content: "Doubles Quarterfinal match vs. Team Santos/Reyes.",
            }),
          );
        }
      },
    });

    // Empty and error states
    const emptyStateDemo = emptyState({
      icon: "inbox",
      title: "No bookings found",
      description: "No reservations match your selected date or court filters.",
      resetLabel: "Reset Filters & Date Range",
      onReset: () =>
        toast("Filters reset to default window.", { tone: "info" }),
    });

    const errorStateDemo = emptyState({
      icon: "alert",
      title: "Could not sync tournament standings",
      description:
        "Network timeout while reaching the server. Your cached data is safe.",
      resetLabel: "Retry Connection",
      onReset: () => toast("Retrying sync…", { tone: "info" }),
    });

    const section = h(
      "section",
      { class: "component-section", id: "sec-feedback" },
      h(
        "div",
        { class: "component-section-head" },
        h("h2", {}, "4. Notifications & Feedback"),
        badge("Centralized Toasts & Alerts", "info"),
      ),
      h(
        "div",
        { class: "component-grid" },
        registerComponentCard({
          name: "Global Floating Toast System",
          keywords: [
            "toast",
            "notification",
            "floating",
            "success",
            "error",
            "warning",
            "info",
          ],
          guidance:
            "Floating alerts in bottom-right corner with polite/assertive live region announcements and auto-dismiss.",
          variants: "Success, Error, Warning, Info",
          demoEl: toastTriggers,
        }),
        registerComponentCard({
          name: "Inline Alert Boxes",
          keywords: ["alert", "inline", "box", "banner", "message"],
          guidance:
            "In-page notification banners with clear iconography and accessible color contrast.",
          variants: "4 Semantic Tones",
          demoEl: alertsDemo,
        }),
        registerComponentCard({
          name: "Announcement Banners",
          keywords: ["banner", "announcement", "top"],
          guidance:
            "Prominent page-wide announcements with action verbs and dismiss button.",
          variants: "Info, Warning",
          demoEl: bannerDemo,
        }),
        registerComponentCard({
          name: "Validation Summary",
          keywords: ["validation", "summary", "error", "list", "form"],
          guidance:
            "Aggregates all form errors above submission buttons with specific resolution steps.",
          variants: "Form Error Summary",
          demoEl: valSummaryDemo,
        }),
        registerComponentCard({
          name: "Progress Bars",
          keywords: [
            "progress",
            "bar",
            "determinate",
            "indeterminate",
            "percent",
          ],
          guidance:
            "Shows task completion percentage or indeterminate animated progress.",
          variants: "Determinate, Indeterminate",
          demoEl: h(
            "div",
            { class: "demo-stack" },
            progressEl,
            progressBtns,
            indeterminateBar,
          ),
        }),
        registerComponentCard({
          name: "Loading Spinners",
          keywords: ["spinner", "loading", "circular"],
          guidance:
            "Smooth circular loading spinners in 16px, 24px, and 36px sizes.",
          variants: "sm, md, lg",
          demoEl: spinnersDemo,
        }),
        registerComponentCard({
          name: "Structure-Matched Skeletons",
          keywords: ["skeleton", "placeholder", "loading", "shimmer"],
          guidance:
            "Matches the exact structure and dimensions of the content it replaces to eliminate layout shifts.",
          variants: "Avatar, Title, Card, Text",
          demoEl: h(
            "div",
            { class: "demo-stack" },
            skeletonToggleBtn,
            skeletonTarget,
          ),
        }),
        registerComponentCard({
          name: "Empty & Error States",
          keywords: ["empty", "error", "state", "retry", "reset"],
          guidance:
            "Centered state with icon badge, specific explanation, and contextual action or retry.",
          variants: "Empty State, Error State",
          demoEl: h(
            "div",
            { class: "demo-stack-lg" },
            emptyStateDemo,
            errorStateDemo,
          ),
        }),
      ),
    );
    return section;
  };

  // ==========================================
  // SECTION 5: MODALS AND OVERLAYS
  // ==========================================
  const buildModalsSection = () => {
    // Form Modal Demo
    const openFormModalBtn = button({
      label: "Open Form Modal (Medium)",
      variant: "primary",
      icon: "plus",
      onClick: () => {
        const bodyContent = h(
          "div",
          { class: "demo-stack" },
          field({
            id: "m-court",
            label: "Court Selection",
            value: "Court 1 (Indoor Wood)",
            required: true,
          }),
          field({
            id: "m-date",
            label: "Date",
            type: "date",
            value: businessDate(),
            required: true,
          }),
          field({
            id: "m-notes",
            label: "Booking Notes",
            placeholder: "Optional player notes…",
          }),
        );
        openModal({
          title: "New Court Reservation",
          eyebrow: "Booking System",
          description:
            "Reserve a 1-hour court block. Admin approval is required.",
          icon: "calendar",
          body: bodyContent,
          confirmLabel: "Submit Booking",
          onConfirm: async () => {
            await new Promise((r) => setTimeout(r, 1200));
            toast("Reservation submitted for admin review!", {
              tone: "success",
            });
            return true;
          },
        });
      },
    });

    // Confirmation Modal Demo
    const openConfirmBtn = button({
      label: "Open Confirmation Dialog",
      variant: "secondary",
      icon: "check",
      onClick: () => {
        confirmModal({
          title: "Finalize Match Division?",
          message:
            "Finalizing division scores will compute final standings and advance participants to the next tournament stage.",
          icon: "alertTriangle",
          confirmLabel: "Finalize Now",
          onConfirm: async () => {
            await new Promise((r) => setTimeout(r, 800));
            toast("Division finalized and standings updated.", {
              tone: "success",
            });
          },
        });
      },
    });

    // Destructive Confirmation Demo
    const openDestructiveBtn = button({
      label: "Open Destructive Confirmation",
      variant: "danger",
      icon: "trash",
      onClick: () => {
        confirmModal({
          title: "Delete Court Reservation?",
          message:
            "Are you sure you want to cancel and remove this reservation? This action is idempotent and cannot be undone.",
          icon: "alert",
          confirmLabel: "Yes, Delete Reservation",
          destructive: true,
          onConfirm: async () => {
            await new Promise((r) => setTimeout(r, 800));
            toast("Reservation cancelled.", { tone: "error" });
          },
        });
      },
    });

    // Drawer Demo
    const openDrawerBtn = button({
      label: "Open Off-Canvas Drawer",
      variant: "outline",
      icon: "layers",
      onClick: () => {
        const drawerBody = h(
          "div",
          { class: "demo-stack-lg" },
          h("h4", { class: "demo-reset-margin" }, "Player Quick Profile"),
          avatar({ name: "Juan Dela Cruz", size: "lg", status: "online" }),
          divider({ label: "Details" }),
          h("p", { class: "muted" }, "Member ID: CPC-2026-00001"),
          h("p", { class: "muted" }, "Rating: 3.5 (Intermediate High)"),
          h("p", { class: "muted" }, "Total Matches Played: 28"),
          button({
            label: "View Full Profile",
            variant: "primary",
            onClick: () => toast("Opening full profile…"),
          }),
        );
        openDrawer({
          title: "Player Information",
          eyebrow: "CPC Registry",
          description: "Quick member overview and tournament history.",
          body: drawerBody,
        });
      },
    });

    // Popover Demo
    const popoverTrigger = button({
      label: "Toggle Popover",
      variant: "secondary",
      icon: "info",
    });
    const popoverDemo = popover({
      trigger: popoverTrigger,
      content: h(
        "div",
        { class: "demo-stack-sm" },
        h("h4", { class: "demo-body-title" }, "Rating Information"),
        h(
          "p",
          { class: "muted" },
          "Ratings are calculated on division finalization, not per single match.",
        ),
      ),
    });

    // Dropdown Menu Demo
    const dropdownTrigger = button({
      label: "Dropdown Options",
      variant: "secondary",
      icon: "chevronDown",
      iconPosition: "right",
    });
    const dropdownMenuDemo = dropdownMenu({
      trigger: dropdownTrigger,
      items: [
        {
          label: "View Profile",
          icon: "user",
          onClick: () => toast("Profile clicked"),
        },
        {
          label: "Account Settings",
          icon: "sliders",
          onClick: () => toast("Settings clicked"),
        },
        { divider: true },
        {
          label: "Sign Out",
          icon: "x",
          danger: true,
          onClick: () => toast("Sign out requested", { tone: "warning" }),
        },
      ],
    });

    // Tooltip demo
    const tooltipDemo = tooltip({
      text: "Only active members in good standing may reserve courts.",
      element: button({
        label: "Hover for Tooltip",
        variant: "outline",
        icon: "info",
      }),
    });

    // Modal sizes buttons
    const sizesModalDemo = h(
      "div",
      { class: "demo-row-sm" },
      button({
        label: "Small (420px)",
        size: "sm",
        variant: "secondary",
        onClick: () =>
          openModal({
            title: "Small Modal",
            size: "sm",
            body: h(
              "p",
              { class: "muted" },
              "Compact dialog for simple confirmations or single input.",
            ),
          }),
      }),
      button({
        label: "Medium (560px)",
        size: "sm",
        variant: "secondary",
        onClick: () =>
          openModal({
            title: "Medium Modal",
            size: "md",
            body: h(
              "p",
              { class: "muted" },
              "Standard modal for typical multi-field workflows.",
            ),
          }),
      }),
      button({
        label: "Large (800px)",
        size: "sm",
        variant: "secondary",
        onClick: () =>
          openModal({
            title: "Large Modal",
            size: "lg",
            body: h(
              "p",
              { class: "muted" },
              "Spacious modal for dense forms, comparisons, and tournament bracket reviews.",
            ),
          }),
      }),
    );

    const section = h(
      "section",
      { class: "component-section", id: "sec-modals" },
      h(
        "div",
        { class: "component-section-head" },
        h("h2", {}, "5. Modals & Overlays"),
        badge("Native <dialog> & Focus Trapping", "success"),
      ),
      h(
        "div",
        { class: "component-grid" },
        registerComponentCard({
          name: "Standard Form Modal",
          keywords: ["modal", "dialog", "form", "popup", "openModal"],
          guidance:
            "Native dialog with icon badge header, focus trapping, Escape dismissal, and submit spinner.",
          variants: "Small, Medium, Large",
          demoEl: h(
            "div",
            { class: "demo-stack" },
            openFormModalBtn,
            sizesModalDemo,
          ),
        }),
        registerComponentCard({
          name: "Confirmations & Destructive Dialogs",
          keywords: ["confirm", "destructive", "delete", "confirmModal"],
          guidance:
            "Clearly states the target and consequences. Defaults to a safe Cancel action.",
          variants: "Confirm, Destructive",
          demoEl: h(
            "div",
            { class: "demo-row-sm" },
            openConfirmBtn,
            openDestructiveBtn,
          ),
        }),
        registerComponentCard({
          name: "Off-Canvas Drawer",
          keywords: ["drawer", "panel", "slide", "openDrawer"],
          guidance:
            "Side panel sliding in from the right edge for detailed inspection without navigating away.",
          variants: "Drawer",
          demoEl: openDrawerBtn,
        }),
        registerComponentCard({
          name: "Popovers, Tooltips & Dropdowns",
          keywords: ["popover", "tooltip", "dropdownMenu", "menu", "context"],
          guidance:
            "Floating interactive surfaces with keyboard navigation, Escape dismiss, and clean backdrop click handling.",
          variants: "Popover, Dropdown, Tooltip",
          demoEl: h(
            "div",
            {
              class: "demo-row",
            },
            popoverDemo,
            dropdownMenuDemo,
            tooltipDemo,
          ),
        }),
      ),
    );
    return section;
  };

  // ==========================================
  // SECTION 6: NAVIGATION
  // ==========================================
  const buildNavigationSection = () => {
    // Breadcrumbs Demo
    const breadcrumbDemo = breadcrumbs({
      items: [
        { label: "Club Home", href: "#/" },
        { label: "Tournaments", href: "#/components" },
        { label: "Summer Open 2026", href: "#/components" },
        { label: "Bracket Results" },
      ],
    });

    // Tabs Demo
    const tabPanels = h(
      "div",
      { class: "demo-stack" },
      ...[
        ["overview", "Event overview and registration summary."],
        ["participants", "32 sample participants are registered."],
        ["schedule", "Sample matches start at 8:00 AM, Asia/Manila."],
        ["rules", "Review the event rules and waiver before registration."],
      ].map(([id, text]) =>
        h("p", {
          id: `panel-${id}`,
          role: "tabpanel",
          "aria-labelledby": `tab-${id}`,
          tabindex: "0",
          hidden: id !== "overview",
        }, text)
      ),
    );
    const tabDemo = h(
      "div",
      { class: "demo-stack" },
      tabs({
        tabs: [
          { id: "overview", label: "Overview", icon: "grid", badge: "Live" },
          {
            id: "participants",
            label: "Participants",
            icon: "user",
            badge: "32",
          },
          { id: "schedule", label: "Match Schedule", icon: "calendar" },
          { id: "rules", label: "Rules & Waiver", icon: "file" },
        ],
        activeId: "overview",
        onChange: (id) => {
          for (const panel of tabPanels.children) {
            panel.hidden = panel.id !== `panel-${id}`;
          }
        },
      }),
      tabPanels,
    );

    // Stepper Demo
    let activeStepIdx = 1;
    const stepperContainer = h("div", {});
    const renderStepper = () => {
      stepperContainer.replaceChildren(
        stepper({
          steps: [
            { label: "Member Profile", description: "Personal Details" },
            { label: "Division Select", description: "Choose Skill Bracket" },
            { label: "Waiver & Proof", description: "Upload Receipt" },
            { label: "Admin Approval", description: "Review & Confirmation" },
          ],
          currentStep: activeStepIdx,
          onStepClick: (idx) => {
            activeStepIdx = idx;
            renderStepper();
            toast(`Step changed to ${idx + 1}`, { tone: "info" });
          },
        }),
      );
    };
    renderStepper();

    // Sidebar navigation demo
    const sidebarDemo = sidebarNav({
      items: [
        { header: "Main Navigation" },
        { path: "#/", label: "Dashboard", icon: "home" },
        {
          path: "#/courts",
          label: "Court Booking",
          icon: "calendar",
          badge: "2",
        },
        { path: "#/tournaments", label: "Tournaments", icon: "layers" },
        { header: "Account & Settings" },
        { path: "#/profile", label: "Member Profile", icon: "user" },
        {
          path: "#/settings",
          label: "Club Settings",
          icon: "sliders",
          disabled: true,
        },
      ],
      activePath: "#/tournaments",
      onNavigate: (path) => toast(`Navigate: ${path}`, { tone: "info" }),
    });

    // Pagination Demo
    let curPage = 2;
    const pagerDemo = h("div", {});
    const renderPager = () => {
      pagerDemo.replaceChildren(
        pagination({
          page: curPage,
          pageSize: 10,
          total: 48,
          onPage: (p) => {
            curPage = p;
            renderPager();
            toast(`Page ${p} loaded`, { tone: "info" });
          },
        }),
      );
    };
    renderPager();

    const section = h(
      "section",
      { class: "component-section", id: "sec-navigation" },
      h(
        "div",
        { class: "component-section-head" },
        h("h2", {}, "6. Navigation"),
        badge("Breadcrumbs, Tabs, Steppers", "info"),
      ),
      h(
        "div",
        { class: "component-grid" },
        registerComponentCard({
          name: "Breadcrumbs",
          keywords: ["breadcrumbs", "navigation", "trail", "path"],
          guidance:
            "Accessible trail using aria-label and aria-current='page' on the active leaf node.",
          variants: "Breadcrumb Trail",
          demoEl: breadcrumbDemo,
        }),
        registerComponentCard({
          name: "Tabs Navigation",
          keywords: ["tabs", "tablist", "panels", "navigation"],
          guidance:
            "ARIA tablist with icons, badge counts, and active underline indicators.",
          variants: "Underline Tabs",
          demoEl: tabDemo,
        }),
        registerComponentCard({
          name: "Progress Stepper",
          keywords: ["stepper", "wizard", "steps", "multi-step"],
          guidance:
            "Step-by-step progress indicator with completed checkmarks and current step labels.",
          variants: "Numbered Stepper",
          demoEl: stepperContainer,
        }),
        registerComponentCard({
          name: "Sidebar Navigation",
          keywords: ["sidebar", "navigation", "menu", "sidebarNav"],
          guidance:
            "Grouped vertical menu with category headers, icons, and status badges.",
          variants: "Sidebar Nav",
          demoEl: sidebarDemo,
        }),
        registerComponentCard({
          name: "Data Pagination",
          keywords: ["pagination", "pager", "pages", "table"],
          guidance:
            "Clamped previous/next and numeric page controls. Never displays misleading 1-0 on empty results.",
          variants: "Pagination Pager",
          demoEl: pagerDemo,
        }),
      ),
    );
    return section;
  };

  // ==========================================
  // SECTION 7: DATA DISPLAY
  // ==========================================
  const buildDataDisplaySection = () => {
    // Stat cards demo
    const statCardsDemo = h(
      "div",
      {
        class: "demo-metric-grid",
      },
      statCard({
        label: "Total Members",
        value: "348",
        change: "+12% this month",
        changeTone: "success",
        icon: "user",
      }),
      statCard({
        label: "Active Bookings",
        value: "24",
        change: "+5 today",
        changeTone: "success",
        icon: "calendar",
      }),
      statCard({
        label: "Court Utilization",
        value: "88%",
        change: "-3% vs peak",
        changeTone: "danger",
        icon: "grid",
      }),
      kpiCard("Monthly Revenue", formatMoney(12500000)),
    );

    // Badges & Status Indicators demo
    const badgesDemo = h(
      "div",
      {
        class: "demo-row-sm-center",
      },
      badge("Success", "success"),
      badge("Warning", "warning"),
      badge("Danger", "danger"),
      badge("Info", "info"),
      badge("Primary", "primary"),
      badge("Neutral", "neutral"),
    );

    const statusIndicatorsDemo = h(
      "div",
      {
        class: "demo-row-medium",
      },
      statusIndicator({
        status: "active",
        label: "Court Open",
        tone: "success",
      }),
      statusIndicator({
        status: "busy",
        label: "Match in Progress",
        tone: "danger",
      }),
      statusIndicator({
        status: "pending",
        label: "Pending Approval",
        tone: "warning",
      }),
      statusIndicator({
        status: "closed",
        label: "Lighting Maintenance",
        tone: "info",
      }),
    );

    // Avatars demo
    const avatarsDemo = h(
      "div",
      {
        class: "demo-row",
      },
      avatar({ name: "Juan Dela Cruz", size: "sm", status: "online" }),
      avatar({ name: "Maria Santos", size: "md", status: "busy" }),
      avatar({ name: "Andres Bonifacio", size: "lg", status: "offline" }),
    );

    // Accordion demo
    const accordionDemo = accordion({
      items: [
        {
          id: "acc-1",
          title: "How do skill rating promotions work?",
          content:
            "Ranks change once per member after the division finalization of a sanctioned tournament. Split single elimination champions gain +1 level; consolation bracket finalists retain rank.",
          defaultOpen: true,
        },
        {
          id: "acc-2",
          title: "What is the cancellation policy for court bookings?",
          content:
            "Reservations can be cancelled up to 2 hours before the booked start time. Cancellations are recorded in the audit log and release the time slot immediately.",
        },
        {
          id: "acc-3",
          title: "Are non-member guests allowed on courts?",
          content:
            "All players must have a registered member account with verified profile data before participating in matches.",
        },
      ],
    });

    // Dividers demo
    const dividerDemo = h(
      "div",
      { class: "demo-stack-sm" },
      divider({ label: "Or Continue With" }),
      divider({}),
    );

    // Full interactive Data Table demo
    const tableSchema = {
      columns: [
        { key: "member_id", label: "Member ID" },
        { key: "name", label: "Player Name" },
        { key: "category", label: "Category" },
        { key: "matches", label: "Matches", align: "right" },
        { key: "fee", label: "Balance", kind: "money", align: "right" },
        {
          key: "status",
          label: "Status",
          render: (r) =>
            badge(r.status, r.status === "active" ? "success" : "warning"),
        },
      ],
      actions: [
        {
          label: "Edit Member",
          icon: "edit",
          onClick: (r) => toast(`Editing ${r.name}`, { tone: "info" }),
        },
        {
          label: "Delete Member",
          icon: "trash",
          onClick: (r) => toast(`Delete ${r.name}`, { tone: "error" }),
        },
      ],
    };

    const SAMPLE_MEMBERS = [
      {
        member_id: "CPC-2026-00001",
        name: "Juan Dela Cruz",
        category: "Intermediate High",
        matches: 42,
        fee: 1250,
        status: "active",
      },
      {
        member_id: "CPC-2026-00002",
        name: "Maria Santos",
        category: "Novice Low",
        matches: 15,
        fee: 500,
        status: "pending",
      },
      {
        member_id: "CPC-2026-00003",
        name: "Jose Rizal",
        category: "Advanced Open",
        matches: 78,
        fee: 2000,
        status: "active",
      },
      {
        member_id: "CPC-2026-00004",
        name: "Andres Bonifacio",
        category: "Intermediate Low",
        matches: 29,
        fee: 750,
        status: "active",
      },
      {
        member_id: "CPC-2026-00005",
        name: "Gabriela Silang",
        category: "Novice High",
        matches: 21,
        fee: 0,
        status: "active",
      },
    ];

    let tableStateMode = "ready";
    let tableSearch = "";
    const tableHost = h("div", {});

    const renderDataTableDemo = () => {
      const filtered = SAMPLE_MEMBERS.filter((m) =>
        m.name.toLowerCase().includes(tableSearch.toLowerCase()) ||
        m.member_id.toLowerCase().includes(tableSearch.toLowerCase())
      );
      tableHost.replaceChildren(
        dataTable({
          schema: tableSchema,
          rows: filtered,
          state: tableStateMode,
          hasFilters: tableSearch !== "",
          emptyTitle: "No members match search query",
          emptyText: "No players exist in this division.",
          onReset: () => {
            tableSearch = "";
            renderDataTableDemo();
          },
          onRetry: () => {
            tableStateMode = "ready";
            renderDataTableDemo();
          },
        }),
      );
    };

    const tableToolbar = toolbar({
      searchLabel: "Search player by name or ID…",
      onSearch: (v) => {
        tableSearch = v;
        renderDataTableDemo();
      },
      actions: [
        button({
          label: "Ready",
          size: "sm",
          variant: "secondary",
          onClick: () => {
            tableStateMode = "ready";
            renderDataTableDemo();
          },
        }),
        button({
          label: "Loading Skeleton",
          size: "sm",
          variant: "secondary",
          onClick: () => {
            tableStateMode = "loading";
            renderDataTableDemo();
          },
        }),
        button({
          label: "Error State",
          size: "sm",
          variant: "secondary",
          onClick: () => {
            tableStateMode = "error";
            renderDataTableDemo();
          },
        }),
      ],
    });

    renderDataTableDemo();

    const section = h(
      "section",
      { class: "component-section", id: "sec-datadisplay" },
      h(
        "div",
        { class: "component-section-head" },
        h("h2", {}, "7. Data Display"),
        badge("Cards, Tables, Badges", "info"),
      ),
      h(
        "div",
        { class: "component-grid" },
        registerComponentCard({
          name: "Statistic KPI Cards",
          keywords: ["kpi", "card", "statCard", "metric", "trend"],
          guidance:
            "Highlights key business metrics with percentage change and semantic color indicators.",
          variants: "KPI Stat Cards",
          demoEl: statCardsDemo,
        }),
        registerComponentCard({
          name: "Badges & Status Dots",
          keywords: ["badge", "status", "indicator", "pill"],
          guidance:
            "Consistent 24px height badges with high contrast border and text tokens.",
          variants: "6 Badges, 4 Indicators",
          demoEl: h(
            "div",
            { class: "demo-stack" },
            badgesDemo,
            statusIndicatorsDemo,
          ),
        }),
        registerComponentCard({
          name: "Member Avatars",
          keywords: ["avatar", "user", "profile", "image", "initials"],
          guidance:
            "Small, medium, and large circles with fallback initials and real-time status dots.",
          variants: "sm, md, lg",
          demoEl: avatarsDemo,
        }),
        registerComponentCard({
          name: "Collapsible Accordion",
          keywords: ["accordion", "collapse", "expand", "faq"],
          guidance:
            "Clean expandable panels with animated chevron and keyboard navigation support.",
          variants: "Accordion",
          demoEl: accordionDemo,
        }),
        registerComponentCard({
          name: "Visual Dividers",
          keywords: ["divider", "separator", "rule"],
          guidance:
            "Horizontal and vertical dividers with optional centered label.",
          variants: "Horizontal, Vertical",
          demoEl: dividerDemo,
        }),
        registerComponentCard({
          name: "Production Data Table",
          keywords: ["table", "dataTable", "grid", "tabular", "sorting"],
          guidance:
            "Single column definition drives header, populated rows, and skeleton. Numbers and money are right-aligned with tabular numerals.",
          variants: "Live Table, Skeletons, Empty, Error",
          demoEl: h(
            "div",
            { class: "demo-stack" },
            tableToolbar,
            tableHost,
          ),
        }),
      ),
    );
    return section;
  };

  // ==========================================
  // SECTION 8: COMPLETE FORM EXAMPLE
  // ==========================================
  const buildCompleteFormSection = () => {
    // State tracking dirty and validation
    let isDirty = false;
    const initialValues = {
      fullName: "",
      email: "",
      mobile: "",
      category: "novice_low",
      password: "",
      confirmPassword: "",
      fee: "1500.00",
      birthDate: "1995-06-15",
      smsAlerts: true,
      agreeWaiver: false,
    };

    let formValues = { ...initialValues };
    const summaryContainer = h("div", {});

    const updateDirty = () => {
      isDirty = JSON.stringify(formValues) !== JSON.stringify(initialValues);
    };

    const nameInput = field({
      id: "cf-name",
      label: "Full Legal Name",
      value: formValues.fullName,
      placeholder: "e.g. Juan C. Dela Cruz",
      required: true,
      hint: "As it appears on your government identification.",
      onInput: (e) => {
        formValues.fullName = e.target.value;
        updateDirty();
      },
    });

    const emailInput = field({
      id: "cf-email",
      label: "Email Address",
      type: "email",
      value: formValues.email,
      placeholder: "juan@example.com",
      required: true,
      iconLeading: "mail",
      hint: "For confirmation notices and security updates.",
      onInput: (e) => {
        formValues.email = e.target.value;
        updateDirty();
      },
    });

    const mobileInput = field({
      id: "cf-mobile",
      label: "Philippine Mobile Number",
      type: "tel",
      value: formValues.mobile,
      placeholder: "09171234567",
      required: true,
      iconLeading: "phone",
      hint: "Exactly 11 digits starting with 09.",
      onInput: (e) => {
        formValues.mobile = e.target.value;
        updateDirty();
      },
    });

    const categorySelect = selectField({
      id: "cf-category",
      label: "Initial Skill Category",
      options: [
        { value: "novice_low", label: "Novice Low (1.0 - 2.0)" },
        { value: "novice_high", label: "Novice High (2.5)" },
        { value: "intermediate_low", label: "Intermediate Low (3.0)" },
        { value: "intermediate_high", label: "Intermediate High (3.5)" },
        { value: "advanced", label: "Advanced (4.0+)" },
      ],
      value: formValues.category,
      required: true,
      hint:
        "Self-assessed rating. Official rank assigned after first tournament.",
      onChange: (e) => {
        formValues.category = e.target.value;
        updateDirty();
      },
    });

    const passwordInput = field({
      id: "cf-password",
      label: "Password",
      type: "password",
      value: formValues.password,
      placeholder: "Minimum 12 characters",
      required: true,
      showToggle: true,
      hint: "At least 12 characters. Avoid common phrases.",
      onInput: (e) => {
        formValues.password = e.target.value;
        updateDirty();
      },
    });

    const confirmPasswordInput = field({
      id: "cf-confirm",
      label: "Confirm Password",
      type: "password",
      value: formValues.confirmPassword,
      placeholder: "Re-enter password",
      required: true,
      showToggle: true,
      hint: "Must match password exactly.",
      onInput: (e) => {
        formValues.confirmPassword = e.target.value;
        updateDirty();
      },
    });

    const birthDateInput = dateField({
      id: "cf-birthdate",
      label: "Birth Date",
      value: formValues.birthDate,
      required: true,
      hint: "Required for senior and junior bracket placement.",
      onChange: (e) => {
        formValues.birthDate = e.target.value;
        updateDirty();
      },
    });

    const feeInput = field({
      id: "cf-fee",
      label: "Registration Fee",
      value: formValues.fee,
      prefix: "₱",
      readonly: true,
      hint: "Annual membership fee (₱1,500.00).",
    });

    const smsSwitch = switchToggle({
      id: "cf-sms",
      label: "Receive Match & Schedule SMS Announcements",
      checked: formValues.smsAlerts,
      hint: "Real-time court calls and schedule adjustments.",
      onChange: (checked) => {
        formValues.smsAlerts = checked;
        updateDirty();
      },
    });

    const waiverCheck = checkbox({
      id: "cf-waiver",
      label:
        "I agree to Capitol Pickleball Club Rules, Safety Code & Liability Waiver",
      checked: formValues.agreeWaiver,
      required: true,
      hint: "Mandatory waiver agreement for all facility use.",
      onChange: (checked) => {
        formValues.agreeWaiver = checked;
        updateDirty();
      },
    });

    // Form buttons
    const submitBtn = button({
      label: "Submit Application",
      variant: "primary",
      icon: "checkCircle",
      type: "submit",
    });

    const resetBtn = button({
      label: "Reset Form",
      variant: "outline",
      type: "button",
      onClick: () => {
        if (isDirty) {
          confirmModal({
            title: "Discard Unsaved Changes?",
            message:
              "You have unsaved form entries. Are you sure you want to discard your changes and reset this form?",
            icon: "alertTriangle",
            confirmLabel: "Discard & Reset",
            cancelLabel: "Keep Editing",
            destructive: true,
            onConfirm: () => {
              formValues = { ...initialValues };
              nameInput.querySelector("input").value = "";
              emailInput.querySelector("input").value = "";
              mobileInput.querySelector("input").value = "";
              passwordInput.querySelector("input").value = "";
              confirmPasswordInput.querySelector("input").value = "";
              waiverCheck.querySelector("input").checked = false;
              summaryContainer.replaceChildren();
              isDirty = false;
              toast("Form reset to default values.", { tone: "info" });
            },
          });
        } else {
          toast("Form is already clean.", { tone: "info" });
        }
      },
    });

    const formEl = h(
      "form",
      { class: "complete-form-demo" },
      summaryContainer,
      h(
        "div",
        {
          class: "demo-form-grid",
        },
        nameInput,
        emailInput,
        mobileInput,
        categorySelect,
        passwordInput,
        confirmPasswordInput,
        birthDateInput,
        feeInput,
      ),
      h("div", { class: "demo-block-space" }, smsSwitch),
      h("div", { class: "demo-block-bottom" }, waiverCheck),
      h(
        "div",
        { class: "demo-row-end" },
        resetBtn,
        submitBtn,
      ),
    );

    formEl.addEventListener("submit", async (e) => {
      e.preventDefault();
      // Validation schema
      const schema = {
        fullName: { label: "Full Name", required: true, min: 3, max: 80 },
        email: { label: "Email Address", required: true, email: true },
        mobile: {
          label: "Mobile Number",
          required: true,
          custom: (
            v,
          ) => (/^09\d{9}$/.test(String(v || "").trim())
            ? null
            : "Enter an 11-digit Philippine mobile starting with 09."),
        },
        password: {
          label: "Password",
          required: true,
          custom: (v) => {
            const probs = localPasswordProblems(
              String(v || ""),
              formValues.confirmPassword,
            );
            return probs[0] || null;
          },
        },
        agreeWaiver: {
          label: "Club Waiver",
          custom: (
            v,
          ) => (!v ? "You must agree to the club waiver to submit." : null),
        },
      };

      const res = validate(formValues, schema);
      if (!res.ok) {
        const errorList = Object.values(res.errors);
        summaryContainer.replaceChildren(
          validationSummary({
            title: "Please correct the following errors before submitting:",
            errors: errorList,
          }),
        );
        summaryContainer.scrollIntoView({ behavior: "smooth" });
        toast("Please fix form validation errors.", { tone: "error" });
        return;
      }

      summaryContainer.replaceChildren();
      submitBtn.dataset.pending = "true";
      submitBtn.disabled = true;

      try {
        await new Promise((r) => setTimeout(r, 1400));
        toast(
          "Member application submitted successfully! Pending admin approval.",
          {
            tone: "success",
            title: "Registration Received",
          },
        );
        isDirty = false;
      } finally {
        delete submitBtn.dataset.pending;
        submitBtn.disabled = false;
      }
    });

    const section = h(
      "section",
      { class: "component-section", id: "sec-completeform" },
      h(
        "div",
        { class: "component-section-head" },
        h("h2", {}, "8. Complete Form Example"),
        badge("End-to-End Workflow", "success"),
      ),
      registerComponentCard({
        name: "Member Registration & Tournament Entry Form",
        keywords: [
          "form",
          "validation",
          "complete",
          "submission",
          "loading",
          "unsaved",
          "dirty",
        ],
        guidance:
          "Integrates validation, password checks, Philippine mobile formatting, async submit spinner, error summary, floating toast, and unsaved changes confirmation modal.",
        variants: "Production Form Example",
        demoEl: formEl,
      }),
    );
    return section;
  };

  // Assemble full page
  host.append(
    header,
    stickyNav,
    noResults,
    buildFoundationsSection(),
    buildButtonsSection(),
    buildInputsSection(),
    buildFeedbackSection(),
    buildModalsSection(),
    buildNavigationSection(),
    buildDataDisplaySection(),
    buildCompleteFormSection(),
  );

  filterCards("");
  return host;
}
