# Graph Report - ToastMonitor  (2026-08-15)

## Corpus Check
- 86 files · ~288,523 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 1443 nodes · 3546 edges · 82 communities (71 shown, 11 thin omitted)
- Extraction: 90% EXTRACTED · 10% INFERRED · 0% AMBIGUOUS · INFERRED: 342 edges (avg confidence: 0.81)
- Token cost: 8,700 input · 2,900 output

## Community Hubs (Navigation)
- Popover Views & Bindings
- URL Session Networking
- Dashboard Window & Toolbar
- Keychain Credential Storage
- SQLite Database Layer
- Design System & Styling
- Cost & Token Aggregation
- Popover Root & Configuration
- Plans View & Credentials
- Source Health Monitoring
- Daily Aggregates & Breakdowns
- Hermes Remote Client
- Date & Number Formatting
- Repo Docs & Contribution
- Backup & Data Maintenance
- Settings Views & Sections
- Usage Query Service
- DSH Session Log Parsing
- Feed Import & Settings
- Database Backup Tests
- App Delegate & Status Bar
- File Scanning & Caching
- Overview Heatmap & Periods
- Collector Engine Scheduling
- Floating Panel Window
- DSH Parser Tests
- Forecast & Subscription Math
- System Framework Imports
- Session Totals & Cache Scan
- Tool Kind Identity
- Update Manager Checks
- Test Suite Modules
- Update Check Networking
- Usage Analysis Views
- Aggregation Rows & Grouping
- Metric & Period Enums
- Codex Parser Tests
- OMP Parser Tests
- Health Status & Month Axis
- Heatmap Grid Rendering
- Claude Code Parser Tests
- Response Handling & Limits
- Dashboard Sections & Headers
- UI Framework Imports
- Crash Handler & Main
- Sources View Rows
- Popover & UI State Tests
- Pricing Model Tests
- Codex Session Parsing
- Redesigned UI Screenshot
- File Scanner Tests
- OpenCode Parser & Model IDs
- Update Error Handling
- Redirect & Download Delegates
- Dashboard UI Screenshots
- Panel Surface Rendering
- Event Identity & Digests
- Model Pricing & Estimation
- Network Boundary Tests
- Hermes Parser & Sessions
- App Icon 1024 Concept
- App Icon 32 Concept
- Appcast Manifest Keys
- Update Checker Tests
- Icon Retina Size Family
- Iconset 128 Family
- Icon 16@2x Palette
- Icon Bread & Chart Motif
- Icon 512@2x Concept
- Icon Source Artwork
- App Lifecycle & Reopen
- Icon 16 Concept
- Icon 32@2x Concept
- Icon 512 Concept
- Credential Targets
- Icon 256 Concept
- Code of Conduct
- Swift Package Manifest
- Keychain Auth Script
- Build Script
- Release Packaging Script
- Update Signing Script

## God Nodes (most connected - your core abstractions)
1. `Database` - 120 edges
2. `ToolKind` - 51 edges
3. `AppState` - 48 edges
4. `PopoverHomeView` - 47 edges
5. `PlansView` - 36 edges
6. `UsageAnalysisView` - 35 edges
7. `DatabaseTests` - 34 edges
8. `TurnRecord` - 32 edges
9. `OverviewView` - 32 edges
10. `OpenCodeGoClient` - 31 edges

## Surprising Connections (you probably didn't know these)
- `Feature Request Constraints` --semantically_similar_to--> `Zero Third-Party Dependency Constraint`  [INFERRED] [semantically similar]
  .github/ISSUE_TEMPLATE/feature_request.yml → CONTRIBUTING.md
- `Feature Request Constraints` --semantically_similar_to--> `Local-Only Privacy Default`  [INFERRED] [semantically similar]
  .github/ISSUE_TEMPLATE/feature_request.yml → README.md
- `Pull Request Template` --semantically_similar_to--> `Zero Third-Party Dependency Constraint`  [INFERRED] [semantically similar]
  .github/PULL_REQUEST_TEMPLATE.md → CONTRIBUTING.md
- `Feature Request Issue Template` --references--> `Data Semantics Document`  [INFERRED]
  .github/ISSUE_TEMPLATE/feature_request.yml → docs/data-semantics.md
- `Security Policy` --references--> `Remote Feed Validation Rules`  [INFERRED]
  SECURITY.md → README.md

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Privacy-First Constraints Across Contribution Surface** — readme_local_only_privacy, _github_issue_template_feature_request_constraints, contributing_keychain_credentials, security_policy [INFERRED 0.85]
- **Migration Data-Safety Strategy** — docs_migration_protected_backup, docs_migration_user_version, _github_workflows_ci_migration_replay_gate [INFERRED 0.85]
- **Token Accounting Semantics** — docs_data_semantics_token_semantics, docs_token_collection_token_total_formula, docs_token_collection_dedupe_chain, docs_token_collection_delta_baseline [INFERRED 0.85]
- **App Icon Composition Elements** — artifacts_toastmonitor_icon_toastmonitor_1024_app_icon, artifacts_toastmonitor_icon_toastmonitor_1024_bread_slice, artifacts_toastmonitor_icon_toastmonitor_1024_toast_logo_mark [EXTRACTED 1.00]
- **ToastMonitor Icon Visual Identity** — artifacts_toastmonitor_icon_toastmonitor_source_alpha_source_artwork, artifacts_toastmonitor_icon_toastmonitor_source_alpha_toast_motif, artifacts_toastmonitor_icon_toastmonitor_source_alpha_monitor_graph [INFERRED 0.85]
- **ToastMonitor Branding Assets** — artifacts_toastmonitor_icon_toastmonitor_iconset_icon_128x128_app_icon, artifacts_toastmonitor_icon_toastmonitor_iconset_icon_128x128_iconset, artifacts_toastmonitor_icon_toastmonitor_iconset_icon_128x128_toastmonitor_app [INFERRED 0.85]
- **ToastMonitor App Icon Set (Toast + Monitor Trace Design)** — artifacts_toastmonitor_icon_toastmonitor_iconset_icon_128x128_2x_app_icon, artifacts_toastmonitor_icon_toastmonitor_iconset_icon_16x16_icon_16x16, artifacts_toastmonitor_icon_toastmonitor_iconset_icon_512x512_2x_icon_512x512_2x, artifacts_toastmonitor_icon_toastmonitor_iconset_icon_128x128_2x_toast_graph_concept [INFERRED 0.95]
- **ToastMonitor Icon Brand System** — artifacts_toastmonitor_icon_toastmonitor_iconset_icon_16x16_app_icon, artifacts_toastmonitor_icon_toastmonitor_iconset_icon_16x16_toast_motif, artifacts_toastmonitor_icon_toastmonitor_iconset_icon_16x16_brand_identity [INFERRED 0.75]
- **ToastMonitor Icon Design Composition** — artifacts_toastmonitor_icon_toastmonitor_iconset_icon_16x16_2x_app_icon, artifacts_toastmonitor_icon_toastmonitor_iconset_icon_16x16_2x_toast_bread_slice, artifacts_toastmonitor_icon_toastmonitor_iconset_icon_16x16_2x_toast_wordmark, artifacts_toastmonitor_icon_toastmonitor_iconset_icon_16x16_2x_color_palette [INFERRED 0.95]
- **ToastMonitor Icon Visual Identity** — artifacts_toastmonitor_icon_toastmonitor_iconset_icon_256x256_app_icon, artifacts_toastmonitor_icon_toastmonitor_iconset_icon_256x256_toast_graph_symbol [EXTRACTED 1.00]
- **ToastMonitor Icon Visual Concept** — artifacts_toastmonitor_icon_toastmonitor_iconset_icon_256x256_2x_app_icon, artifacts_toastmonitor_icon_toastmonitor_iconset_icon_256x256_2x_toast_bread, artifacts_toastmonitor_icon_toastmonitor_iconset_icon_256x256_2x_monitor_chart, artifacts_toastmonitor_icon_toastmonitor_iconset_icon_256x256_2x_toastmonitor_app [INFERRED 0.85]
- **ToastMonitor Icon Composition** — artifacts_toastmonitor_icon_toastmonitor_iconset_icon_32x32_app_icon, artifacts_toastmonitor_icon_toastmonitor_iconset_icon_32x32_toast, artifacts_toastmonitor_icon_toastmonitor_iconset_icon_32x32_rounded_square_frame, artifacts_toastmonitor_icon_toastmonitor_iconset_icon_32x32_dark_palette [EXTRACTED 1.00]
- **ToastMonitor Icon Composition** — artifacts_toastmonitor_icon_toastmonitor_iconset_icon_32x32_2x_app_icon, artifacts_toastmonitor_icon_toastmonitor_iconset_icon_32x32_2x_toast_slice, artifacts_toastmonitor_icon_toastmonitor_iconset_icon_32x32_2x_icon_design_family [INFERRED 0.85]
- **Icon Design: Toast with Embedded Trend Chart** — artifacts_toastmonitor_icon_toastmonitor_iconset_icon_512x512_app_icon, artifacts_toastmonitor_icon_toastmonitor_iconset_icon_512x512_toast, artifacts_toastmonitor_icon_toastmonitor_iconset_icon_512x512_trend_chart [INFERRED 0.85]
- **ToastMonitor Icon Design** — artifacts_toastmonitor_icon_toastmonitor_iconset_icon_512x512_2x_app_icon, artifacts_toastmonitor_icon_toastmonitor_iconset_icon_512x512_2x_toast_bread, artifacts_toastmonitor_icon_toastmonitor_iconset_icon_512x512_2x_line_graph [INFERRED 0.95]
- **Usage Widget Layout** — docs_redesign_after_content_usage_card, docs_redesign_after_content_model_breakdown, docs_redesign_after_content_cost_panel, docs_redesign_after_content_time_range_tabs [INFERRED 0.85]
- **Model Usage Split** — docs_redesign_after_content_ohmypi, docs_redesign_after_content_hermes, docs_redesign_after_content_codex [EXTRACTED 1.00]
- **Redesigned Widget UI (After State)** — docs_redesign_after_content_ui_after, docs_redesign_after_content_usage_card, docs_redesign_after_content_sync_status, docs_redesign_after_content_footer_actions [INFERRED 0.85]
- **Usage Summary Components** — docs_redesign_before_token_metric, docs_redesign_before_model_chart, docs_redesign_before_stats_panel [INFERRED 0.95]
- **Dashboard Navigation Chrome** — docs_redesign_before_time_filter, docs_redesign_before_footer_nav, docs_redesign_before_dashboard [INFERRED 0.95]
- **Old ToastMonitor UI** — docs_redesign_before_ui_before, docs_redesign_before_screenshot, docs_redesign_before_dashboard [INFERRED 0.95]

## Communities (82 total, 11 thin omitted)

### Community 0 - "Popover Views & Bindings"
Cohesion: 0.05
Nodes (47): Binding, Context, NSObject, NSSegmentedControl, NSViewRepresentable, Coordinator, dayFromKey(), HeroValue (+39 more)

### Community 1 - "URL Session Networking"
Cohesion: 0.08
Nodes (24): NoRedirectDelegate, Data, Error, HTTPURLResponse, Int, URLRequest, URLResponse, URLSession (+16 more)

### Community 2 - "Dashboard Window & Toolbar"
Cohesion: 0.07
Nodes (26): NSToolbar, NSToolbarDelegate, NSToolbarItem, NSToolbarItemGroup, NSViewController, DashboardPageController, DashboardToolbarController, .initialTabIndex (+18 more)

### Community 3 - "Keychain Credential Storage"
Cohesion: 0.10
Nodes (25): OSStatus, KeychainStore, .lastSecStatus, .lastWasInteractionNotAllowed, LegacyValue, missing, unavailable, value (+17 more)

### Community 4 - "SQLite Database Layer"
Cohesion: 0.13
Nodes (6): Equatable, Database, Subscription, Any, Bool, String

### Community 5 - "Design System & Styling"
Cohesion: 0.08
Nodes (31): Font, .color, .heatLegend, .body, .statusLine, .activityBlock, .hero, .sourceBar (+23 more)

### Community 6 - "Cost & Token Aggregation"
Cohesion: 0.06
Nodes (36): AppState, .all, .allTokens, .apiValueAll, .apiValueMonth, .apiValueToday, .apiValueWeek, .byToolAll (+28 more)

### Community 7 - "Popover Root & Configuration"
Cohesion: 0.08
Nodes (27): Configuration, SMAppService, FooterIconButton, .body, PopoverHeightReporter, PopoverRootView, .body, .footer (+19 more)

### Community 8 - "Plans View & Credentials"
Cohesion: 0.16
Nodes (20): KeyPath, DailyPoint, .id, PlansView, .body, .goCard, .goCredentialSheet, .goHistory (+12 more)

### Community 9 - "Source Health Monitoring"
Cohesion: 0.10
Nodes (21): ObservableObject, SourceHealth, .displayName, .id, .isStale, SourceHealthHub, Bool, Double (+13 more)

### Community 10 - "Daily Aggregates & Breakdowns"
Cohesion: 0.14
Nodes (18): Hashable, Identifiable, DayAgg, LocalRebuildPreview, ModelAgg, .id, OGSnapshot, .id (+10 more)

### Community 11 - "Hermes Remote Client"
Cohesion: 0.11
Nodes (20): HermesRemoteClient, .feedURL, .remoteSourcesEnabled, IPv4Address, .isLoopback, .isPrivate, .isTailscale, Any (+12 more)

### Community 12 - "Date & Number Formatting"
Cohesion: 0.15
Nodes (12): DateFormatter, NumberFormatter, DateFormatterCache, Format, Date, Double, Int64, String (+4 more)

### Community 13 - "Repo Docs & Contribution"
Cohesion: 0.09
Nodes (30): Sanitized Logs Requirement, Bug Report Issue Template, Feature Request Constraints, Feature Request Issue Template, Pull Request Template, Migration Replay Gate, CI Workflow, Contributing Guide (+22 more)

### Community 14 - "Backup & Data Maintenance"
Cohesion: 0.14
Nodes (15): LocalizedError, DataMaintenance, .directory, DataRepairReceipt, MaintenanceError, backupFailed, clearFailed, .errorDescription (+7 more)

### Community 15 - "Settings Views & Sections"
Cohesion: 0.11
Nodes (19): .subsCard, DataMaintenanceSection, .body, SettingsView, SubscriptionSettingsSection, .body, .subscriptionForm, Bool (+11 more)

### Community 16 - "Usage Query Service"
Cohesion: 0.21
Nodes (11): Sendable, CostQuality, .coverage, LightSnapshot, Snapshot, Double, Int, Int64 (+3 more)

### Community 17 - "DSH Session Log Parsing"
Cohesion: 0.16
Nodes (16): DSHParser, .home, .projCachePath, .sessionsRoot, Mode, cache, log, SessionListCache (+8 more)

### Community 19 - "Database Backup Tests"
Cohesion: 0.20
Nodes (5): Double, Int64, TurnRecord, DatabaseTests, String

### Community 20 - "App Delegate & Status Bar"
Cohesion: 0.15
Nodes (13): ClosedRange, Notification, NSApplicationDelegate, NSStatusBarButton, AppDelegate, Any, CGFloat, Double (+5 more)

### Community 21 - "File Scanning & Caching"
Cohesion: 0.19
Nodes (11): ISO8601DateFormatter, FileListCache, FileListCacheStore, FileScanner, ISOFormatterCache, Stat, Bool, Date (+3 more)

### Community 22 - "Overview Heatmap & Periods"
Cohesion: 0.15
Nodes (18): Period, OverviewView, .actualSpend, .apiValue, .heatmapMaxTokens, .heatmapWeeks, .periodCalls, .periodControl (+10 more)

### Community 23 - "Collector Engine Scheduling"
Cohesion: 0.20
Nodes (12): DispatchSourceTimer, CollectorEngine, ScanReceipt, .changed, Bool, CFAbsoluteTime, Date, Int (+4 more)

### Community 24 - "Floating Panel Window"
Cohesion: 0.14
Nodes (15): NSPanel, NSSize, NSWindowDelegate, FloatingPanel, .canBecomeKey, .canBecomeMain, PanelController, .dismissOnResign (+7 more)

### Community 25 - "DSH Parser Tests"
Cohesion: 0.18
Nodes (5): DSHParserTests, .fixturePath, .projCacheFixturePath, Int64, String

### Community 26 - "Forecast & Subscription Math"
Cohesion: 0.19
Nodes (11): CycleInfo, Forecast, SubscriptionMath, Bool, Date, Double, Int, Int64 (+3 more)

### Community 27 - "System Framework Imports"
Cohesion: 0.11
Nodes (6): Combine, CryptoKit, Foundation, Security, DebugLog, Bool

### Community 28 - "Session Totals & Cache Scan"
Cohesion: 0.16
Nodes (6): SessionInfo, OpenCodeParserDeltaTests, Double, Int64, HermesParserTests, Int64

### Community 29 - "Tool Kind Identity"
Cohesion: 0.11
Nodes (19): Bool, Color, ToolKind, .cacheIncludedInInput, claude, codex, .defaultSource, .displayName (+11 more)

### Community 30 - "Update Manager Checks"
Cohesion: 0.16
Nodes (10): Data, Bool, Date, Error, String, URL, UpdateManager, .autoCheckEnabled (+2 more)

### Community 31 - "Test Suite Modules"
Cohesion: 0.17
Nodes (5): SQLite3, Data, String, ToastMonitor, XCTest

### Community 32 - "Update Check Networking"
Cohesion: 0.33
Nodes (11): Decodable, AvailableUpdate, network, Envelope, Payload, Data, Int, String (+3 more)

### Community 33 - "Usage Analysis Views"
Cohesion: 0.20
Nodes (12): DaySegments, .days, CGFloat, Int, UsageAnalysisView, .body, .controls, .costChart (+4 more)

### Community 34 - "Aggregation Rows & Grouping"
Cohesion: 0.29
Nodes (11): AggregateRow, AnalysisData, Grouping, byModel, byTool, .id, Row, Color (+3 more)

### Community 35 - "Metric & Period Enums"
Cohesion: 0.12
Nodes (16): CaseIterable, Period, all, .id, month, today, week, Metric (+8 more)

### Community 36 - "Codex Parser Tests"
Cohesion: 0.17
Nodes (9): Any, Int64, CodexEventIdentityTests, CodexParserJSONTests, .fixturePath, OpenCodeParserTests, Any, String (+1 more)

### Community 37 - "OMP Parser Tests"
Cohesion: 0.18
Nodes (6): OmpParser, .root, String, OmpParserTests, .fixturePath, String

### Community 38 - "Health Status & Month Axis"
Cohesion: 0.15
Nodes (13): .monthLabels, .monthLabels, MonthAxis, Int, Int64, TMHealthStatus, .color, failed (+5 more)

### Community 39 - "Heatmap Grid Rendering"
Cohesion: 0.24
Nodes (11): CGSize, GridItem, HoverPhase, .heatmap, .heatmapCost, HeatmapGrid, .accessibilitySummary, .body (+3 more)

### Community 40 - "Claude Code Parser Tests"
Cohesion: 0.19
Nodes (6): ClaudeCodeParser, .root, String, ClaudeCodeParserTests, .fixturePath, String

### Community 41 - "Response Handling & Limits"
Cohesion: 0.19
Nodes (11): Error, HTTPURLResponse, URLRequest, URLResponse, URLSession, URLSessionDataTask, URLSessionTask, Void (+3 more)

### Community 42 - "Dashboard Sections & Headers"
Cohesion: 0.21
Nodes (11): .heatmapSection, .intro, .pageHeader, .quotaSection, .trendBlock, SectionTitle, .body, String (+3 more)

### Community 43 - "UI Framework Imports"
Cohesion: 0.18
Nodes (4): AppKit, Charts, ServiceManagement, SwiftUI

### Community 44 - "Crash Handler & Main"
Cohesion: 0.20
Nodes (9): CChar, Darwin, Int, Int32, Int64, tmAppendDecimal(), tmCrashSignalHandler(), ToastMonitorMain (+1 more)

### Community 45 - "Sources View Rows"
Cohesion: 0.36
Nodes (7): .body, SourcesView, .body, .content, .remoteRow, Bool, String

### Community 47 - "Pricing Model Tests"
Cohesion: 0.27
Nodes (4): PricingTests, Double, Int64, String

### Community 48 - "Codex Session Parsing"
Cohesion: 0.25
Nodes (5): CodexParser, .sessionsRoot, .stateDBPath, String, CodexParserTests

### Community 49 - "Redesigned UI Screenshot"
Cohesion: 0.24
Nodes (10): Model: Codex (0.9%, 2.1M tokens), Cost Panel (输入 / 输出 / 实际花费 / API 价值), Footer Actions (Power, Settings, 打开主面板), Model: Hermes (7.0%, 16.6M tokens), Model Breakdown Panel (Oh My PI / Hermes / Codex), Model: Oh My PI (92.1%, 218.8M tokens), Sync Status Indicator (数据已同步), Time Range Tabs (今日 / 7 天 / 近 30 天 / 全部) (+2 more)

### Community 50 - "File Scanner Tests"
Cohesion: 0.22
Nodes (3): Any, FileScannerTests, String

### Community 51 - "OpenCode Parser & Model IDs"
Cohesion: 0.36
Nodes (6): OpenCodeParser, .dbPath, Row, Double, Int64, String

### Community 52 - "Update Error Handling"
Cohesion: 0.20
Nodes (10): CheckError, artifactTooLarge, .errorDescription, invalidDownloadURL, invalidEndpoint, invalidResponse, invalidSignature, invalidVersion (+2 more)

### Community 53 - "Redirect & Download Delegates"
Cohesion: 0.24
Nodes (8): HTTPSRedirectDelegate, .exceededLimit, LimitState, .value, Bool, Int64, URLSessionDownloadDelegate, URLSessionTaskDelegate

### Community 54 - "Dashboard UI Screenshots"
Cohesion: 0.31
Nodes (9): ToastMonitor Main Dashboard, Footer Navigation (打开主面板 / Settings / Power), Model Distribution Chart (Oh My PI 92.0%, Hermes 7.2%, Codex 0.7%), Redesign After State (New UI), Old UI Screenshot (redesign-before.png), Statistics Panel (输入 3.9M / 输出 834.7k / 实际花费 $0.968 / API 价值 $9.58), Time Filter Tabs (今日 / 7 天 / 近 30 天 / 全部), Token Metric Display (230.1M tokens, 916 calls) (+1 more)

### Community 55 - "Panel Surface Rendering"
Cohesion: 0.31
Nodes (4): NSView, PanelSurfaceView, CGFloat, NSCoder

### Community 56 - "Event Identity & Digests"
Cohesion: 0.61
Nodes (4): EventIdentity, Any, Int64, String

### Community 57 - "Model Pricing & Estimation"
Cohesion: 0.31
Nodes (5): ModelPrice, Pricing, Double, Int64, String

### Community 58 - "Network Boundary Tests"
Cohesion: 0.25
Nodes (4): ChunkedPayloadURLProtocol, Bool, URLRequest, URLProtocol

### Community 59 - "Hermes Parser & Sessions"
Cohesion: 0.32
Nodes (6): HermesParser, .dbPath, SessionRow, Int64, OpaquePointer, String

### Community 60 - "App Icon 1024 Concept"
Cohesion: 0.53
Nodes (6): ToastMonitor App Icon, 3D Rendered Bread Slice, Dark Charcoal Rounded-Square Background, Toast Logo Mark (Curved Line with Three Square Nodes), Toast Notification Concept, Toast Food/Notification Visual Pun

### Community 61 - "App Icon 32 Concept"
Cohesion: 0.50
Nodes (5): ToastMonitor App Icon (32x32), Dark Charcoal and Golden Color Palette, Rounded-Square macOS Icon Frame, Golden Toasted Bread Slice, ToastMonitor Brand Identity

### Community 62 - "Appcast Manifest Keys"
Cohesion: 0.40
Nodes (5): CodingKey, CodingKeys, downloadURL, sha256, version

### Community 64 - "Icon Retina Size Family"
Cohesion: 0.50
Nodes (4): ToastMonitor App Icon (128pt @2x), Toast + Monitoring Trace Visual Pun, ToastMonitor Icon (16x16), ToastMonitor Icon (512pt @2x)

### Community 65 - "Iconset 128 Family"
Cohesion: 0.67
Nodes (4): ToastMonitor App Icon (128x128), ToastMonitor Iconset Family, Toasted Bread Icon Subject, ToastMonitor App

### Community 66 - "Icon 16@2x Palette"
Cohesion: 0.50
Nodes (4): ToastMonitor App Icon (16x16@2x), Icon Color Palette (Charcoal, Orange, Cream, Gold), Toast Bread Slice Icon Subject, Toast Wordmark Text

### Community 67 - "Icon Bread & Chart Motif"
Cohesion: 0.67
Nodes (4): ToastMonitor App Icon, Embedded Monitoring Chart, Toast Bread Motif, ToastMonitor Application

### Community 68 - "Icon 512@2x Concept"
Cohesion: 0.67
Nodes (4): ToastMonitor App Icon (512x512@2x), Line Graph Symbol, Data Monitoring Theme, Toast Bread Slice

### Community 69 - "Icon Source Artwork"
Cohesion: 0.83
Nodes (4): ToastMonitor App Icon, Recessed Monitoring Line Graph Element, ToastMonitor Source Icon Artwork, Skeuomorphic Toast Bread Slice Motif

### Community 71 - "Icon 16 Concept"
Cohesion: 1.00
Nodes (3): ToastMonitor App Icon (16x16), ToastMonitor Brand Identity, Toast Slice Motif

### Community 72 - "Icon 32@2x Concept"
Cohesion: 1.00
Nodes (3): ToastMonitor App Icon (32x32@2x), ToastMonitor Icons Set Design Family, Toasted Bread Slice (Icon Subject)

### Community 73 - "Icon 512 Concept"
Cohesion: 1.00
Nodes (3): ToastMonitor App Icon (512x512), Toast Slice (Icon Subject), Rising Trend Chart (Icon Detail)

### Community 74 - "Credential Targets"
Cohesion: 0.67
Nodes (3): CredentialTarget, openCodeGo, openRouter

## Ambiguous Edges - Review These
- `Redesign Before State (Old UI)` → `Redesign After State (New UI)`  [AMBIGUOUS]
  docs/redesign-before.png · relation: conceptually_related_to

## Knowledge Gaps
- **199 isolated node(s):** `PackageDescription`, `.today`, `.week`, `.month`, `.all` (+194 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **11 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **What is the exact relationship between `Redesign Before State (Old UI)` and `Redesign After State (New UI)`?**
  _Edge tagged AMBIGUOUS (relation: conceptually_related_to) - confidence is low._
- **Why does `Database` connect `SQLite Database Layer` to `Popover Views & Bindings`, `URL Session Networking`, `Aggregation Rows & Grouping`, `Keychain Credential Storage`, `OMP Parser Tests`, `Cost & Token Aggregation`, `Plans View & Credentials`, `Daily Aggregates & Breakdowns`, `Backup & Data Maintenance`, `Settings Views & Sections`, `Usage Query Service`, `Feed Import & Settings`, `Database Backup Tests`, `DSH Parser Tests`, `Forecast & Subscription Math`, `Session Totals & Cache Scan`, `Test Suite Modules`?**
  _High betweenness centrality (0.270) - this node is a cross-community bridge._
- **Why does `ToolKind` connect `Tool Kind Identity` to `Usage Analysis Views`, `Aggregation Rows & Grouping`, `Metric & Period Enums`, `SQLite Database Layer`, `Design System & Styling`, `Source Health Monitoring`, `Daily Aggregates & Breakdowns`, `Hermes Remote Client`, `UI Framework Imports`, `Sources View Rows`, `Backup & Data Maintenance`, `Settings Views & Sections`, `Usage Query Service`, `Feed Import & Settings`, `Database Backup Tests`, `Overview Heatmap & Periods`, `Session Totals & Cache Scan`?**
  _High betweenness centrality (0.064) - this node is a cross-community bridge._
- **Why does `AppState` connect `Cost & Token Aggregation` to `Popover Views & Bindings`, `SQLite Database Layer`, `Heatmap Grid Rendering`, `Plans View & Credentials`, `Source Health Monitoring`, `UI Framework Imports`, `Usage Query Service`, `Overview Heatmap & Periods`?**
  _High betweenness centrality (0.050) - this node is a cross-community bridge._
- **Are the 14 inferred relationships involving `ToolKind` (e.g. with `.displayName` and `.record()`) actually correct?**
  _`ToolKind` has 14 INFERRED edges - model-reasoned connections that need verification._
- **Are the 2 inferred relationships involving `AppState` (e.g. with `.subForGo` and `.codexStatusRow`) actually correct?**
  _`AppState` has 2 INFERRED edges - model-reasoned connections that need verification._
- **Are the 2 inferred relationships involving `PlansView` (e.g. with `.host()` and `.body`) actually correct?**
  _`PlansView` has 2 INFERRED edges - model-reasoned connections that need verification._