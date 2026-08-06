import SwiftUI

/// The compact menu bar label: today's tokens + confirmed variable spend.
/// Fixed subscriptions and estimates stay separate in the tooltip; they are
/// never silently added to a single financial number.
struct MenuBarLabel: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var orClient = OpenRouterClient.shared

    private var todayActual: Double { app.costToday.actual + orClient.state.usageDaily }

    private var subAmortized: Double {
        var t = 0.0
        for sub in app.subscriptions {
            guard sub.startDate <= Int64(Date().timeIntervalSince1970) else { continue }
            if let info = SubscriptionMath.cycleInfo(start: sub.startDate, cycle: sub.cycle) {
                t += sub.price / Double(info.totalDays)
            }
        }
        return t
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 11, weight: .semibold))
            Text("\(Format.compact(app.todayTokens)) · \(todayActual > 0 ? Format.moneyShort(todayActual) : "—")")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
        }
        .help("""
        ToastMonitor
        今日 \(Format.compact(app.todayTokens)) tokens（输入 + 输出；缓存独立）
        今日已确认变量支出 \(Format.money(todayActual))
        今日估算变量支出 \(Format.money(app.costToday.estimated))
        · 订阅摊销 \(Format.money(subAmortized))
        · OpenRouter 实际 \(Format.money(orClient.state.usageDaily))
        · 本机/直连（估算）\(Format.money(app.costToday.estimated))
        """)
    }
}
