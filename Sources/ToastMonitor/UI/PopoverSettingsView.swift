import SwiftUI
import AppKit
import Combine

// MARK: - Glass intensity

/// Popover 玻璃材质强度（0.25 = 更通透 … 1.0 = 更磨砂，即 effect 层 alpha）。
/// 独立于主面板配置：视觉设置留在 Popover，订阅/凭据数据在主面板改。
@MainActor
final class GlassSettings: ObservableObject {
    static let shared = GlassSettings()

    static let key = "popoverGlassIntensity"
    /// 允许的范围：再低内容就没有可读背景了。
    static let range = 0.25...1.0

    @Published var intensity: Double {
        didSet {
            UserDefaults.standard.set(intensity, forKey: Self.key)
        }
    }

    private init() {
        let stored = UserDefaults.standard.object(forKey: Self.key) as? Double ?? 1.0
        intensity = Self.clamp(stored)
    }

    /// 纯函数，无状态：测试可同步调用。
    nonisolated static func clamp(_ v: Double) -> Double {
        min(max(v, range.lowerBound), range.upperBound)
    }

    /// 滑块值 → NSVisualEffectView 的 alpha。
    ///
    /// 直接线性映射不线性：behindWindow 磨砂的感知区间很窄，alpha 降到
    /// ~0.8 以下磨砂视觉就消失了，导致滑块中低段全是死区（用户实测
    /// 「到 80% 就完全 clear，再拖没区别」）。用 gamma 曲线把视觉变化
    /// 摊平到整个滑块行程：
    /// - 0% 滑块 → alpha 0.75（完全通透，再低内容没有可读背景）
    /// - 100% 滑块 → alpha 1.0（满磨砂）
    /// - 中段按 pow(t, 0.6) 过渡，低段变化更快（从 clear 快速进入磨砂）。
    nonisolated static func alpha(for slider: Double) -> Double {
        let t = min(max((slider - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
        let low: Double = 0.75
        return low + (1 - low) * pow(t, 0.6)
    }
}

// MARK: - Popover 内嵌设置页

/// Popover 的第二页（仿 Tusi：同一面板内 ZStack 切换，不做新窗口）。
/// 只放前端/外观类设置；订阅、凭据、来源等数据配置一律在主面板。
struct PopoverSettingsView: View {
    @ObservedObject private var glass = GlassSettings.shared
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.7)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    appearanceSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                // 整页高度直接汇报给 panel controller（绕过 SwiftUI preference）。
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { postHeight(geo.size.height) }
                            .onChange(of: geo.size.height) { _, h in postHeight(h) }
                    }
                )
            }
            Divider().opacity(0.7)
            footerNote
        }
        .frame(width: 400)
        .environment(\.controlSize, .small)
        .onReceive(NotificationCenter.default.publisher(for: PanelController.settingsBackNotification)) { _ in
            onBack()
        }
    }

    // MARK: - Header（Tusi 风格：返回按钮 + 标题 + 版本）

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("返回 (Esc)")

            Text("设置")
                .font(.system(size: 14, weight: .semibold))

            Spacer()

            Text("v\(appVersion)")
                .font(.system(size: 10.5))
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("外观")
                .font(.system(size: TMType.caption, weight: .semibold))
                .foregroundStyle(TMDesign.quiet)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("玻璃通透度")
                        .font(.system(size: 12.5, weight: .medium))
                    Spacer()
                    Text("\(Int((glass.intensity - GlassSettings.range.lowerBound) / (GlassSettings.range.upperBound - GlassSettings.range.lowerBound) * 100))%")
                        .font(.system(size: 12, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(TMDesign.quiet)
                }
                Slider(value: $glass.intensity, in: GlassSettings.range)
                    .accessibilityLabel("Popover 玻璃通透度")
                HStack {
                    Text("更通透")
                        .font(.system(size: 11))
                        .foregroundStyle(TMDesign.faint)
                    Spacer()
                    Text("更磨砂")
                        .font(.system(size: 11))
                        .foregroundStyle(TMDesign.faint)
                }
            }
        }
    }

    private var footerNote: some View {
        HStack {
            Text("外观设置只影响 Popover；订阅与凭据请在主面板修改。")
                .font(.system(size: TMType.micro))
                .foregroundStyle(TMDesign.faint)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func postHeight(_ h: CGFloat) {
        NotificationCenter.default.post(
            name: PanelController.contentHeightNotification,
            object: nil,
            userInfo: ["kind": "body", "height": h]
        )
        // 设置页没有 pinned 周期选择器；清零旧值，避免与 home 的残留叠加。
        NotificationCenter.default.post(
            name: PanelController.contentHeightNotification,
            object: nil,
            userInfo: ["kind": "pinned", "height": 0]
        )
    }
}
