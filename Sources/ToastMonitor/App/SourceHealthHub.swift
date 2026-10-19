import Foundation
import Combine

/// Per-source collection health, observable by the UI.
struct SourceHealth: Identifiable, Equatable {
    let tool: String
    var mode: String          // "local" | "remote"
    var lastScan: Int64 = 0
    var lastRows: Int = 0
    var failedRows: Int = 0
    var durationMs: Double = 0
    var error: String?

    var id: String { tool }

    /// User-facing name used when an aggregate status needs to identify one
    /// failing source instead of reporting only a count.
    var displayName: String {
        if tool == "remote-feed" { return "Remote Feed" }
        return ToolKind(rawValue: tool)?.displayName ?? tool
    }
    var isStale: Bool {
        lastScan > 0 && Date().timeIntervalSince1970 - TimeInterval(lastScan) > Self.staleThreshold
    }
}

extension SourceHealth {
    /// One staleness threshold for local sources and the remote feed alike.
    static let staleThreshold: TimeInterval = 120
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

    /// Drop the remote feed and any remote-mode records once remote ingestion
    /// is disabled; nothing refreshes them afterwards, so they would otherwise
    /// age into a permanent "stale" status.
    func purgeRemote() {
        let kept = sources.filter { $0.tool != "remote-feed" && $0.mode != "remote" }
        if kept.count != sources.count { sources = kept }
    }

    /// An unchanged scan is still a successful parse. Clear an old error so a
    /// transient failure cannot remain visible forever after recovery.
    func recordIdle(tool: String, durationMs: Double) {
        var h = sources.first { $0.tool == tool }
            ?? SourceHealth(tool: tool, mode: (ToolKind(rawValue: tool)?.sourceIsRemote ?? false) ? "remote" : "local")
        h.lastScan = Int64(Date().timeIntervalSince1970)
        h.lastRows = 0
        h.failedRows = 0
        h.durationMs = durationMs
        h.error = nil
        h.mode = (ToolKind(rawValue: tool)?.sourceIsRemote ?? false) ? "remote" : "local"
        if let idx = sources.firstIndex(where: { $0.tool == tool }) {
            sources[idx] = h
        } else {
            sources.append(h)
        }
    }
}
