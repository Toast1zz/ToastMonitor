import Foundation

/// Debug logging gate: set TM_DEBUG=1 to trace per-file scan decisions.
enum DebugLog {
    static let enabled: Bool = ProcessInfo.processInfo.environment["TM_DEBUG"] == "1"
}
