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

### Members reference controls (approved October 25, 2026)

Event guest tools use the shared modal, search, select, date, switch and field
components. With migration 1690, only `events.admin_roster` exposes guest write
controls. Draft, Open and Closed event details expose Guest Registration; enabled
events expose Add Guest and Add Existing Player. Open and Closed events expose
Register Guest without reopening public registration. Undrawn requested/confirmed
guest entry rows expose icon-only Move Division and Replace Players actions with
accessible labels. Their modal requires a reason and explains payment ownership;
only eligible undrawn destinations appear. Waitlisted and drawn rows retain their
existing workflows.
Registration rows label guests and show partner names as subtext. The payment row
action submits a receipt for normal review; the Payments table identifies the
guest payer and Event Registration source without exposing guest contact data.

Division tables reuse the Members identity cell: round icon, emphasized name,
and smaller muted details. Format names stack above scoring-rule subtext using
the shared table stack. Keep shared row density, status badges, and icon actions.

The Events directory includes a Template column showing the event's default
format template, “Not set” when none is selected, or “Unavailable template” when
the saved template cannot be read. Show the full template name on one line without
an ellipsis; give this column space from the flexible Event column.

Staff and Roles reuses the Members summary cards, full-width search with counted
view pills below it, avatar initials with member IDs, status badges, and icon-only
row actions. Its permission reference cards use two columns on desktop and one
on mobile.

Member Events presents open tournaments using executive summary panels with an embossed
gold trophy badge, uppercase eyebrow, schedule, venue court grid, and fee metadata tiles.
Division tables use trophy avatar badges (emerald when eligible, gold when restricted),
format/gender/category tags, tabular capacity progress meters, and structured restriction
alert callouts for ineligible ranks or categories. On mobile, divisions render as responsive
cards with top-aligned identity and status, structured restriction notices, and full-width
bottom capacity/actions without empty layout gaps.

The Members table shows the current category and rank in the Rank column (or
Unranked), with the membership date as muted “Member since” subtext. Both membership
and added dates use the shared `formatDate()` display (for example, Oct 27, 2026). Members
without a joined date show “Not joined yet”.

The current Members page is the reference for comparable controls. Retain the
existing green, gold, and semantic colors and shared font; buttons are flat and
have no shadows. Use `ui.js` components rather than new page-specific controls.

- Tables: one column schema drives headings, records, and skeletons. Text aligns
  left, money right, and actions center. Use the shared horizontal-scroll wrapper
  on desktop and the shared labelled row layout on mobile. Stack primary and
  secondary text with a 2px gap. Keep every grid header at 49px high (48px cells plus the divider); pagination uses the same height. Keep Action on one line and reserve at least 88px for its heading and controls.
- Badge contents are centered horizontally and vertically, including text, icons
  and status dots. Reuse the shared alignment for status, identity, counters and
  public-page badge variants; retain their semantic colors and size variants.
- The admin Courts list uses Court, Type, Status, Notes and Action columns. Notes comes from the saved court record, keeps line breaks, wraps long text, and shows a dash when empty. Shared search includes note text; headers, records and loading skeletons share this schema.
- All grid pagination uses `DEFAULT_PAGE_SIZE` (10) from the shared pagination
  module, including server query ranges and local slices. Hide the complete
  footer when the filtered total is zero; the table empty state explains the
  result. With records, show the range, total and page size in a compact footer.
- Settings uses the full available admin content width, including wider desktops, with no page/body/card width cap. Nine balanced tabs share the desktop width and scroll horizontally on smaller screens. Panels reuse the flat emerald surface, 44px gold section icon, eyebrow/title/subtitle and option count. Switches occupy full-width rows with aligned icon, title/status, description and toggle. Regular fields use two columns on desktop and one on mobile; lone/odd final fields fill the row. Fixed values use matching read-only field surfaces. Payment methods use four equal selectable tiles, two on mobile. A labeled optional Reason for Change section precedes a compact footer with live unsaved-change count and Discard/Save actions. Hide empty status rows; retain validation, audit reasons and retry-safe saves.
- All shared grids default to 10 records per page, including grids without search. Views with an external/server pager explicitly set `pageSize: 0` to avoid duplicate pagination.
  Filter the full list before paging; reset to page one when search changes,
  retain the current page on refresh, and clamp it when records are removed.
  Categories, Courts, opening hours, rates and blackouts use 10 records per page.
- Row actions and pagination: 36px square, 10px radius, 17px icons, and 8px action
  gaps. Provide an accessible action label and tooltip; use semantic colors.
  Declare `actionCount` for conditional actions so loading reserves their width.
- Compact forms may use the shared `form-grid` two-column layout, stacking on
  mobile. Use `inputWithIcon` to decorate existing input/dropdown/textarea
  controls without replacing their native references or validation. Use the
  shared switch for boolean settings and preserve its submitted field name.
- Dropdowns: `selectField` for new fields; `selectControl` for existing native
  select references. Both use the searchable, keyboard-accessible component.
  Preserve native field names, validation, disabled state, and change callbacks.
- Search and list-status filters sit outside the bordered grid, in one shared
  toolbar. Use `tableFilter` for searchable status selections; pass its host as
  `dataTable({ filter })` to place it beside search. The shared grid layout owns
  a separate toolbar and table panel. Existing full-list searches remain outside
  their grids. Court schedule sections and tournament stages retain navigation.
- Data grids include search by default, filtering their displayed data with a
  clearable no-results state. Do not show a record count beside search. Pass the page-owned
  `searchState` object to retain the query through refresh, and a distinct
  `searchKey` for separate nested lists. Set `searchable: false` only when an
  existing external search already filters the full dataset before pagination.
  Grid rows have a shared 72px minimum height; ordering columns are 80px wide,
  while descriptions receive the remaining width. Filtered rows retain one
  separator, with no duplicate borders around the integrated search/header.
- Searches: `searchControl` returns the input for existing handlers and renders
  the shared search icon and clear action. Clear is hidden when empty and rotates
  on hover, with reduced-motion support.
- Rank management uses responsive category cards, shared identity icons and
  compact rank rows with grouped actions. Keep the full ladder visible inside a
  matching category so search never changes the rank order used for movement.
  Search, category and view filters sit above the content; movement rules use
  the shared grid and 10-row pagination. Rank and rule dialogs reuse icon fields,
  compact form grids, switches and decision callouts.
- Scoring-rule dialogs group Match scoring and Tiebreak order into balanced
  `form-section` panels within the shared compact form grid. Panels stack on
  mobile; every field uses the shared icon input or searchable dropdown.
  Retain numeric constraints, optional caps and the saved tiebreak order.
- Role-assignment dialogs use the shared member-selection panel, searchable
  icon role selector and counted audit reason. Empty search/preview containers
  must not reserve space. Preserve radio selection, self-assignment restrictions,
  submitted field names and the reason requirement in both assignment/change flows.
- Calendar popups use a 320px viewport-safe width independent of the trigger,
  seven equal weekday/day columns, and 36px navigation, date, preset and
  month/year controls. Keep the month/year heading on one line. A single date
  has four rounded corners; only range endpoints use connected range styling.
- Dates, modal actions, empty states, and pagination reuse `dateField`,
  `dateControl` (native-form adapter), `openModal`, `dataTable`, and `pagination`. Specialized calendar and tournament
  layouts retain their workflow while using the same controls.

## 2. Design tokens

Display the format name as **Split Single Elimination** everywhere. Use the shared `formatTemplateLabel()` for saved template names so legacy capitalization and H/L suffixes do not appear in labels.

The landing member strip shows a fresh random selection of up to 15 active members on each welcome-page open or refresh. It uses circular, overlapping uploaded photos with `object-fit: cover`; the same circles show initials if no usable photo exists, including image-load failures. Circles shrink proportionally to fit mobile widths; an empty club has no placeholder avatar. Keep the full active-member total beside the strip.

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
| Table cell padding | Desktop/tablet (>720px): 8px vertical, 18px horizontal, minimum 56px data rows growing with content. Mobile retains its original row and card spacing. |

Admin routes share the Members Directory layout through `.admin-reference-page`: 1380px maximum content width, 24px section gaps (16px on mobile), 18px KPI gaps, and 12px between search and status pills. Desktop headers use 16px × 20px padding, a 128px club logo, 32px title, and 14px description. Page-specific controls retain their functions and column definitions.

Use comfortable spacing, not excessive empty areas or compressed controls. Allow browser zoom and user text scaling. Do not disable zoom to make a layout fit.

## 3. Color, hierarchy, and readability

- Separate page background, raised panels, inputs, and hover states using subtle surface differences.
- Use the shared forest-green palette with champagne-gold accents. Primary actions use green with white text; accent actions use gold with dark-green text. Tokens in `web/styles.css` are the source of truth; the Components palette reads their current values. Reserve status colors for success, warning, error, and information.
- Never communicate meaning through color alone. Add a text label or recognizable icon.
- Keep primary text clearly readable; do not use faint text for essential values or instructions.
- Maintain at least 4.5:1 contrast for normal text and 3:1 for large text and meaningful control boundaries.
- Use restrained shadows and gradients. Avoid unnecessary glow, animation, excessive bold text, and decorative clutter.
- Use plain-language labels, consistent capitalization, and specific action verbs.

## 4. Page composition

- Admin pages use a plain sidebar and content layout, without the public top header or Home/Courts/Events links. The sidebar has no internal scroll area; long navigation uses document scrolling. My profile, Change password, and Sign out live in the sidebar account menu. On mobile, the Menu button opens the same sidebar. The dashboard separates approval requests from club activity; existing control styles and colors are retained.

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

- Reusable button design: `web/buttons.css` is the sole owner of `.btn` appearance and states, using a flat finish without gradients or shadows. `button()` and `iconButton()` in `web/ui.js` and modal actions share `buttonClasses()` from `web/lib/buttons.js`. Use semantic variants (primary, secondary, accent, danger, warning, success, info, archive, restore, edit, outline, ghost, link); page CSS may control layout and width but must not override their flat finish. Default text buttons are 46px high with 12px corners; small and icon buttons are 36px with 10px corners. Pagination uses the same icon size. Large buttons are 48px. Header/menu/calendar controls retain their specialized layout, with the same flat finish. No button may add a gradient, box shadow, or text shadow in any state.

- Use shared primary, secondary, destructive, and icon-button variants with consistent dimensions.
- Pagination and table row actions keep their compact, flat finish in `web/buttons.css`, with 36px buttons and 10px corners; all other buttons also use solid fills without shadows.
- Define default, hover, focus-visible, active, disabled, and pending states for every interactive component.
- During submission, prevent duplicate actions and show clear progress without moving surrounding content.
- Device-alert settings offer activation only when browser support and an active service worker are available, including localhost previews (which bypass shell caching). Failures distinguish browser permissions, notification-service connectivity (including Brave's push messaging setting), sign-in, device limits, and server registration; never show device keys or endpoints.
- All row action buttons must be icon-only. Provide a specific tooltip and accessible label, such as "Edit record" rather than just "Action".
- Page actions and modal submission buttons retain readable text labels; the icon-only rule applies to row actions, not every button.
- Use persistent field labels. Placeholders supplement labels; they do not replace them.
- All new single-choice dropdowns use `selectField()` or `searchableSelect()` from `web/ui.js`; both provide the same searchable dropdown, animation, keyboard controls, disabled options, and native form validation. Supply an `id` and a label (or `ariaLabel`). Update existing controls with `.setOptions(options)` and `.value = selectedValue` instead of rebuilding them or styling native selects separately. `onChange` receives the backing select's change event; `onSelect(value, option)` is also available. Shared styles live in `web/styles.css`.
- Place validation messages beside the affected field and preserve the user's entered values after an error.
- Use the same dropdown and datepicker styling everywhere, including controls added dynamically.
- Custom controls must support keyboard use, visible focus, correct roles, and expanded/selected states.
- Use one compact badge style with consistent height, padding, radius, text size, and semantic colors.
- Status badge labels stay on one line. Reserve enough column width for the longest label and let event names wrap to accommodate it.
- Unread notification counts use red circular badges with white text (99+ maximum). On mobile, the count overlaps the upper-right edge of the floating navigation circle and also appears beside Notifications in the menu. Hide unread badges at zero.
- The floating Quick Menu omits QR Pass for both members and visitors.
- Profile and Member Details share a Rank Assessment card with two equal-width summary tiles with matching emerald surfaces, borders, spacing and 21px rank text: saved/club-assigned assessment and official CPC rank. Club/admin assessments load automatically; saved member assessments are static read-only summaries with provenance and an admin-only update notice. Fresh submissions use a searchable rank selector and one Save Assessment action with a clear one-time-save note. Authorized admins get correction controls and a required reason. Show Reload Assessment only after conflict/access errors, Retry after load failure, and omit absent notes entirely. Mobile stacks the tiles and uses full-width actions. Saving profile details does not submit the assessment.
- Record lists use a full-width search with wrapping status badges 12px below it, rather than a status dropdown. Use `tableFilter()` for these badge groups; show counts for every record category and default missing or unavailable counts to zero, including while loading. Keep form and category selectors as searchable dropdowns.

## 6. Grid tables and column content

- Header, populated rows, and skeleton rows must use exactly the same column definition.
- Distribute ordinary data columns equally across the available width. Reserve a compact, consistent width for Action based on its button count.
- Any necessary exception for long content must be defined in a shared table schema and applied identically to its header, rows, and skeleton—not as an isolated inline override.
- Shared dropdown lists, action menus, date and date-time calendars use `dropdownPosition()` from `web/lib/dropdown-position.js`: open above when space below is insufficient, respect viewport and scrolling-modal bounds, and constrain tall panels with internal scrolling. Reposition on scroll, resize, and mobile keyboard changes.
- Center the Action heading and all action icons beneath it. Keep action-button gaps consistent.
- Left-align text. Right-align money and numerical amounts, including their headings. Use tabular numerals.
- Keep quantities, currency, and dates consistently formatted. Do not wrap a currency label separately from its amount.
- Always render data beneath a primary value as subtext: use the shared `.sub` class for smaller, muted text with a 2px gap. This includes dates, times, member IDs, booking references, and supporting notes.
- Shared event summary details appear as Schedule, Registration Window, Entry Fee, Divisions, Format Template and Venue. On desktop, Registration Window and Venue span two columns; Entry Fee occupies the top-right slot. Mobile follows the same reading order.
- Public event panels use deep green shading, a restrained gold border, a 56px trophy emblem and a larger event title. Group metadata in one inset panel with flat cells, muted labels and gold icons; highlight Entry Fee in gold. Division cards use subtle surfaces, smaller muted `.sub` text, tabular entry counts and capacity bars. Separate the Divisions heading and registration footer with fine rules, keeping the established mobile title/status layout and full-width mobile actions.
- The public Members directory shares the staff Members name formatter and shows the saved CPC member number below the name using `.sub.member-subtext`; never substitute an internal database ID or guess missing name parts.
- Public court cards use the matching green gradient and a 48px gold court icon. Keep Indoor/Outdoor as a setting badge, show operating hours at full width with smaller muted `.sub` day information, and put surface on one simple row. Avoid repeated surface text and nested detail boxes. The full-width Reserve Court action uses the shared primary button with calendar and chevron icons, at least 44px high. Loading cards retain the same structure.
- Court cards show two count-only statistics, Vacant Today and Occupied Today, above Reserve Court. Display unknown counts as a dash rather than zero. Public and member booking cards show saved court notes as a subtle info callout with smaller muted `.sub` text, preserved line breaks and safe wrapping; hide it when notes are blank. The court editor identifies notes as visible on these cards.
- Place the public membership indicator at the right of the card header, vertically centered with the player's name and CPC number. Both indicators use a 28px solid primary-green circle with a white icon: a check for Active and a clock for Not Active. Keep a 2px gap between name and CPC number. Keep accessible status labels and title tooltips, and hide the badge's decorative dot. Status comes from the server's active-membership boolean.
- Public Members uses compact pagination at 600px and below: centered record count above Previous, three nearby page numbers and Next, with 40px controls. Let the footer grow to contain both rows. Use the same shared 20px plus safe-area bottom spacing as member Home, without extra page padding. Desktop retains five numbered page links; the current page stays visible at either end of the list.
- Public member cards use a subtle green gradient, a 48–56px portrait with a fine gold ring, readable wrapping names and muted monospaced CPC numbers. Category and CPC Rank share a flat details row with small gold icons and existing badges, separated from the identity by one subtle rule. Avoid nested bordered tiles and movement on hover; match skeleton sizing and respect reduced motion.
- On desktop and tablet (>720px), vertically center each cell's content group, identity icon, and row actions; keep stacked primary and secondary text together.
- My Bookings lists bookings by scheduled date and time, newest first, in both Upcoming and Past and Closed. Creation time and ID break ties consistently.
- My Bookings uses the shared animated court pattern on mobile and desktop, including empty states. The pattern sits behind controls, responds to mouse/touch, and remains static when reduced motion is requested.
- The shell fills in the same animated pattern on every routed page that does not already provide it, without adding duplicate canvases. Shared non-home mobile headers apply across member and admin pages; desktop page headers retain a bordered container. The public landing and Home keep their existing welcome presentation.
- Events, Ranking, Notifications, Brackets, and Leaderboard/Results use `memberHero()` directly, matching Book a Court and My Bookings with Manila date and page-specific section chips on both screen sizes.
- Admin headers, including the admin dashboard, follow the same CPC-logo sizing, title/role grouping, Manila date chips, and spacing as member headers. Keep admin labels and actions, use a bordered container on desktop, and an unboxed centered layout on mobile.
- My Bookings retains the bordered hero container on desktop (above 720px); its mobile header stays unboxed with balanced spacing around the photo.
- On mobile, My Bookings places the Play badge beside its title and presents each booking as a card: court and time, status, price and payment, then accessible icon actions. The booking reference appears below the price, in a compact 170px Price column on desktop. Free bookings show a No Charge payment badge with Complimentary beneath it.
- My Bookings is ordered by booking number descending, with the highest booking number first, on desktop and mobile.
- The member Home welcome shows the personal header photo (128px on desktop, 144px on mobile), using the private signed image URL or initials. Other member page headers match the landing CPC logo size (72px desktop, 54px tablet, 96px phone) with an 8px mobile gap below the logo; Profile retains its photo editor. Member desktop headers, including Home, use the bordered hero container; mobile headers remain unboxed.
- Non-home mobile pages share a centered header: title beside section badge, description, Manila date and section chips, then full-width actions. Use matching 16px gaps between the header copy and actions and between page sections (including Search). Home dashboards retain their own header layout; desktop headers retain their existing containers.
- Public Courts, Events and Members headers reuse Admin Members' desktop header rules above 720px: 128px CPC logo, 16px/20px container padding, 16px section gap, 8px copy gap, 32px/800 title and 14px description. At mobile widths, remove the container, border and shadow and hide the logo. Keep the existing page-specific chips, descriptions, actions and content-card styling. The navigation shell retains this public logo when visitors are signed out.
- The staff Members Rank column reserves enough width for the membership date. Both Member since and Added dates stay on one line.
- Member lists use compact cards up to 720px: primary icon and title, status badges, labeled details, and an action footer, with 16px gaps between search, filter groups, and records. Table schemas identify primary/status/detail cells for both loading and populated rows. Desktop tables and administrator lists retain their layouts.
- Member Events and Ranking use full-width search above counted pill filters on both desktop and mobile. Events has one shared search across event/division metadata and registrations; Ranking retains its category selector within the filter area.
- Members opens with All selected and server pagination across non-deleted statuses. The Active filter shows active members; row status badges still say Active with Approved as the secondary text for non-deleted active members. Saved status-change reasons remain available in member details/history. Keep status filters and the separate Deleted view. Imported rows show an Imported badge with Not Signed In Yet as secondary text. Names use saved last/first names in Last Name, First Name M. Extension format, with proper case and canonical extensions; fall back to the proper-case Display Name if either first or last is missing. Use the same name in member dialogs and action messages. Sort on the server by surname, then first name, then display name and ID for stable pagination; missing surnames follow named records. Search accepts name words in either order across saved name fields and Display Name. The Members table allocates at least 240px to the flexible Contact column and 180px to Status. Keep desktop email addresses on one line, ellipsizing only when needed and exposing the full address on hover; mobile may wrap long addresses. Header, rows and skeletons use these same schema widths.
- Public Events and member Club Events use the same `web/event-summary.js` component: gold trophy beside the Club Event eyebrow and title, registration/CPC/DUPR badges with 8px gaps, and six metadata tiles (Schedule, Registration Window, Venue, Divisions, Format Template, Entry Fee). Desktop uses a four-column grid with Registration Window and Entry Fee spanning two columns; tablet and mobile use two and one columns. Member details use existing authenticated RLS reads; registration eligibility still comes from `my_event_options`. On mobile (up to 720px), Club Event aligns with the title's left edge and registration status sits immediately beside it above the title; the trophy is hidden so the heading uses the full width and the CPC/DUPR badges sit below, aligned with the event name. The mobile heading uses a 4px gap above the event name and 8px below it. Member summaries balance the space above the detail tiles with their bottom padding: 20px on desktop and 16px on mobile. Desktop keeps the original header arrangement. Skeletons share the summary geometry. Member divisions stay inside the same bordered, rounded event panel below its summary on every screen size, with 16px padding on mobile. Desktop divisions use the shared table with distinct Division, Entries capacity, Status badge, and Action columns; mobile divisions use a modern 3-row card layout: Row 1 features the division identity with squircle trophy avatar and format subtitle on the left, and the status badge aligned top-right, with any ineligibility callout note spanning 100% width below the identity; Row 2 provides a continuous hairline divider across the entire card width; Row 3 balances the Entries capacity block (uppercase tracking label, count, and fluid progress bar) with the 40px action button. If no action exists, the capacity bar smoothly fills the card width. Skeletons and empty states match this exact geometry.
- Member event divisions sort Beginner, Novice, Intermediate, Advanced, then Elite. Within each category, show Men Low/High, Women Low/High, then Mixed Low/High. Divisions without a Low/High label follow those levels within their gender group.
- Member Details Modal in admin uses a compact layout: Membership & Audit features an executive 3x2 grid (Row 1: Membership, Account, Club Ranking; Row 2: Reason on Record, Review Flags, DUPR ID with gold accent badge). Rank Assessment tiles and header paddings are compacted to reduce vertical height and fit profile sections comfortably without tall empty gaps.
- The admin Event Detail view uses an executive top action toolbar (navigation on the left, record and lifecycle actions on the right) above a prominent tournament summary card with gold trophy branding, reference code, status pill, and 4 KPI tiles (Schedule, Venue, Entry Fee, Registration). Below the summary, segmented tab filters switch between Divisions and Registrations tables to prevent stacked duplicate search controls and giant stacked empty states.
- Event Detail groups Guest Registration, Add Guest, Add Existing Player and Register Guest in a separate Player Registration panel with smaller muted subtext. All Events stays in the navigation row beside event controls. Mobile uses two-column button grids with at least 44px touch targets and consistent row heights; permission and event-state visibility rules are preserved.
- Add Existing Player modal in admin Event Detail uses an executive search-and-select flow: header squircle with userPlus icon, secondary search button, debounced live query (250ms), and transitions from a search results list to a dedicated .staff-selected-card preview upon player selection. The preview features a userCheck avatar squircle, bold player name, Member/Guest badge, CPC ID/subtitle, and a Change button to re-open search.
- Events and Ranking desktop rows use the same round icon treatment as My Bookings. Ranking uses a compact 64px position column and places its standard searchable 240px category dropdown to the right of Search on desktop, with pills on the next row. Mobile stacks Search, Category, and pills. Free registrations use the shared green Free badge.
- Ranking cards center the position number without a hash in a gold badge; desktop uses an 80px centered position column and 32px badge. Player names and actual member numbers align left; never derive or invent a member number from a database ID. Category and rank use the shared info/success badges.
- Ranking player rows use private profile photos through signed links, with initials when no image is available. Only active ranked players' images are shared within the signed-in club; the avatar bucket remains private.
- Public Members (#/members) uses executive member cards instead of a traditional table, presenting members in a responsive grid (3 columns on desktop, 2 on tablet, 1 on mobile). The full-width search bar remains permanently above the grid with real-time filtering across name, CPC number, category, and rank. Each card displays a prominent 46px avatar with gold accent ring, bold member name with subtitle CPC number/status, hairline gold divider, and 2 structured metadata tiles for Category and CPC Rank. Skeleton loading matches this exact card geometry with zero Cumulative Layout Shift.
- A cell's content and mobile label must match its column heading. Do not put notes under a heading for status or timestamps under an unrelated heading.
- Use real recorded values. Distinguish zero, unavailable data, not counted, and pending data; do not substitute a misleading zero.
- Allow long names and references to wrap safely. Avoid overlapping cells, clipped actions, and broken amounts.
- Use consistent row separators, hover treatment, row height, and vertical alignment.
- Use semantic table markup where practical. Grid-based tables must retain accessible header/cell relationships.

### Pagination

Shared client-side lists (including My Bookings) show all matching records with
no pagination footer on mobile (up to 720px). Desktop and tablet retain pagination.
Server-paged directories retain their navigation so further records stay accessible.

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
- Keep long modal bodies scrollable and the header/footer reachable. Hide scrollbars in all modals while preserving wheel, touch, and keyboard scrolling. Do not let content extend beyond the viewport.
- Stack fields and actions consistently on small screens; ensure sufficient touch targets.
- The member details Membership & Audit section uses equal status tiles with aligned badge rows, followed by matching reason and review tiles. Stack tiles on mobile and keep the rank action beside its wrapping badge.
- The staff role assignment modal ("Give Someone a Role") dynamically replaces the member search and radio list with a unified Selected Member card upon selection, showing an emerald verified avatar, display name, member ID chip, role badge, and a "Change" button to eliminate redundant duplicate cards.
- The event division registration modal ("Register for Division") presents an executive tournament division summary card with format, category, and fee/capacity badges, followed by a dedicated Doubles Partner panel with real-time member search, candidate cards with active status pills, and dynamic replacement with a unified Selected Partner card upon selection.
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
- Indeterminate progress bars (including app startup and upload bars) use continuous GPU-accelerated translateX transforms with soft alpha-feathered gradient tails and dual-phase emerald/gold illumination, eliminating abrupt rectangular edges, layout jitter, or ping-pong reversals.

## 11. Responsive and accessible interaction

- Verify desktop, tablet, and mobile—not just one screenshot size.
- Preserve all data and actions on small screens. Use a consistent labeled-card pattern or a deliberately scrollable table for dense comparisons.
- Rank history cards on mobile stack three distinct full-width tiers: When (date and medal badge on one line), Rank Change (transition badges with directional indicator), and Why (audit note and event details), maintaining safe bottom clearance for floating navigation.
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
- All toasts share a compact, flat rounded surface with a plain leading icon, vertically centered message, and small dismiss button. Preserve semantic tone colors on the border and icon. Capitalize the first letter of messages and titles without changing acronyms or names.

### 12.8 Responsive design
- Mobile pages (up to 720px) use 20px bottom spacing plus the device safe-area inset, matching sign-in. Avoid adding a second bottom spacer inside a page. Desktop and tablet spacing stays unchanged.
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
