import AppKit
import SwiftUI

/// Building blocks shared by the four dashboard pages.
///
/// The dashboard is the roomy sibling of the popover: the same tonal cards,
/// title-case headings and stacked share bars, laid out on a grid instead of a
/// single column. Pages compose these pieces rather than drawing their own
/// panels, so spacing, type and color stay identical from page to page.
enum DashLayout {
    /// Page margin and the gap between cards.
    static let margin: CGFloat = 24
    static let gap: CGFloat = 16
    /// Content stops growing here and centers, so a full-screen window keeps
    /// a readable measure instead of stretching every card edge to edge.
    static let maxContentWidth: CGFloat = 1240
    static let cardPadding: CGFloat = 18
    static let cardRadius: CGFloat = 12
}

/// Page scaffold: margin, centered readable width, one vertical rhythm, and
/// exactly the window's height. Pages never scroll as a whole. A page whose
/// content can use more height (a chart, a list) lets that card absorb it and
/// scroll inside; cards with nothing more to show keep their content height
/// rather than being stretched into empty surfaces.
struct DashPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DashLayout.gap) {
            content
        }
        .frame(maxWidth: DashLayout.maxContentWidth, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, DashLayout.margin)
        .padding(.top, 18)
        .padding(.bottom, DashLayout.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// Keeps a card at its content height inside a filling page.
    func dashFixedHeight() -> some View {
        fixedSize(horizontal: false, vertical: true)
    }
}

/// A grouped surface. No stroke: on macOS, grouped content separates from the
/// window by tone alone, exactly like the popover's cards.
struct DashCard<Trailing: View, Content: View>: View {
    let title: String?
    /// Padding around the card content. Lists whose rows carry their own
    /// hover background use a smaller inset so the highlight stays inside.
    var inset: CGFloat
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(_ title: String? = nil,
         inset: CGFloat = DashLayout.cardPadding,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.inset = inset
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if title != nil || Trailing.self != EmptyView.self {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let title {
                        Text(title)
                            .font(TMType.semibold(15))
                    }
                    Spacer(minLength: 8)
                    trailing
                }
            }
            content
        }
        .padding(inset)
        // Fills the row it shares: cards side by side end on one edge.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TMDesign.surface,
                    in: RoundedRectangle(cornerRadius: DashLayout.cardRadius, style: .continuous))
    }
}

/// A single headline figure with its label above it. Sits in a row of equal
/// tiles at the top of a page.
struct DashMetric: View {
    let label: String
    let value: String
    var warningDetail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(label)
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(TMDesign.quiet)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let warningDetail {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(TMDesign.warning)
                        .help(warningDetail)
                }
            }
            Text(value)
                .font(TMType.semibold(26))
                .tmMonospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, DashLayout.cardPadding)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TMDesign.surface,
                    in: RoundedRectangle(cornerRadius: DashLayout.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(Text(value))
    }
}

struct DashMetricRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 12) { content }
    }
}

/// One entry of a share breakdown (tool, model, …).
struct ShareItem: Identifiable {
    let name: String
    let value: Int64
    let color: Color
    var id: String { name }
}

/// Stacked proportion bar: one segment per item, separated by a gap so
/// neighbouring hues stay distinguishable (HIG Charts: separate contiguous
/// areas of color).
struct ShareBar: View {
    let items: [ShareItem]
    var height: CGFloat = 8

    static func segmentWidths(values: [Int64], availableWidth: CGFloat, gap: CGFloat = 2) -> [CGFloat] {
        let positive = values.filter { $0 > 0 }
        guard !positive.isEmpty, availableWidth > 0 else { return [] }
        let totalGap = CGFloat(max(positive.count - 1, 0)) * gap
        let usable = max(0, availableWidth - totalGap)
        guard usable > 0 else { return Array(repeating: 0, count: positive.count) }
        let total = Double(positive.reduce(0, +))
        let minSeg = min(3, usable / CGFloat(positive.count))
        var widths = positive.map { usable * CGFloat(Double($0) / total) }
        var deficit: CGFloat = 0
        var surplusTotal: CGFloat = 0
        for i in widths.indices {
            if widths[i] < minSeg {
                deficit += minSeg - widths[i]
                widths[i] = minSeg
            } else {
                surplusTotal += widths[i] - minSeg
            }
        }
        if deficit > 0, surplusTotal > 0 {
            let scale = min(1, deficit / surplusTotal)
            for i in widths.indices where widths[i] > minSeg {
                widths[i] -= (widths[i] - minSeg) * scale
            }
        }
        return widths
    }

    var body: some View {
        GeometryReader { geo in
            let active = items.filter { $0.value > 0 }
            let widths = Self.segmentWidths(values: active.map(\.value), availableWidth: geo.size.width)
            HStack(spacing: 2) {
                ForEach(Array(zip(active, widths).enumerated()), id: \.offset) { _, pair in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(pair.0.color)
                        .frame(width: pair.1)
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule(style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Ranked share list: colored dot, name, percentage and value in aligned
/// columns, preceded by the stacked bar.
struct ShareList: View {
    let items: [ShareItem]
    /// Rows beyond this many collapse into one "Other" line.
    var limit = 6
    var emptyText = "No usage in this period"

    private var visible: [ShareItem] {
        guard items.count > limit else { return items }
        let head = Array(items.prefix(limit - 1))
        let rest = items.dropFirst(limit - 1)
        let other = ShareItem(name: "Other \(rest.count)",
                              value: rest.reduce(Int64(0)) { $0 + $1.value },
                              color: Color.primary.opacity(0.25))
        return head + [other]
    }

    var body: some View {
        let shown = visible
        let total = Double(shown.reduce(Int64(0)) { $0 + $1.value })
        if shown.isEmpty || total <= 0 {
            Text(emptyText)
                .font(TMType.regular(TMType.body))
                .foregroundStyle(TMDesign.quiet)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ShareBar(items: shown)
                VStack(spacing: 9) {
                    ForEach(shown) { item in
                        HStack(spacing: 8) {
                            Circle().fill(item.color).frame(width: 8, height: 8)
                            Text(item.name)
                                .font(TMType.regular(TMType.body))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(String(format: "%.1f%%", Double(item.value) / total * 100))
                                .font(TMType.regular(TMType.caption))
                                .tmMonospacedDigit()
                                .foregroundStyle(TMDesign.quiet)
                                .frame(width: 54, alignment: .trailing)
                            Text(Format.compact(item.value))
                                .font(TMType.medium(TMType.body))
                                .tmMonospacedDigit()
                                .frame(width: 62, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

/// Gauge bar: fills rightward to the percentage it is given.
struct DashUsageBar: View {
    /// 0…100.
    let fillPercent: Double
    let tint: Color
    var height: CGFloat = 6
    /// Optional hairline at a fixed fraction (0…1) of the bar — e.g. the
    /// subscription price as a share of the quota it buys.
    var marker: Double?
    /// 0…1 share of the window's time already passed; nil draws a plain gauge.
    var elapsed: Double? = nil

    static func semanticTint(usedPercent: Double, base: Color) -> Color {
        base
    }

    var body: some View {
        let used = min(max(fillPercent, 0), 100) / 100
        GeometryReader { geo in
            let fillWidth = used > 0 ? max(geo.size.width * used, height) : 0
            let timeWidth = elapsed.map { $0 > 0 ? max(geo.size.width * min($0, 1), height) : 0 }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                if let timeWidth, fillWidth > timeWidth {
                    Capsule()
                        .fill(tint.opacity(0.45))
                        .frame(width: fillWidth)
                    Capsule()
                        .fill(tint)
                        .frame(width: timeWidth)
                } else {
                    if let timeWidth, timeWidth > 0 {
                        Capsule()
                            .fill(Color.primary.opacity(0.12))
                            .frame(width: timeWidth)
                    }
                    Capsule()
                        .fill(tint)
                        .frame(width: fillWidth)
                }
                if let marker {
                    Rectangle()
                        .fill(Color.primary.opacity(0.45))
                        .frame(width: 1, height: height + 4)
                        .offset(x: geo.size.width * CGFloat(min(max(marker, 0), 1)) - 0.5)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Round-cornered tool/service glyph: the brand color as a wash behind a
/// symbol in that color.
struct DashGlyph: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The system value-selection control, as in the popover's period selector:
/// an `NSSegmentedControl` (capsule, extra-large on macOS 26+, `tabs` role on
/// 27 for the draggable Liquid Glass selection). SwiftUI's own segmented
/// picker still draws the flat pre-Liquid Glass bezel. Sized to its content;
/// the segments name themselves, so it needs no caption.
struct DashSegmented<Value: Hashable & Identifiable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    var accessibilityName: String

    var body: some View {
        // An NSSegmentedControl offers no intrinsic width cap of its own, so
        // without this it stretches to whatever space the row leaves it.
        SegmentedControl(selection: $selection, options: options, title: title,
                         accessibilityName: accessibilityName)
            .fixedSize()
            .modifier(SegmentedControlSize())
            // Measured on macOS 27: bare, the capsule overhangs its row by 6.5 pt
            // on each side, past the cards and into the next control. With any
            // padding it lays out at full width and lines up with the cards.
            .padding(.horizontal, 0.5)
    }
}

/// The control size is set through the environment, not on the control:
/// SwiftUI writes the environment's size into a represented control on every
/// update, so a size set only on the control was reset and re-applied each
/// refresh, and the control visibly resized whenever the data changed.
private struct SegmentedControlSize: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.environment(\.controlSize, .extraLarge)
        } else {
            content.environment(\.controlSize, .large)
        }
    }
}

private struct SegmentedControl<Value: Hashable & Identifiable>: NSViewRepresentable {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    var accessibilityName: String

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: options.map(title),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:))
        )
        control.segmentDistribution = .fit
        control.selectedSegment = selectedIndex
        if #available(macOS 26.0, *) {
            control.borderShape = .capsule
        }
        if #available(macOS 27.0, *) {
            control.role = .tabs
        }
        control.setAccessibilityLabel(accessibilityName)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        for (index, option) in options.enumerated() where index < control.segmentCount {
            let label = title(option)
            if control.label(forSegment: index) != label {
                control.setLabel(label, forSegment: index)
                control.invalidateIntrinsicContentSize()
            }
        }
        if control.selectedSegment != selectedIndex {
            control.selectedSegment = selectedIndex
        }
    }

    private var selectedIndex: Int {
        options.firstIndex(of: selection) ?? 0
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: SegmentedControl

        init(parent: SegmentedControl) { self.parent = parent }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            guard parent.options.indices.contains(sender.selectedSegment) else { return }
            parent.selection = parent.options[sender.selectedSegment]
        }
    }
}

/// Lays children out left to right and wraps to a new line when the row is full.
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + verticalSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.items.isEmpty ? size.width : row.width + horizontalSpacing + size.width
            if !row.items.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + horizontalSpacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

/// Rounded-top-only bar clip shape (macOS 13+ replacement for UnevenRoundedRectangle)
/// so interior stacked bar segments stay flush without pinched corner notches.
struct DashBarSegmentShape: Shape {
    var topRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }
        let r = min(max(topRadius, 0), rect.width / 2, rect.height)
        guard r > 0 else { return Path(rect) }
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + r, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + r),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

extension View {
    /// Floating callout card surface: shadow and hairline border live on the
    /// card backing instead of the view itself so SwiftUI does not cast
    /// per-glyph drop shadows behind text and legend dots.
    func dashChartCallout() -> some View {
        background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(TMDesign.calloutSurface)
                .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(TMDesign.divider, lineWidth: 0.75)
        }
    }

    /// Scrollers that appear only while scrolling, whatever the system
    /// scroll bar setting. For short lists inside a card, whose clipped last
    /// row already shows that more follow. Apply inside the ScrollView.
    func overlayScrollers() -> some View {
        background(OverlayScrollerStyle())
    }
}

private struct OverlayScrollerStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // AppKit restores the preferred style when the setting or the
            // attached pointing devices change.
            if observer == nil {
                observer = NotificationCenter.default.addObserver(
                    forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                    object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.apply() }
                }
            }
        }

        private func apply() {
            enclosingScrollView?.scrollerStyle = .overlay
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
