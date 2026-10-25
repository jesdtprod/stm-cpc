# Members control standard rollout

Approved reference: the Members page and the table, alignment, search, dropdown,
pagination, action-button, and modal rules agreed in this conversation.

- [x] Centralize column sizing, money/action alignment, row/skeleton geometry, and table containers.
- [x] Reuse searchable dropdowns in existing forms, preserving names, values, validation, dynamic options, and change events.
- [x] Reuse the icon/clear search control and convert remaining text table actions to accessible icon actions.
- [x] Align shared spacing, borders, pagination, and modal controls; retain specialized calendars and bracket layouts.
- [x] Run regression checks and document page coverage and visual verification limits.

Scope: account/profile, dashboard, Members, Bookings, Payments, Categories,
Ranks, Courts and nested schedules/rates/blackouts, Staff, Import, Events and
divisions/registrations, member events/bookings, Scoring, Brackets, Settings,
and Components. Public hero content and business/database behavior are retained.

Visual review requires a connected browser. Automated component tests do not
substitute for rendered desktop/mobile evidence.

## Coverage and validation

| Surface | Shared controls applied or retained |
| --- | --- |
| Dashboard, Members, Bookings and Payments | Tables, skeletons, action alignment, search and pagination; existing shared cards and modal actions retained |
| Categories, Ranks, Staff and Import | Shared table geometry, icon actions, searches, searchable native-select adapters |
| Courts and hours/rates/blackouts | Searchable selectors, shared date picker with native validation, scroll containers and conditional action sizing |
| Events, divisions and registrations | Shared selectors, date pickers, icon actions and table geometry |
| Member bookings/events and Brackets | Shared searches, selectors, dates, tables and actions; specialized calendar/bracket layout retained |
| Account, Settings and Components | Shared field controls and demonstrations; existing form values and callbacks retained |

Validation: 154 unit tests passed; repository lint, formatting and hygiene passed.
The full secret-scan command remains blocked by four existing password-fixture
matches in unchanged files. No database changes are part of this rollout.

- [ ] Rendered desktop, tablet and mobile review. Computer Use returned no browsers
  or apps because the native pipe is unavailable; source coverage and component
  tests do not establish visual acceptance.
