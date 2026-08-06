import Foundation
import Combine

/// Per-source collection health, observable by the UI (spec §3.2 数据来源).
struct SourceHealth: Identifiable, Equatable {
    let tool: String
    var mode: String          // "local" | "remote"
    var lastScan: Int64 = 0
    var lastRows: Int = 0
    var failedRows: Int = 0
    var durationMs: Double = 0
    var error: String?

    var id: String { tool }
    var isStale: Bool {
        lastScan > 0 && Date().timeIntervalSince1970 - TimeInterval(lastScan) > 120
    }
}

@MainActor
final class SourceHealthHub: ObservableObject {
    static let shared = SourceHealthHub()

    @Published private(set) var sources: [SourceHealth] = []

    private init() {}

    func record(tool: String, rows: Int, failed: Int, durationMs: Double, error: String?) {
        var h = sources.first { $0.tool == tool }
            ?? SourceHealth(tool: tool, mode: (ToolKind(rawValue: tool)?.sourceIsRemote ?? false) ? "remote" : "local")
        h.lastScan = Int64(Date().timeIntervalSince1970)
        h.lastRows = rows
        h.failedRows = failed
        h.durationMs = durationMs
        h.error = error
        h.mode = (ToolKind(rawValue: tool)?.sourceIsRemote ?? false) ? "remote" : "local"
        if let idx = sources.firstIndex(where: { $0.tool == tool }) {
            sources[idx] = h
        } else {
            sources.append(h)
        }
    }

    /// An unchanged scan is not a successful parse. Keep the previous error
    /// and failure count visible while updating the heartbeat timestamp.
    func recordIdle(tool: String, durationMs: Double) {
        var h = sources.first { $0.tool == tool }
            ?? SourceHealth(tool: tool, mode: (ToolKind(rawValue: tool)?.sourceIsRemote ?? false) ? "remote" : "local")
        h.lastScan = Int64(Date().timeIntervalSince1970)
        h.durationMs = durationMs
        h.mode = (ToolKind(rawValue: tool)?.sourceIsRemote ?? false) ? "remote" : "local"
        if let idx = sources.firstIndex(where: { $0.tool == tool }) {
            sources[idx] = h
        } else {
            sources.append(h)
        }
    }
}
