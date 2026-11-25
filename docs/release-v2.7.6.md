## Fixed

- **Dashboard Table Row Hover Highlight (`Analysis` › `Details` & `Performance` › `Models`)**: Replaced `Grid` / `GridRow` with aligned fixed-column `HStack` rows inside `VStack(spacing: 0)` in `UsageAnalysisView` and `PerformanceView`. Previously SwiftUI distributed `.background(...)` attached to `GridRow` across each individual column cell, producing fragmented gray boxes with gaps between columns on hover instead of one continuous full-row highlight.
- **Dashboard Charts (`UsageAnalysisView` & `PerformanceView`)**:
  - Added `TMDesign.calloutSurface` and `dashChartCallout()` so hover callouts render on a crisp surface card with outer drop shadow and hairline border without per-glyph muddy shadows.
  - Added `DashBarSegmentShape` (macOS 13+ compatible) so stacked bars in `UsageAnalysisView` round only the topmost segment per day, removing pinched interior notches.
  - Centered X-axis date tick labels (`centered: false, anchor: .top`) directly under their bars and used solid 1pt hover rule lines.
