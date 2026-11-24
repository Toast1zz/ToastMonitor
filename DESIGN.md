# ToastMonitor Design System (`DESIGN.md`)

> Authoritative visual, layout, interaction, and performance constitution for ToastMonitor's native macOS UI (`Sources/ToastMonitor/UI/`). Any UI edit—whether authored manually or by an AI coding agent—must satisfy these rules and pass visual screenshot inspection before completion.

---

## 1. Platform & Visual Philosophy

- **Native macOS First (macOS 13–27)**: Built with AppKit window/panel chrome (`NSWindow`, `NSPanel`, `NSToolbarItemGroup`, `NSSegmentedControl`, `NSVisualEffectView`) hosting SwiftUI views. Production builds compile with `--build-system native` (`scripts/build-app.sh`) so macOS 26/27 serves native Liquid Glass geometry.
- **Quiet Tonal Hierarchy**: No web-style card borders, heavy shadows, neon gradients, or decorative clutter. Hierarchy comes from tonal surface steps, aligned tabular numerals, generous whitespace, and restrained semantic accents.

---

## 2. Hard Redlines (Non-Negotiable)

### 2.1 Surfaces, Cards & Corners
- **No Card Borders**: Separate `DashCard` and `PopoverCard` surfaces from `TMDesign.canvas` solely by tonal fill (`TMDesign.surface` / `Color.primary.opacity(0.055)`). **Never** add `.strokeBorder` / `.border` around cards—including colored error outlines.
- **Continuous Squircle Corners**: Use `style: .continuous` (`CALayerCornerCurve.continuous`) on every rounded container, bar, pill, and `FloatingPanel` (`PanelSurfaceView`).

### 2.2 Typography (`TMDesignSystem.swift`)
- **SF Pro Only for UI Copy**: Use `TMType.*` (`SF Pro`). Never use `.monospaced` (`design: .monospaced`) for UI labels, capsules, or status pills (code/API-key inputs in credential sheets are the sole exception).
- **Tabular Numerals Everywhere**: Every dynamic figure—tokens, money, percentages, counts, countdowns, and timestamps—must apply `.tmMonospacedDigit()` (or `TMType.number(...)`) so live refreshes never jitter layout width.
- **No Mixed Scales in Data Columns**: Never place text labels (such as plan names like `"Free"` or `"Gemini AI Pro"`) inside large numeric figure columns (`FigureColumn` / `DashMetric` value slots). Plan tiers belong as a quiet 1-line subtitle (`TMType.micro`) under the card title.
- **Never Truncate Card Headers**: Do not cram capsule badges onto the same horizontal line as a card title and trailing timestamp (`Just now`). Keep the title + subtitle stacked on the left and status/refresh flush-right.

### 2.3 Color & Semantic Restraint
- **Accent & Semantic Palette**:
  - Primary product accent: `TMDesign.accent` (warm copper-orange).
  - Semantic states: Quota progress bars and percentage readouts keep their calm base service color and `.primary` text at every usage level (high usage is indicated by the subtle warning icon, never by turning bars or numbers red/orange); reserve `TMDesign.danger` for actual errors and expired sessions, and `TMDesign.warning` for stale indicators and warning icons.
  - Brand colors (`ToolKind.*.color`, `TMDesign.*`) must remain consistent across Popover, Dashboard, and Settings (e.g., OpenCode Go always uses `ToolKind.opencode.color`).
- **Keep Normal States Neutral**: Healthy states stay neutral (`TMDesign.quiet` / `.primary`); color is reserved for brand marks, charts, and actionable anomalies.

### 2.4 Layout, Grids & Alignment
- **Uniform Grid Card Heights**: All cards in a `LazyVGrid` section (e.g., `PlansView` quota cards) must share a single explicit `.frame(height: ...)` so rows never look staggered.
- **Flush-Right Trailing Alignment**: Never reserve invisible fixed-width placeholders (e.g., `.opacity(0)` buttons) next to `"Just now"` or trailing values—swap `"Just now"` ↔ `↻` in place on hover so right edges align with percentages below.
- **Shared Multi-Row Metric Columns**: Stacked rows inside a shared card (such as `Balances`) must align metric columns (`Balance`, `Today`, `This month`) vertically across rows.
- **Keep Popover Compact & Uncluttered**: Never squeeze Dashboard tables or multi-line prose into the menu-bar popover; keep `DashMetric` labels single-line (`.lineLimit(1)`).

### 2.5 Popover-Specific Rules (`PopoverRootView.swift`, `PopoverHomeView.swift`, `FloatingPanel.swift`)
- **No Visible Scrollbars in Popover**: Always use `ScrollView(.vertical, showsIndicators: false)` paired with the bottom fade `.mask`—never attach `.overlayScrollers()` to the main Popover scroll view.
- **Immediate Visibility Sync**: `@State` visibility flags (`quotaRowHidden`) must be initialized synchronously in `init` from `Database.shared.setting` (backed by in-memory `settingsCache`) and refreshed on `TMNotifications.popoverVisibility` transitions—never wait solely for `.onAppear`.
- **Single-Line Header Status**: Keep `PopoverRootView` header error/stale status single-line (`.lineLimit(1)`) and clickable to jump directly to `Settings › Sources`.

### 2.6 Errors & Settings Deep-Linking (`RowProblem.swift`, `SettingsWindow.swift`)
- **Human-Readable Errors via `RowProblem`**: Always map raw client errors (including HTTP 302 redirects, 401/403, expired sessions, offline errors) through `RowProblem.from(service:error:accountKey:)`. Never expose raw HTTP status codes or verbose multi-line essays inside dashboard cards—keep card errors to a concise 1-line title with full detail in `.help(...)`.
- **Account Deep-Linking & Honest Status**: `"Open Settings…"` must call `SettingsWindowController.shared.show(pane: .accounts, expandAccount: key)` to open and expand the exact account. `Settings › Accounts` must surface `"Error"` / `"Sign-in expired"` in `TMDesign.danger` whenever a configured account has an active error.

### 2.7 Frontend Performance & State Hygiene
- **Zero Synchronous SQLite Queries in `body`**: SwiftUI `body` and computed view properties must never query `Database.shared` for aggregates or series (`openRouterSpend`, `orCreditUsage`, `deepSeekBalances`, etc.). Preload them into `UsageQueryService.LightSnapshot` and expose in-memory helpers on `AppState`.
- **Isolate High-Frequency Hover State**: Keep `hoveredDay` / `hoveredModel` inside leaf subviews (e.g., `ActivityHeatmapCard`, `PopoverHeatmap`, `TrendChartView`) and render large grids (371-cell annual heatmap) with `Canvas`.
- **Gate Background Work on Visibility**: Inactive Dashboard tabs (`dashboardActiveTab`) and hidden Popover panels (`panelVisible`) must pause periodic timers and polling loops.
- **Strong View Identity**: Never use `[AnyView]` + `id: \.offset` in `ForEach` for dynamic grids.

---

## 3. Mandatory Visual Verification Workflow

After **any** frontend/UI change, verify both code health and rendered pixels before finishing:

1. **Run UI & Regression Unit Tests**:
   ```bash
   swift test --filter "DashboardWindowTests|SettingsWindowTests|UIStateTests|PopoverHeatmapTests|QuotaWindowTests|RowProblemTests"
   ```
2. **Render Screenshots (Light & Dark)** using `--build-system native` (never plain `swift build`, which records a legacy SDK version and disables Liquid Glass bezels) and an isolated `TM_DATABASE_PATH`:
   ```bash
   # Build with native engine so Liquid Glass renders accurately
   swift build --build-system native

   # Full baseline comparison suite (Light & Dark across Overview, Analysis, Plans, Sessions, Popover, Settings)
   swift scripts/visual-regression.swift compare

   # Or render targeted surfaces directly (always isolate TM_DATABASE_PATH):
   TM_DATABASE_PATH=/tmp/tm-visual.db .build/out/Products/Debug/ToastMonitor --demo --show-dashboard --tab plans --appearance light --capture-dashboard /tmp/plans-light.png
   TM_DATABASE_PATH=/tmp/tm-visual.db .build/out/Products/Debug/ToastMonitor --demo --show-panel --appearance light --capture /tmp/popover-light.png
   TM_DATABASE_PATH=/tmp/tm-visual.db .build/out/Products/Debug/ToastMonitor --render-settings /tmp/settings-accounts.png accounts
   ```
   *(Inspect the generated PNGs directly via `read_file` to verify visual quality with your own eyes.)*

### Pre-Ship Visual Checklist
- [ ] **Zero Truncation**: No cut-off card titles, subtitles, button labels, or hover callouts.
- [ ] **Edge Alignment**: Trailing `"Just now"` / `%` / currency figures align cleanly on the right edge across rows and cards.
- [ ] **Uniform Card Geometry**: All cards in a grid row share identical height; no awkward blank grid holes.
- [ ] **No Card Borders & No Popover Scrollbar**: Cards separate cleanly by tone; Popover shows no scrollbar when overflowing.
- [ ] **Both Appearances**: Legible contrast and harmonized colors in both Light and Dark mode.
- [ ] **Hidden Accounts Respected**: Accounts toggled off via `"Show in popover"` do not appear in the Popover.
