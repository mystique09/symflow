# Symphony Horizontal Operations Board Design

Date: 2026-07-23

## Goal

Replace the dashboard's vertically stacked runtime tables with a read-only
horizontal operations board inspired by Linear and GitHub Projects. Running,
retrying, and blocked work should be visible together without changing
Symphony's runtime model or becoming a project-management interface.

## Scope

The change is limited to the human dashboard returned by `GET /`. Existing JSON
routes, refresh behavior, view-model data, orchestration state, tracker
behavior, and runtime semantics remain unchanged. The page remains
server-rendered by V and `veb`, uses the vendored Bulma stylesheet, and requires
no JavaScript or external assets.

## Layout

The page retains:

1. The compact Symphony brand header and service-live indicator.
2. A reduced overview header with the page title, short description, and
   operational metadata.
3. A quiet engineering-preview footer.

The three duplicate summary cards are removed. Their counts move exclusively
to the corresponding board-column headers.

The board contains exactly three columns in this order:

1. Running
2. Retrying
3. Blocked

On wide screens, all three columns share the available viewport width. The
dashboard no longer uses the current `1180px` content cap. Each column has a
practical minimum width so cards stay legible. At narrower widths, the board
remains one horizontal row and becomes the page's only horizontal scroller.
Mobile columns occupy most of the viewport and use scroll snapping to preserve
the board mental model instead of reverting to a vertical stack.

## Ticket cards

Each runtime entry becomes one compact card inside its state column. Cards use
the existing safe issue link and show state-specific information:

- Running: issue, tracker state, attempt, turns, last event, and tokens.
- Retrying: issue, attempt, next due time, and bounded last error.
- Blocked: issue, tracker state, attempt, and bounded reason.

The three card types share the same shell and spacing but do not force unrelated
fields into an identical schema. Labels and values use definition-list
semantics where appropriate. Long event and error text wraps inside the card
without widening the column.

Each empty column renders a compact explanatory message inside the column body.
Empty states do not reserve table-row height or use table `colspan` markup.

## Visual system

The existing cream, navy, green, amber, and red identity remains. State color
is limited to column headings, dots, count tags, and status labels. Columns use
quiet borders and surfaces; ticket cards use a second surface layer without
wide decorative shadows.

The stylesheet gains a small 4-point spacing scale and applies it to the board,
columns, headers, cards, metadata, and responsive gaps. The oversized hero
heading and redundant status-card emphasis are removed so operational work
becomes the strongest visual layer.

## Accessibility and resilience

- The board is a labelled region containing three labelled status sections.
- Ticket collections use list semantics, and each ticket remains a distinct
  article.
- Issue links retain visible keyboard focus.
- Horizontal overflow remains reachable by keyboard, trackpad, touch, and
  browser zoom.
- Status is communicated with text in addition to color.
- Existing `<time>` elements and HTML-escaping boundaries remain intact.
- The page remains fully useful without JavaScript.

## Interaction boundary

The board is read-only. It does not implement drag-and-drop, ticket editing,
status mutation, filters, add-item controls, or tracker transitions. Running,
retrying, and blocked are orchestrator runtime states, not a mutable tracker
workflow. Any future tracker-status board would be a separate feature with
provider-specific mutation and authorization requirements.

## Architecture

`symphony/statusweb/templates/index.html` owns the semantic board and card
markup. `symphony/statusweb/assets/symphony.css` owns the horizontal layout,
spacing tokens, responsive overflow, and scroll snapping.

`symphony/statusweb/app.v` continues to build the existing presentation-only
view model. No new route, endpoint, DTO, tracker method, or client-side data
flow is introduced.

## Verification

Focused HTTP tests will assert:

- The three board columns and card-list markers are rendered.
- The old summary-card and table markers are absent.
- Running ticket fields and all three compact empty states render correctly.
- Safe issue links, unsafe-link rejection, escaped dynamic text, local assets,
  and semantic `<time>` output remain unchanged.

CSS and live-browser verification will cover all three columns at desktop
width, board-level horizontal scrolling at tablet width, scroll snapping at
mobile width, long-message wrapping, keyboard focus, and empty columns.

Final verification runs V formatting, vet, the focused status-web tests, the
complete V test suite, a production build, and an embedded-asset smoke test.

## Non-goals

- No drag-and-drop or tracker mutation.
- No complete backlog or terminal-ticket browser.
- No changes to JSON APIs, refresh behavior, scheduler, tracker, or
  orchestrator state.
- No auto-refresh or client-side state management.
- No theme switcher, dark theme, or external asset pipeline.
