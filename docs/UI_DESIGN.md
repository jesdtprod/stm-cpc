# UI Design Standard — STM-CPC

## Mandatory instruction for Antigravity and all coding agents

Directly edit the existing application to implement this standard. Do not stop at recommendations, sample screens, or a mockup when implementation is requested.

**STRICT: Do not skip a single applicable page, component, element, or state. The entire application must use one uniform design system.** This includes every role-based area (admin, staff, and any other user type), reports, nested dialogs, dynamically rendered content, and mobile views. Specialized workflows may have different layouts, but must use the same visual tokens and interaction conventions.

If a shared element changes, apply the change to every equivalent instance. Do not leave old and new designs mixed together. Do not mark the work complete while an applicable surface remains inconsistent. Identify any blocked surface explicitly instead of silently skipping it.

Preserve business logic, calculations, permissions, routes, data, and working interactions. Do not add dependencies, change authorization, or redesign unrelated workflows merely to restyle a screen.

## 1. Visual reference and implementation approach

- Establish the first fully approved page as the visual reference (dark navy surfaces, subtle blue borders, cyan/blue accents, restrained gradients, rounded cards, clear typography). Every later page is matched to it, not to its own local style.
- Treat the approved date-preset strip and centered empty-table design as the references for those patterns.
- Reuse the existing font family and icon system. Do not introduce competing fonts or icon styles.
- Centralize colors, spacing, type, radius, control dimensions, shadows, and states in shared tokens (CSS variables / Tailwind theme) and shared classes.
- Consolidate conflicting overrides rather than adding another layer of page-specific CSS or inline styles.
- Use reusable components for repeated table, modal, toolbar, empty-state, pagination, and skeleton patterns (for example shared Vue components rendered through Inertia layouts).
- Consistency means a shared visual language, not forcing every workflow into the same page layout.

## 2. Design tokens

Use one shared scale throughout the application:

| Property | Standard |
| --- | --- |
| Spacing | 4, 8, 12, 16, 24, 32px |
| Section separation | 16–24px |
| Page/card/modal padding | 24px desktop; 16px mobile |
| Page title | 20–24px; weight 700 |
| Section/modal title | 18–20px; weight 700 |
| Body and input text | 13–14px; weight 400–500 |
| Button and important cell text | 13–14px; weight 600–700 |
| Secondary text | 12px; weight 400–500 |
| Table heading | 11–12px; weight 700; uppercase |
| Body line height | Approximately 1.45–1.6 |
| Control height | 40–44px; touch targets at least 44px |
| Control radius | 10px |
| Card/modal radius | 14–16px |
| Icons | 18–20px; consistent stroke weight |
| Table cell padding | 12–16px vertical; 16–18px horizontal |

Use comfortable spacing, not excessive empty areas or compressed controls. Allow browser zoom and user text scaling. Do not disable zoom to make a layout fit.

## 3. Color, hierarchy, and readability

- Separate page background, raised panels, inputs, and hover states using subtle surface differences.
- Use blue/cyan for primary actions and information; green for success; amber for warning; red for destructive actions and errors.
- Never communicate meaning through color alone. Add a text label or recognizable icon.
- Keep primary text clearly readable; do not use faint text for essential values or instructions.
- Maintain at least 4.5:1 contrast for normal text and 3:1 for large text and meaningful control boundaries.
- Use restrained shadows and gradients. Avoid unnecessary glow, animation, excessive bold text, and decorative clutter.
- Use plain-language labels, consistent capitalization, and specific action verbs.

## 4. Page composition

Use this order when the section is applicable:

1. Page header: icon, optional eyebrow, title, short description, necessary actions.
2. Relevant KPI cards.
3. Search and filtering controls.
4. Date range, presets, and report actions.
5. Table or task-specific content.
6. Pagination/footer.

- Render only sections that the page actually needs. Do not add irrelevant KPIs, presets, search fields, or actions.
- Keep one clear primary action per task area. Secondary actions must have a distinct purpose.
- Do not repeat the same action in the header, toolbar, empty state, and footer.
- Keep related controls grouped, consistently aligned, and in a predictable order.
- Maintain comparable content widths and page gutters across equivalent screens.

## 5. Buttons, inputs, dropdowns, and badges

- Use shared primary, secondary, destructive, and icon-button variants with consistent dimensions.
- Define default, hover, focus-visible, active, disabled, and pending states for every interactive component.
- During submission, prevent duplicate actions and show clear progress without moving surrounding content.
- All row action buttons must be icon-only. Provide a specific tooltip and accessible label, such as "Edit record" rather than just "Action".
- Page actions and modal submission buttons retain readable text labels; the icon-only rule applies to row actions, not every button.
- Use persistent field labels. Placeholders supplement labels; they do not replace them.
- Place validation messages beside the affected field and preserve the user's entered values after an error.
- Use the same dropdown and datepicker styling everywhere, including controls added dynamically.
- Custom controls must support keyboard use, visible focus, correct roles, and expanded/selected states.
- Use one compact badge style with consistent height, padding, radius, text size, and semantic colors.

## 6. Grid tables and column content

- Header, populated rows, and skeleton rows must use exactly the same column definition.
- Distribute ordinary data columns equally across the available width. Reserve a compact, consistent width for Action based on its button count.
- Any necessary exception for long content must be defined in a shared table schema and applied identically to its header, rows, and skeleton—not as an isolated inline override.
- Center the Action heading and all action icons beneath it. Keep action-button gaps consistent.
- Left-align text. Right-align money and numerical amounts, including their headings. Use tabular numerals.
- Keep quantities, currency, and dates consistently formatted. Do not wrap a currency label separately from its amount.
- Place supporting information directly beneath its primary value using consistent spacing and secondary text.
- A cell's content and mobile label must match its column heading. Do not put notes under a heading for status or timestamps under an unrelated heading.
- Use real recorded values. Distinguish zero, unavailable data, not counted, and pending data; do not substitute a misleading zero.
- Allow long names and references to wrap safely. Avoid overlapping cells, clipped actions, and broken amounts.
- Use consistent row separators, hover treatment, row height, and vertical alignment.
- Use semantic table markup where practical. Grid-based tables must retain accessible header/cell relationships.

### Pagination

- Show a consistent footer with the visible row range and filtered record count.
- Use the same previous/next and page-number controls throughout the app.
- Reset or clamp the page when filters change so a valid result does not appear empty.
- Do not display a misleading "1–0" range for an empty result.

## 7. Date ranges and presets

- Display date controls only where date filtering is meaningful.
- Default to the first day of the current month through today, using the application's business timezone: Asia/Manila.
- Use the same compact preset strip: **Presets: This Month · Last 30 Days · All Time**.
- This Month means the first day of the current month through today.
- Last 30 Days means today and the preceding 29 days.
- All Time removes date restrictions; do not silently substitute an arbitrary date window.
- Synchronize preset selection and date inputs. Indicate a custom range when applicable.
- Prevent a reversed range. Apply inclusive business-date boundaries consistently.
- Keep Print PDF and Export PDF beside the report filters using shared button styles.
- Printed and exported reports must use the current filters and the same figures as the displayed report.

## 8. Empty, error, and refreshing states

### Empty table

Keep the table header visible. Center the following inside the table body:

1. Relevant icon in the standard icon container.
2. Specific title, for example "No transactions found".
3. A short explanation.
4. One reset action, only when filters are active.

For a page with date-range controls, use **Reset Filters & Date Range**. Otherwise use **Reset Filters**.

- Reset search, dropdown/chip filters, pagination, and any date range to its standard default.
- If there are genuinely no records and no active filters, explain that no records exist yet. Do not show an ineffective reset button.
- Do not duplicate an existing header creation button inside the empty state.
- Do not show fake pagination or zero-value summary results while data is loading.

### Error and stale data

- Loading failure is not an empty dataset. Show a clear error with an appropriate retry action.
- If retaining previously loaded data, clearly label it as the last successful update and indicate refreshing or connection failure.
- Do not hide a failed save behind a success message or discard the user's input.

## 9. Standard modal anatomy

Every modal must use the same header and footer design, including nested and dynamically created modals.

- Header: shared icon badge, optional eyebrow, title, concise description, and icon-only close button.
- Use consistent padding and a subtle divider between header and body.
- Body: shared form controls, label spacing, validation, and field-group gaps.
- Use equal-width form columns when appropriate; long references, descriptions, and notes use full width.
- Footer: shared divider and padding; Cancel followed by the primary action, right-aligned on desktop.
- Do not duplicate footer submission actions in the body.
- Keep long modal bodies scrollable and the header/footer reachable. Do not let content extend beyond the viewport.
- Stack fields and actions consistently on small screens; ensure sufficient touch targets.
- Provide an accessible dialog name, initial focus, focus containment, and focus restoration after closing.
- Support Escape and backdrop closing when safe. Protect unsaved changes where the workflow requires it.
- Destructive confirmations must clearly describe the target and consequences and default to a safe choice.

## 10. Structure-based skeleton loading

Build skeletons from the actual page and table schema, not a generic loading rectangle.

- Match the real header, KPIs, toolbar, columns, alignment, padding, and approximate row height.
- Use image placeholders only in columns that contain images.
- Match primary/secondary text stacks, badges, amounts, and centered action-icon groups.
- Use a small representative number of rows and reserve stable space to minimize layout shifts.
- Use subtle animation and honor `prefers-reduced-motion`.
- Mark the region busy for assistive technology (`aria-busy="true"`); decorative skeletons must not be announced as real content.
- Never show "No records found" while a request is pending.
- Keep loading, empty, error, refreshing, and populated states distinct.
- Prevent stale requests from overwriting newer filters, accounts, or views.

## 11. Responsive and accessible interaction

- Verify desktop, tablet, and mobile—not just one screenshot size.
- Preserve all data and actions on small screens. Use a consistent labeled-card pattern or a deliberately scrollable table for dense comparisons.
- Do not shrink text to unreadable sizes, hide necessary actions, or force the entire page to scroll horizontally.
- Ensure keyboard operation, visible focus, accessible names, and logical tab order.
- Make tooltips supplementary; essential instructions must remain available without hover.
- Respect reduced motion and avoid flashing effects.
- Keep status changes and errors understandable to screen-reader users.

## 12. UI design best practices

General principles that apply to every screen. When a rule here conflicts with a specific rule above, the specific rule wins.

### 12.1 Hierarchy and layout
- Make the most important thing on each screen the most visually prominent. Use size, weight, color, and position—in that order—to establish hierarchy, not decoration.
- Group related items with proximity and shared containers; separate unrelated groups with more space than the space inside a group.
- Use a consistent grid and alignment. Align to a common left edge; avoid arbitrary offsets.
- Follow natural reading patterns (F-pattern for data-dense pages, Z-pattern for sparse ones). Put the primary action where users expect it.
- Prefer whitespace over borders and dividers for separation. Add a line only when spacing alone is not clear enough.

### 12.2 Consistency and predictability
- Same function, same look, same place. A control must never look different in two places or behave differently for the same intent.
- Use familiar conventions (magnifier for search, X to close, trash for delete). Do not reinvent standard patterns.
- Name things with one term across the app (do not alternate "Delete", "Remove", and "Discard" for the same action).
- Keep navigation stable. The current location must always be clearly indicated.

### 12.3 Clarity and content
- Lead with the user's task, not the system's structure. Use words the users actually use.
- Keep labels short and specific: verb + object ("Save Student", not "Submit").
- Write error messages that say what happened, why, and how to fix it. Never blame the user.
- Show only what is needed now. Use progressive disclosure for advanced or rarely used options.
- Provide sensible defaults so most users can proceed without configuration.

### 12.4 Feedback and system status
- Every action gets a visible response: pressed state, progress, then success or failure.
- Use optimistic UI only when failure is rare and recoverable; otherwise wait for confirmation.
- Show progress for any operation longer than about one second; use skeletons for known layouts and spinners only for short, indeterminate waits.
- Confirm destructive actions, but prefer **undo** over confirmation dialogs when the action is reversible. Over-confirming trains users to click through.
- Toasts are for transient, non-critical confirmation. Errors that need action stay on screen until resolved.

### 12.5 Forms
- One column by default. Place labels above fields. Group related fields under clear section headings.
- Mark optional fields rather than required ones when most fields are required (or the reverse—pick one rule app-wide).
- Use the right input for the data: date picker for dates, numeric keyboard for numbers, select/radio for fixed sets, `autocomplete` attributes for personal data.
- Validate on blur and on submit, not on every keystroke. Show inline errors beside the field and move focus to the first invalid field on submit.
- Never clear valid input after an error. Never disable the submit button without telling the user why.
- Support paste, autofill, and password managers. Do not block them.

### 12.6 Data-dense interfaces (tables, dashboards, reports)
- Show the most decision-relevant columns first; allow sorting and filtering on the columns people actually search by.
- Keep numbers right-aligned with consistent decimals and units. Make totals visually distinct.
- Limit KPI cards to metrics that drive a decision; every card should answer a question the user really asks.
- Use charts only when they reveal a pattern a table cannot. Label axes and units; start bar charts at zero; do not rely on color alone to distinguish series.
- Always provide a path from summary to detail (click-through to the underlying records).

### 12.7 Accessibility (WCAG 2.2 AA minimum)
- Meet contrast ratios (4.5:1 text, 3:1 large text and UI boundaries).
- Everything must be operable by keyboard alone, with visible focus and a logical order. Provide a skip-to-content link on pages with heavy navigation.
- Use semantic HTML first (`button`, `a`, `table`, `label`, `nav`, `main`); add ARIA only to fill genuine gaps.
- Provide text alternatives for meaningful images and accessible names for icon-only controls. Mark decorative icons `aria-hidden="true"`.
- Pointer targets at least 24×24 CSS px by WCAG minimum; this standard requires 44px for touch controls.
- Do not rely on hover, color, sound, or motion alone to convey information.
- Announce dynamic changes (toasts, validation, loading results) with live regions.

### 12.8 Responsive design
- Design mobile-first, then enhance. Content decides breakpoints, not device names.
- Use fluid layouts and relative units; avoid fixed pixel widths for containers.
- On mobile, put primary actions within thumb reach, collapse secondary navigation, and keep forms single-column.
- Test with real content: very long names, large numbers, empty values, and many items.
- Support landscape, split-screen, and zoom up to 200% without loss of content or function.

### 12.9 Performance as UX
- Perceived speed matters: render the layout immediately, stream content in, and avoid layout shift (reserve space for images and async content).
- Lazy-load below-the-fold images and heavy components. Debounce search inputs (about 250–300ms).
- Paginate or virtualize long lists. Avoid loading everything at once.
- Keep animations to short durations (100–250ms) with easing; animate only `transform` and `opacity` where possible.

### 12.10 Dark-theme specifics
- Avoid pure black backgrounds and pure white text; use layered navy/gray surfaces and slightly off-white text to reduce glare.
- Express elevation with lighter surfaces and subtle borders instead of heavy shadows.
- Desaturate accent colors slightly on dark surfaces and re-check contrast for every semantic color.
- If a light theme is added later, drive both from the same tokens so no component is hard-coded to one theme.

### 12.11 Maintainability
- Build components once, with variants and documented props. A new screen should be assembled from existing parts.
- Never hard-code a color, size, or radius in a component; reference a token.
- Keep a living inventory of components and states (a simple page that renders every variant is enough) and use it for visual review.
- Review every UI change against this document before merging.

### 12.12 Quick self-review before shipping a screen
1. Is the main purpose and primary action obvious within three seconds?
2. Does it use only shared tokens and components?
3. Does it work with keyboard only, and at 200% zoom?
4. Are loading, empty, error, and populated states all designed?
5. Does it still work with the longest realistic data and with no data?
6. Does it look correct at mobile, tablet, and desktop widths?

## 13. Strict implementation and acceptance checklist

Before editing, inventory every page, table, toolbar, button variant, dropdown, datepicker, badge, modal, pagination footer, and loading/empty/error state. Include role-specific, hidden, nested, and dynamically rendered surfaces.

Maintain a coverage checklist with each surface marked **Updated**, **Verified**, or **Blocked**. A blocked or unverified surface is not complete. Do not silently omit anything.

- [ ] Shared tokens and components replace conflicting one-off designs.
- [ ] Every applicable page follows the same visual standard.
- [ ] Every table header, row, and skeleton uses the same column structure.
- [ ] All row actions are icon-only, accessible, and centered under Action.
- [ ] Relevant date ranges and presets work consistently.
- [ ] Empty tables use the correct conditional reset wording and behavior.
- [ ] No redundant action buttons remain.
- [ ] All modal headers and footers follow the standard.
- [ ] Spacing, typography, borders, padding, and alignment are uniform.
- [ ] Long content, large amounts, missing values, and multiple actions remain readable.
- [ ] Populated, empty, filtered-empty, loading, refreshing, error, validation, and disabled states are checked.
- [ ] Desktop, tablet, and mobile layouts are visually verified.
- [ ] Keyboard navigation, focus states, and contrast are verified (Section 12.7).
- [ ] Permissions, business logic, data, and existing workflows are preserved.
- [ ] Relevant automated checks pass; print/export behavior is verified where applicable.

**Completion rule:** Do not claim the entire application is uniform based on one updated page, a successful build, or syntax checks. Report the files changed, surfaces covered, actual verification performed, and every remaining blocker. No skipped design is acceptable under a claim of completion.
