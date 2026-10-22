import Foundation

/// Timing for one model call. A call's records can arrive across several
/// reads (request line, then one line per content block), so every field is
/// optional and rows merge in the database by (tool, key).
struct PerfSample: Equatable {
    let tool: ToolKind
    /// Request identity within the tool (Claude request id, OpenCode message id).
    let key: String
    var model: String?
    /// When the request was sent.
    var requestMs: Int64?
    /// When the first output token arrived.
    var firstTokenMs: Int64?
    /// When the last output token arrived.
    var lastMs: Int64?
    /// Generated tokens, reasoning included.
    var outputTokens: Int64 = 0

    /// Folds a later record for the same call into this one.
    mutating func merge(_ other: PerfSample) {
        model = model ?? other.model
        requestMs = requestMs ?? other.requestMs
        firstTokenMs = firstTokenMs ?? other.firstTokenMs
        if let end = other.lastMs { lastMs = max(lastMs ?? end, end) }
        outputTokens = max(outputTokens, other.outputTokens)
    }
}

/// One measured call, ready for charting. Either figure may be missing.
struct PerfPoint: Equatable {
    let day: Int64
    let tool: String
    let model: String
    let ttftMs: Double?
    let tokensPerSecond: Double?
}

enum PerfStats {
    /// Calls shorter than this are dominated by write and clock granularity.
    static let minOutputTokens: Int64 = 50
    static let minGenerationMs: Int64 = 250

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}
