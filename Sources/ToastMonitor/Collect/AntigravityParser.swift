import Foundation
import SQLite3

/// Antigravity (standalone or inside Gemini.app) keeps one SQLite file per
/// conversation in ~/.gemini/antigravity/conversations/<cascade-id>.db.
/// Each model call is a `gen_metadata` row holding a protobuf
/// `GeneratorMetadata`; its `chatModel.usage` carries the exact token counts
/// the provider returned. The timestamp comes from the `steps` row the call
/// produced, and the title and workspace from conversation_summaries.db.
///
/// Protobuf field numbers (stable wire contract, verified against the
/// language server's JSON API for the same rows):
///   GeneratorMetadata: 1 chatModel, 2 stepIndices (packed)
///   ChatModelMetadata: 4 usage, 11 timeToFirstToken, 12 streamingDuration
///                      (Duration: 1 seconds, 2 nanos), 19 responseModel
///   ModelUsageStats:   2 input, 3 output (thinking + response), 5 cacheRead,
///                      7 messageId, 9 thinking, 11 responseId
///   Step metadata:     1 createdAt (Timestamp: 1 seconds)
///
/// `input` excludes cache reads (Gemini reports them separately here).
enum AntigravityParser {
    static func watermarkKey(_ cascadeID: String) -> String { "antigravity_gen_\(cascadeID)" }

    static var root: String {
        AntigravityQuotaClient.appDataDir().path
    }

    static var conversationsDir: String { (root as NSString).appendingPathComponent("conversations") }
    static var summariesPath: String { (root as NSString).appendingPathComponent("conversation_summaries.db") }

    /// Conversation databases, newest last-modified first.
    static func conversationPaths() -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: conversationsDir) else { return [] }
        return names.filter { $0.hasSuffix(".db") }
            .map { (conversationsDir as NSString).appendingPathComponent($0) }
            .sorted()
    }

    struct Usage: Equatable {
        var input: Int64 = 0
        var output: Int64 = 0
        var thinking: Int64 = 0
        var cacheRead: Int64 = 0
        var messageID: String?
        var responseID: String?
    }

    struct Generation: Equatable {
        var usage: Usage?
        var model: String?
        var stepIndices: [Int64] = []
        var timeToFirstTokenMs: Int64?
        var streamingMs: Int64?
    }

    struct Summary {
        let title: String?
        let project: String?
    }

    static func scan(database: any ParserStateStore = Database.shared) -> (turns: [TurnRecord], sessions: [SessionInfo]) {
        let summaries = loadSummaries()
        var turns: [TurnRecord] = []
        var sessions: [SessionInfo] = []
        for path in conversationPaths() {
            let out = scan(path: path, summary: summaries[cascadeID(path)], database: database)
            turns += out.turns
            if let session = out.session { sessions.append(session) }
        }
        return (turns, sessions)
    }

    static func cascadeID(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private static func scan(path: String, summary: Summary?,
                             database: any ParserStateStore) -> (turns: [TurnRecord], session: SessionInfo?) {
        let cascade = cascadeID(path)
        let key = watermarkKey(cascade)
        let watermark = Int64(database.setting(key) ?? "") ?? -1
        guard let rows = readGenerations(path: path, after: watermark) else {
            database.noteScanProblem("Antigravity conversation could not be opened")
            return ([], nil)
        }
        var turns: [TurnRecord] = []
        var firstTs: Int64?
        var lastTs: Int64 = 0
        var lastModel: String?
        for row in rows {
            let gen = row.gen
            guard let usage = gen.usage,
                  usage.input + usage.output + usage.cacheRead > 0 else { continue }
            let ts = row.sentAt
            firstTs = firstTs.map { min($0, ts) } ?? ts
            lastTs = max(lastTs, ts)
            lastModel = gen.model ?? lastModel
            let cost = Pricing.estimate(model: gen.model, input: usage.input, output: usage.output,
                                        cacheRead: usage.cacheRead, cacheWrite: 0)
            let identity = usage.responseID ?? usage.messageID ?? "\(cascade):\(row.idx)"
            turns.append(TurnRecord(tool: .antigravity, sessionID: cascade, project: summary?.project,
                                    model: gen.model, ts: ts,
                                    inputTokens: usage.input, outputTokens: usage.output,
                                    reasoningTokens: usage.thinking,
                                    cacheRead: usage.cacheRead, cacheWrite: 0,
                                    cost: cost ?? 0,
                                    eventID: "antigravity:\(identity)",
                                    costQuality: cost == nil ? "unknown" : "estimated"))
        }
        let next = readThrough(rows, previous: watermark) { gen in
            guard let usage = gen.usage else { return false }
            return usage.input + usage.output + usage.cacheRead > 0
        }
        if next != watermark { database.setSetting(key, "\(next)") }
        let session = firstTs.map {
            SessionInfo(tool: .antigravity, sessionID: cascade, title: summary?.title,
                        project: summary?.project, model: lastModel, created: $0, updated: lastTs)
        }
        return (turns, session)
    }

    struct Row {
        let idx: Int64
        let gen: Generation
        /// Unix seconds of the step the call produced, else the file's mtime.
        let sentAt: Int64
    }

    /// `gen_metadata` rows after `watermark`, oldest first; nil when the
    /// file cannot be opened. A conversation created moments ago may not
    /// have the table yet, which reads as no rows.
    static func readGenerations(path: String, after watermark: Int64) -> [Row]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)

        var raw: [(idx: Int64, gen: Generation)] = []
        var stmt: OpaquePointer?
        let prepRC = sqlite3_prepare_v2(db, "SELECT idx, data FROM gen_metadata WHERE idx > ? ORDER BY idx;",
                                        -1, &stmt, nil)
        guard prepRC == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? ""
            sqlite3_finalize(stmt)
            // Only a missing table is a genuinely empty brand-new conversation;
            // SQLITE_BUSY / I/O errors must return nil so the caller retries.
            return (prepRC == SQLITE_ERROR && msg.contains("no such table")) ? [] : nil
        }
        sqlite3_bind_int64(stmt, 1, watermark)
        var stepRC: Int32 = SQLITE_OK
        while true {
            stepRC = sqlite3_step(stmt)
            guard stepRC == SQLITE_ROW else { break }
            guard let blob = sqlite3_column_blob(stmt, 1) else { continue }
            let count = Int(sqlite3_column_bytes(stmt, 1))
            guard count > 0, count <= 64_000_000 else { continue }
            raw.append((sqlite3_column_int64(stmt, 0), parseGeneration(Data(bytes: blob, count: count))))
        }
        sqlite3_finalize(stmt)
        guard stepRC == SQLITE_DONE else { return nil }
        guard !raw.isEmpty else { return [] }

        let fallback = FileScanner.fileStat(path).map { $0.mtime / 1_000_000_000 }
            ?? Int64(Date().timeIntervalSince1970)
        var step: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT metadata FROM steps WHERE idx = ?;", -1, &step, nil) != SQLITE_OK {
            sqlite3_finalize(step)
            step = nil
        }
        defer { sqlite3_finalize(step) }
        func createdAt(_ index: Int64) -> Int64? {
            guard let step else { return nil }
            sqlite3_reset(step)
            sqlite3_bind_int64(step, 1, index)
            guard sqlite3_step(step) == SQLITE_ROW, let blob = sqlite3_column_blob(step, 0) else { return nil }
            return parseStepCreatedAt(Data(bytes: blob, count: Int(sqlite3_column_bytes(step, 0))))
        }
        return raw.map { row in
            Row(idx: row.idx, gen: row.gen, sentAt: row.gen.stepIndices.first.flatMap(createdAt) ?? fallback)
        }
    }

    /// The new watermark: the last row that is complete. Earlier rows without
    /// usage (e.g. cancelled/non-usage steps) must not pin the watermark
    /// forever, while trailing incomplete rows stay unread until they finish.
    static func readThrough(_ rows: [Row], previous: Int64, isComplete: (Generation) -> Bool) -> Int64 {
        rows.last { isComplete($0.gen) }.map { max($0.idx, previous) } ?? previous
    }

    /// cascade id → title and workspace folder name.
    static func loadSummaries() -> [String: Summary] {
        var db: OpaquePointer?
        guard FileManager.default.fileExists(atPath: summariesPath),
              sqlite3_open_v2(summariesPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return [:]
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT conversation_id, title, workspace_uris FROM conversation_summaries;",
                                 -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return [:]
        }
        defer { sqlite3_finalize(stmt) }
        var out: [String: Summary] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = SQLiteText.column(stmt, 0), !id.isEmpty else { continue }
            let title = SQLiteText.column(stmt, 1).flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
            out[id] = Summary(title: title, project: project(fromWorkspaceURIs: SQLiteText.column(stmt, 2)))
        }
        return out
    }

    /// `workspace_uris` is a JSON array or a single file:// URI; the first
    /// folder's name is the project.
    static func project(fromWorkspaceURIs raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        var first = raw
        if raw.hasPrefix("["), let data = raw.data(using: .utf8),
           let list = try? JSONSerialization.jsonObject(with: data) as? [String] {
            guard let value = list.first else { return nil }
            first = value
        }
        let path = URL(string: first)?.path ?? first
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    // MARK: - Protobuf

    static func parseGeneration(_ data: Data) -> Generation {
        var gen = Generation()
        Proto.forEachField(data) { field, value in
            switch (field, value) {
            case (1, .bytes(let chat)):
                Proto.forEachField(chat) { f, v in
                    switch (f, v) {
                    case (4, .bytes(let usage)): gen.usage = parseUsage(usage)
                    case (11, .bytes(let d)): gen.timeToFirstTokenMs = parseDurationMs(d)
                    case (12, .bytes(let d)): gen.streamingMs = parseDurationMs(d)
                    case (19, .bytes(let model)): gen.model = cleanModel(model)
                    default: break
                    }
                }
            case (2, .bytes(let packed)):
                gen.stepIndices = Proto.packedVarints(packed)
            case (2, .varint(let index)):
                gen.stepIndices.append(Int64(truncatingIfNeeded: index))
            default: break
            }
        }
        return gen
    }

    static func parseUsage(_ data: Data) -> Usage {
        var usage = Usage()
        Proto.forEachField(data) { field, value in
            switch (field, value) {
            case (2, .varint(let v)): usage.input = FileScanner.tokenCount(Int64(truncatingIfNeeded: v))
            case (3, .varint(let v)): usage.output = FileScanner.tokenCount(Int64(truncatingIfNeeded: v))
            case (5, .varint(let v)): usage.cacheRead = FileScanner.tokenCount(Int64(truncatingIfNeeded: v))
            case (9, .varint(let v)): usage.thinking = FileScanner.tokenCount(Int64(truncatingIfNeeded: v))
            case (7, .bytes(let s)): usage.messageID = cleanID(s)
            case (11, .bytes(let s)): usage.responseID = cleanID(s)
            default: break
            }
        }
        return usage
    }

    static func parseDurationMs(_ data: Data) -> Int64? {
        var seconds: UInt64 = 0
        var nanos: UInt64 = 0
        Proto.forEachField(data) { field, value in
            guard case .varint(let v) = value else { return }
            if field == 1 { seconds = v } else if field == 2 { nanos = v }
        }
        // Anything past a day is a corrupt row, not a real call.
        guard seconds < 86_400, nanos < 1_000_000_000 else { return nil }
        return Int64(seconds) * 1000 + Int64(nanos) / 1_000_000
    }

    static func parseStepCreatedAt(_ data: Data) -> Int64? {
        var seconds: Int64?
        Proto.forEachField(data) { field, value in
            guard field == 1, seconds == nil, case .bytes(let ts) = value else { return }
            Proto.forEachField(ts) { f, v in
                if f == 1, case .varint(let s) = v, s > 0, s < 10_000_000_000 { seconds = Int64(s) }
            }
        }
        return seconds
    }

    private static func cleanModel(_ data: Data) -> String? {
        guard let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty, s.count <= 128, s.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return s
    }

    private static func cleanID(_ data: Data) -> String? {
        guard data.count <= 256, let s = String(data: data, encoding: .utf8), !s.isEmpty,
              s.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return s
    }
}

/// Minimal protobuf wire-format reader: top-level fields only, bounded.
enum Proto {
    enum Value {
        case varint(UInt64)
        case bytes(Data)
        case fixed
    }

    /// Calls `body` for every field until the data ends or is malformed.
    static func forEachField(_ data: Data, _ body: (Int, Value) -> Void) {
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            guard let key = varint(bytes, &i) else { return }
            let field = Int(key >> 3)
            guard field > 0 else { return }
            switch key & 7 {
            case 0:
                guard let v = varint(bytes, &i) else { return }
                body(field, .varint(v))
            case 1:
                guard i + 8 <= bytes.count else { return }
                i += 8
                body(field, .fixed)
            case 2:
                guard let length = varint(bytes, &i), length <= UInt64(bytes.count - i) else { return }
                let end = i + Int(length)
                body(field, .bytes(Data(bytes[i..<end])))
                i = end
            case 5:
                guard i + 4 <= bytes.count else { return }
                i += 4
                body(field, .fixed)
            default:
                return
            }
        }
    }

    static func packedVarints(_ data: Data) -> [Int64] {
        let bytes = [UInt8](data)
        var i = 0
        var out: [Int64] = []
        while i < bytes.count, let v = varint(bytes, &i) {
            out.append(Int64(truncatingIfNeeded: v))
        }
        return out
    }

    private static func varint(_ bytes: [UInt8], _ i: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while i < bytes.count, shift < 64 {
            let byte = bytes[i]
            i += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte < 0x80 { return result }
            shift += 7
        }
        return nil
    }
}
