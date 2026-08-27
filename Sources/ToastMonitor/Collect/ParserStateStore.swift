import Foundation

typealias ParserSessionTotals = [String: (
    tool: String,
    input: Int64,
    output: Int64,
    reasoning: Int64,
    cacheRead: Int64,
    cacheWrite: Int64,
    cost: Double
)]

/// Minimal persistence surface used by incremental parsers. Production scans
/// use `StagedParserStateStore`: reads come from the committed database while
/// cursor/baseline writes stay in memory until the parsed rows commit.
protocol ParserStateStore: AnyObject {
    func scanState(_ source: String) -> (size: Int64, mtime: Int64, identity: Int64, context: String?)
    @discardableResult
    func setScanState(_ source: String, size: Int64, mtime: Int64,
                      identity: Int64, context: String?) -> Bool
    func sessionTotals() -> ParserSessionTotals
    @discardableResult
    func setSessionTotals(_ key: String, tool: String, input: Int64, output: Int64,
                          reasoning: Int64, cacheRead: Int64, cacheWrite: Int64,
                          cost: Double, updated: Int64) -> Bool
}

extension Database: ParserStateStore {}

/// In-memory write set for one source scan. Source files and database
/// baselines are checked again while holding the short commit transaction.
/// A mismatch discards the prepared result; the next tick safely replays it.
final class StagedParserStateStore: ParserStateStore {
    private struct ScanUpdate {
        let source: String
        let size: Int64
        let mtime: Int64
        let identity: Int64
        let context: String?
        let sourceStat: FileScanner.Stat
    }

    private struct TotalsUpdate {
        let key: String
        let tool: String
        let input: Int64
        let output: Int64
        let reasoning: Int64
        let cacheRead: Int64
        let cacheWrite: Int64
        let cost: Double
        let updated: Int64
    }

    private let database: Database
    private let sourceSnapshots: [String: FileScanner.Stat?]
    private var originalScanStates: [String: (size: Int64, mtime: Int64, identity: Int64, context: String?)] = [:]
    private var originalTotals: ParserSessionTotals?
    private var scanUpdates: [String: ScanUpdate] = [:]
    private var totalsUpdates: [String: TotalsUpdate] = [:]
    private(set) var preparationIsConsistent = true

    init(database: Database, sourcePaths: [String]) {
        self.database = database
        sourceSnapshots = Dictionary(uniqueKeysWithValues: Set(sourcePaths).map {
            ($0, FileScanner.fileStat($0))
        })
    }

    func scanState(_ source: String) -> (size: Int64, mtime: Int64, identity: Int64, context: String?) {
        if let update = scanUpdates[source] {
            return (update.size, update.mtime, update.identity, update.context)
        }
        if let original = originalScanStates[source] { return original }
        let original = database.scanState(source)
        originalScanStates[source] = original
        return original
    }

    @discardableResult
    func setScanState(_ source: String, size: Int64, mtime: Int64,
                      identity: Int64, context: String?) -> Bool {
        if originalScanStates[source] == nil {
            originalScanStates[source] = database.scanState(source)
        }
        guard let current = FileScanner.fileStat(source),
              current.mtime == mtime,
              current.identity == identity,
              current.size >= size else {
            preparationIsConsistent = false
            return false
        }
        scanUpdates[source] = ScanUpdate(source: source, size: size, mtime: mtime,
                                         identity: identity, context: context,
                                         sourceStat: current)
        return true
    }

    func sessionTotals() -> ParserSessionTotals {
        if let originalTotals { return applyingTotalsUpdates(to: originalTotals) }
        let totals = database.sessionTotals()
        originalTotals = totals
        return applyingTotalsUpdates(to: totals)
    }

    @discardableResult
    func setSessionTotals(_ key: String, tool: String, input: Int64, output: Int64,
                          reasoning: Int64, cacheRead: Int64, cacheWrite: Int64,
                          cost: Double, updated: Int64) -> Bool {
        guard key.split(separator: "|", maxSplits: 1).count == 2 else {
            preparationIsConsistent = false
            return false
        }
        totalsUpdates[key] = TotalsUpdate(key: key, tool: tool, input: input,
                                          output: output, reasoning: reasoning,
                                          cacheRead: cacheRead, cacheWrite: cacheWrite,
                                          cost: cost, updated: updated)
        return true
    }

    /// Runs inside `Database.inTransaction`, before prepared row inserts.
    func validateForCommit() -> Bool {
        guard preparationIsConsistent else { return false }
        for (path, snapshot) in sourceSnapshots {
            guard Self.sameStat(FileScanner.fileStat(path), snapshot) else { return false }
        }
        for update in scanUpdates.values {
            guard Self.sameStat(FileScanner.fileStat(update.source), update.sourceStat),
                  Self.sameScanState(database.scanState(update.source), originalScanStates[update.source])
            else { return false }
        }
        if let originalTotals {
            let current = database.sessionTotals()
            for key in totalsUpdates.keys where !Self.sameTotals(current[key], originalTotals[key]) {
                return false
            }
        }
        return true
    }

    /// Runs inside `Database.inTransaction`, after row inserts succeeded.
    func apply() -> Bool {
        for update in scanUpdates.values.sorted(by: { $0.source < $1.source }) {
            guard database.setScanState(update.source, size: update.size,
                                        mtime: update.mtime, identity: update.identity,
                                        context: update.context) else { return false }
        }
        for update in totalsUpdates.values.sorted(by: { $0.key < $1.key }) {
            guard database.setSessionTotals(update.key, tool: update.tool,
                                            input: update.input, output: update.output,
                                            reasoning: update.reasoning,
                                            cacheRead: update.cacheRead,
                                            cacheWrite: update.cacheWrite,
                                            cost: update.cost, updated: update.updated)
            else { return false }
        }
        return true
    }

    private func applyingTotalsUpdates(to totals: ParserSessionTotals) -> ParserSessionTotals {
        var result = totals
        for update in totalsUpdates.values {
            result[update.key] = (update.tool, update.input, update.output,
                                  update.reasoning, update.cacheRead,
                                  update.cacheWrite, update.cost)
        }
        return result
    }

    private static func sameStat(_ lhs: FileScanner.Stat?, _ rhs: FileScanner.Stat?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?):
            return l.size == r.size && l.mtime == r.mtime && l.identity == r.identity
        default: return false
        }
    }

    private static func sameScanState(
        _ lhs: (size: Int64, mtime: Int64, identity: Int64, context: String?),
        _ rhs: (size: Int64, mtime: Int64, identity: Int64, context: String?)?
    ) -> Bool {
        guard let rhs else { return false }
        return lhs.size == rhs.size && lhs.mtime == rhs.mtime
            && lhs.identity == rhs.identity && lhs.context == rhs.context
    }

    private static func sameTotals(
        _ lhs: (tool: String, input: Int64, output: Int64, reasoning: Int64,
                cacheRead: Int64, cacheWrite: Int64, cost: Double)?,
        _ rhs: (tool: String, input: Int64, output: Int64, reasoning: Int64,
                cacheRead: Int64, cacheWrite: Int64, cost: Double)?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?):
            return l.tool == r.tool && l.input == r.input && l.output == r.output
                && l.reasoning == r.reasoning && l.cacheRead == r.cacheRead
                && l.cacheWrite == r.cacheWrite && l.cost == r.cost
        default: return false
        }
    }
}
