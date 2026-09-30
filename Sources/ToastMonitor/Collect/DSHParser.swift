import Foundation

/// DeepSeek Harness parser.
///
/// The harness keeps all user data under one root (`$DSH_HOME`, default
/// `~/.dsh`). Token accounting is four disjoint buckets — uncached input,
/// output (reasoning is already inside output), cache read, cache write —
/// that map 1:1 onto ToastMonitor's `turns` columns, so "token 来源计算" is
/// just recognizing those buckets in DSH's on-disk data:
///
/// - **Log mode** (primary): incremental parse of the raw event logs
///   `sessions/--<cwd>--/session-<id>/session.jsonl.zstd` (or `.jsonl` when
///   DSH compression is `none`). Every model step carries an
///   `assistant/chunk { type: 'usage' }` record with exact millisecond
///   timestamps, and every `finish` chunk carries `replayState.provider` /
///   `replayState.model`, so per-step turns get precise day attribution and
///   real pricing. Decompression shells out to the `zstd` CLI (see `Zstd`).
/// - **Cache mode** (fallback): Hermes-style delta over the persisted
///   projection cache `storages/session_projcache.json` (per-session
///   cumulative `tokenUsage` buckets, `title`, `cwd`, `createdAt`,
///   `lastPromptAt`). No model, no per-step data, but works on any Mac.
///
/// The mode is chosen once (sticky, stored in settings) and only upgrades
/// cache → log while no `dsh` turns exist yet, so the two accounting paths
/// can never double-count a session.
enum DSHParser {

    // MARK: - Paths

    /// `$DSH_HOME`, falling back to `~/.dsh` (mirrors dsh-home-paths).
    /// Reads the environment directly so tests can point it at a temp root.
    static var home: String {
        if let h = getenv("DSH_HOME"), let s = String(validatingUTF8: h), !s.isEmpty {
            return s
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh").path
    }

    static var sessionsRoot: String {
        (home as NSString).appendingPathComponent("sessions")
    }

    static var projCachePath: String {
        (home as NSString).appendingPathComponent("storages/session_projcache.json")
    }

    // MARK: - Mode

    enum Mode: String {
        case log
        case cache
    }

    static let modeSettingKey = "dsh_parse_mode"

    /// Resolves the parse mode, persisting the first decision and later
    /// upgrading cache → log only when no `dsh` turns exist yet (a mode flip
    /// with existing data would change the baseline and double-count).
    static func resolveMode(database: Database = .shared,
                            zstdAvailable: Bool? = nil) -> Mode {
        let hasZstd = zstdAvailable ?? (Zstd.executablePath() != nil)
        if let stored = database.setting(modeSettingKey), let mode = Mode(rawValue: stored) {
            if mode == .cache, hasZstd,
               database.totals(from: 0, to: Int64(Date().timeIntervalSince1970), tool: .dsh).count == 0 {
                database.setSetting(modeSettingKey, Mode.log.rawValue)
                return .log
            }
            return mode
        }
        let mode: Mode = hasZstd ? .log : .cache
        database.setSetting(modeSettingKey, mode.rawValue)
        return mode
    }

    // MARK: - Session file discovery

    private struct SessionListCache {
        let files: [String]
        let dirMTimes: [String: Int64]
    }

    private static let listLock = NSLock()
    private static var listCache: SessionListCache?

    /// Lists session transcripts under `sessions/`: depth ≤ 3
    /// (`sessions/--<cwd>--/session-<id>/session.jsonl[.zstd]`). The
    /// traversal reuses any cached result until a visited directory changes,
    /// so new sessions appear promptly without re-walking every scan.
    static func listSessionFiles() -> [String] {
        let root = sessionsRoot
        let fm = FileManager.default
        guard fm.fileExists(atPath: root) else { return [] }
        listLock.lock()
        if let cached = listCache,
           cached.dirMTimes[root] != nil,
           cached.dirMTimes.allSatisfy({ FileScanner.dirMT($0.key) == $0.value }) {
            let files = cached.files
            listLock.unlock()
            return files
        }
        listLock.unlock()

        var out: [String] = []
        var directories: [String: Int64] = [:]
        var stack: [(String, Int)] = [(root, 0)]
        while let (dir, depth) = stack.popLast() {
            if let mt = FileScanner.dirMT(dir) { directories[dir] = mt }
            guard depth < 3 else { continue }
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for e in entries where !e.hasPrefix(".") {
                let full = (dir as NSString).appendingPathComponent(e)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    stack.append((full, depth + 1))
                } else if e == "session.jsonl.zstd" || e == "session.jsonl" {
                    out.append(full)
                }
            }
        }
        listLock.lock()
        listCache = SessionListCache(files: out, dirMTimes: directories)
        listLock.unlock()
        return out
    }

    // MARK: - Log mode

    /// Parses changed session logs. `decompress` is injectable so tests can
    /// pass an identity function over plain-JSONL fixtures.
    static func scanLogs(knownPaths: [String], database: any ParserStateStore = Database.shared,
                         decompress: (Data) -> Data? = { Zstd.decompress($0) })
        -> (turns: [TurnRecord], sessions: [SessionInfo]) {
        guard !ToolKind.dsh.sourceIsRemote else { return ([], []) } // local-only source
        var turns: [TurnRecord] = []
        var sessions: [SessionInfo] = []
        for file in knownPaths {
            guard let st = FileScanner.fileStat(file) else { continue }
            let prev = database.scanState(file)
            if prev.size == st.size && prev.mtime == st.mtime && prev.identity == st.identity { continue }

            // Append-only cursor, mirroring the OMP/ClaudeCode pattern: an
            // mtime change with the same size is an in-place rewrite and is
            // replayed from 0; a shrink forces a full rescan too.
            let pendingRewrite = FileScanner.contextNeedsFullRescan(prev.context)
            // JSONL transcripts: the cursor must rest on a line boundary so a
            // truncate + regrow that happened entirely between polls (cursor
            // mid-line) rescans from 0. zstd files are frame-delimited — the
            // raw byte before a frame boundary is compressed data, never a
            // reliable newline — so their recovery path handles rewrites.
            let lineBoundaryOK = file.hasSuffix(".zstd")
                || prev.size == 0
                || FileScanner.isLineBoundary(path: file, offset: prev.size)
            // A tail that repeatedly fails to make progress (e.g. a false
            // zstd magic the cursor parks on forever) forces a full rescan
            // once it has stalled 3 scans in a row.
            let stalled = FileScanner.contextStallCount(prev.context) >= 3
            let sameAppendOnlyFile = prev.identity == st.identity
                && st.size > prev.size
                && prev.mtime != 0
                && !pendingRewrite
                && lineBoundaryOK
                && !stalled
            let offset = sameAppendOnlyFile ? prev.size : 0
            let persisted = (try? JSONSerialization.jsonObject(with: Data((prev.context ?? "").utf8))) as? [String: Any]
            var sessionID = persisted?["sid"] as? String
            var project = persisted?["cwd"] as? String
            var headerCreated: Int64 = 0
            var newOffset = offset
            var preliminaryCount: Int?

            // A known append cursor already has header identity persisted, so
            // fold it in one pass. Only a full rescan needs a header pass.
            if offset == 0 || sessionID == nil {
                var headerFound = false
                var headerSessionID: String?
                var headerProject: String?
                let firstPass = forEachObject(path: file, fromOffset: offset, decompress: decompress) { item in
                    guard offset == 0, !headerFound,
                          item.obj["type"] as? String == "session" else { return }
                    headerFound = true
                    if let id = item.obj["id"] as? String, !id.isEmpty { headerSessionID = id }
                    headerProject = item.obj["cwd"] as? String
                    headerCreated = sec((item.obj["createdAt"] as? NSNumber)?.int64Value ?? 0)
                }
                preliminaryCount = firstPass.count
                newOffset = firstPass.newOffset
                if offset == 0 {
                    sessionID = headerSessionID ?? sessionID
                    project = headerProject ?? project
                }
            }

            func recordEmptyScan() {
                let noProgress = newOffset == offset && offset > 0
                let stallCount = noProgress ? min(FileScanner.contextStallCount(prev.context) + 1, 3) : 0
                let baseContext = FileScanner.contextWithFullRescan(
                    prev.context, pending: st.size < prev.size || pendingRewrite)
                let context = FileScanner.contextWithStallCount(baseContext, count: stallCount)
                if newOffset == offset && st.size >= prev.size {
                    database.setScanState(file, size: prev.size, mtime: st.mtime,
                                          identity: st.identity, context: context)
                } else {
                    database.setScanState(file, size: newOffset, mtime: st.mtime,
                                          identity: st.identity, context: context)
                }
            }
            if preliminaryCount == 0 {
                recordEmptyScan()
                continue
            }
            guard let sid = sessionID, !sid.isEmpty else {
                database.setScanState(file, size: newOffset, mtime: st.mtime,
                                      identity: st.identity,
                                      context: FileScanner.contextWithStallCount(prev.context, count: 0))
                continue
            }

            var foldPass = (count: 0, newOffset: offset)
            let parsed = parseLogEvents({ consume in
                foldPass = forEachObject(path: file, fromOffset: offset,
                                         decompress: decompress, consume)
            }, sessionID: sid, project: project)
            newOffset = foldPass.newOffset
            if parsed.objectCount == 0 {
                recordEmptyScan()
                continue
            }
            turns.append(contentsOf: parsed.turns)
            if parsed.lastTs > 0 || !parsed.turns.isEmpty {
                sessions.append(SessionInfo(tool: .dsh, sessionID: sid, title: nil, project: project,
                                            model: parsed.model, created: headerCreated,
                                            updated: sec(parsed.lastTs > 0 ? parsed.lastTs : headerCreated)))
            }
            var ctx: [String: Any] = ["sid": sid]
            if let project { ctx["cwd"] = project }
            if st.size < prev.size { ctx["_full_rescan"] = true }
            let ctxJSON = (try? JSONSerialization.data(withJSONObject: ctx))
                .flatMap { String(data: $0, encoding: .utf8) }
            database.setScanState(file, size: newOffset, mtime: st.mtime,
                                  identity: st.identity, context: ctxJSON)
        }
        return (turns, sessions)
    }

    /// Reads new transcript objects one line at a time. Compressed input is
    /// held one independent frame at a time, not as a whole log tail.
    /// Peak memory also includes the largest decoded frame, output rows,
    /// and bounded-cache retention (subject to NSCache's advisory limits).
    @discardableResult
    private static func forEachObject(path: String, fromOffset: Int64,
                                      decompress: (Data) -> Data?,
                                      _ body: ((offset: Int64, obj: [String: Any])) -> Void)
        -> (count: Int, newOffset: Int64) {
        guard path.hasSuffix(".zstd") else {
            var count = 0
            let newOffset = FileScanner.forEachNewJSONLine(path: path, fromOffset: fromOffset) {
                count += 1
                body($0)
            }
            return (count, newOffset)
        }

        guard let fh = FileHandle(forReadingAtPath: path) else { return (0, fromOffset) }
        defer { fh.closeFile() }
        guard let total = try? fh.seekToEnd() else { return (0, fromOffset) }
        var start: UInt64 = 0
        if fromOffset > 0 && Int64(total) >= fromOffset {
            start = UInt64(fromOffset)
        }
        guard total > start else { return (0, Int64(total)) }
        let firstSearch = nextFrameOffset(handle: fh, from: start, end: total)
        guard let firstFrame = firstSearch.offset else {
            return (0, firstSearch.failed || fromOffset > 0 ? fromOffset : Int64(total))
        }

        var count = 0
        var cursor = firstFrame
        while cursor < total {
            // DSH appends one tiny frame per event, so a log can hold tens of
            // thousands of them. The zstd CLI decodes concatenated frames, so
            // decode a bounded run of whole frames per call instead of
            // spawning one subprocess per frame.
            if let batchEnd = batchEnd(handle: fh, cursor: cursor, total: total),
               let slice = readFrame(handle: fh, from: cursor, to: batchEnd).data,
               let decompressed = decompress(slice), !decompressed.isEmpty {
                count += parseJSONLLines(decompressed, baseOffset: Int64(cursor), body)
                cursor = batchEnd
                continue
            }
            var searchFrom = cursor + 4
            var completedFrame = false
            var searchFailed = false
            while true {
                let search = nextFrameOffset(handle: fh, from: searchFrom, end: total)
                if search.failed {
                    searchFailed = true
                    break
                }
                guard let candidate = search.offset else { break }
                let frameRead = readFrame(handle: fh, from: cursor, to: candidate)
                if frameRead.failed {
                    searchFailed = true
                    break
                }
                if let compressed = frameRead.data,
                   let decompressed = decompress(compressed), !decompressed.isEmpty {
                    count += parseJSONLLines(decompressed, baseOffset: Int64(cursor), body)
                    cursor = candidate
                    completedFrame = true
                    break
                }
                // A zstd magic can occur inside compressed payload. A failed
                // prefix is not proof of a corrupt frame; try the next marker.
                searchFrom = candidate + 4
            }
            if searchFailed { break }
            if completedFrame { continue }
            let frameRead = readFrame(handle: fh, from: cursor, to: total)
            guard !frameRead.failed, let compressed = frameRead.data,
                  let decompressed = decompress(compressed), !decompressed.isEmpty else {
                break
            }
            count += parseJSONLLines(decompressed, baseOffset: Int64(cursor), body)
            cursor = total
        }
        return (count, Int64(cursor))
    }

    private static let maxBatchBytes: UInt64 = 4 * 1024 * 1024

    /// End offset of a run of whole frames starting at `cursor`: the rest of
    /// the file when it fits in one batch, else the last frame magic inside
    /// the batch window. Nil when no boundary falls inside the window (one
    /// frame larger than a batch), so the caller takes the per-frame path.
    private static func batchEnd(handle: FileHandle, cursor: UInt64, total: UInt64) -> UInt64? {
        let windowEnd = min(total, cursor + maxBatchBytes)
        if windowEnd == total { return total > cursor ? total : nil }
        guard let window = readFrame(handle: handle, from: cursor, to: windowEnd).data,
              window.count > 4 else { return nil }
        let magic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
        var i = window.count - 4
        while i >= 4 {
            let s = window.startIndex + i
            if window[s] == magic[0], window[s + 1] == magic[1],
               window[s + 2] == magic[2], window[s + 3] == magic[3] {
                return cursor + UInt64(i)
            }
            i -= 1
        }
        return nil
    }

    /// Searches the file in bounded windows, retaining only three overlap
    /// bytes so frame magic split across reads is still detected.
    private static func nextFrameOffset(handle: FileHandle, from start: UInt64, end: UInt64)
        -> (offset: UInt64?, failed: Bool) {
        guard start < end else { return (nil, false) }
        do {
            try handle.seek(toOffset: start)
        } catch {
            return (nil, true)
        }
        var window = Data()
        var windowStart = start
        var readPosition = start
        while readPosition < end {
            let amount = Int(min(UInt64(64 * 1024), end - readPosition))
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: amount)
            } catch {
                return (nil, true)
            }
            guard let chunk, !chunk.isEmpty else { return (nil, true) }
            window.append(chunk)
            readPosition += UInt64(chunk.count)
            if let relative = Zstd.nextFrameOffset(in: window, fromOffset: 0) {
                return (windowStart + UInt64(relative), false)
            }
            if window.count > 3 {
                let discarded = window.count - 3
                window.removeSubrange(
                    window.startIndex..<window.index(window.startIndex, offsetBy: discarded))
                windowStart += UInt64(discarded)
            }
        }
        return (nil, false)
    }

    private static func readFrame(handle: FileHandle, from start: UInt64, to end: UInt64)
        -> (data: Data?, failed: Bool) {
        guard end > start else { return (nil, true) }
        do {
            try handle.seek(toOffset: start)
        } catch {
            return (nil, true)
        }
        var frame = Data()
        var remaining = end - start
        while remaining > 0 {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: Int(min(UInt64(64 * 1024), remaining)))
            } catch {
                return (nil, true)
            }
            guard let chunk, !chunk.isEmpty else { return (nil, true) }
            frame.append(chunk)
            remaining -= UInt64(chunk.count)
        }
        return (frame, false)
    }

    /// Line-scans one decompressed frame or plain JSONL chunk. Complete
    /// malformed lines advance; an unterminated invalid line remains pending.
    private static func parseJSONLLines(
        _ data: Data, baseOffset: Int64,
        _ body: ((offset: Int64, obj: [String: Any])) -> Void
    ) -> Int {
        var count = 0
        var lineStart = data.startIndex
        while lineStart < data.endIndex {
            let newline = data[lineStart..<data.endIndex].firstIndex(of: 0x0a)
            let lineEnd = newline ?? data.endIndex
            let line = data[lineStart..<lineEnd]
            var parsed = false
            autoreleasepool {
                if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    let byteOffset = data.distance(from: data.startIndex, to: lineStart)
                    body((offset: baseOffset + Int64(byteOffset), obj: obj))
                    count += 1
                    parsed = true
                }
            }
            if !parsed && newline == nil { break }
            lineStart = newline.map { data.index(after: $0) } ?? data.endIndex
        }
        return count
    }
    /// Folds a streamed event slice into per-step turns. Pending step state
    /// survives frame boundaries and is finalized once the requested slice ends.
    /// An assistant/message usage replaces an earlier chunk sample for the
    /// same turn/step, matching the harness's own token-meter fold.
    private static func parseLogEvents(
        _ stream: (_ consume: ((offset: Int64, obj: [String: Any])) -> Void) -> Void,
        sessionID: String, project: String?
    ) -> (turns: [TurnRecord], firstTs: Int64, lastTs: Int64, model: String?, objectCount: Int) {
        struct PendingStep {
            let usage: [String: Any]
            let seq: Int64
            let time: Int64
        }
        var turns: [TurnRecord] = []
        var pending: [String: PendingStep] = [:]
        var headerProvider: String?
        var headerModel: String?
        var firstTs: Int64 = 0
        var lastTs: Int64 = 0
        var firstModel: String?
        var objectCount = 0

        func emit(usage: [String: Any], seq: Int64, time: Int64,
                  provider: String?, model: String?) {
            let input = (usage["inputTokens"] as? NSNumber)?.int64Value ?? 0
            let output = (usage["outputTokens"] as? NSNumber)?.int64Value ?? 0
            let cacheRead = (usage["cacheReadTokens"] as? NSNumber)?.int64Value ?? 0
            let cacheWrite = (usage["cacheWriteTokens"] as? NSNumber)?.int64Value ?? 0
            guard input + output + cacheRead + cacheWrite > 0 else { return }
            let ts = sec(time > 0 ? time : Int64(Date().timeIntervalSince1970 * 1000))
            let cost = Pricing.estimate(model: model, input: input, output: output,
                                        cacheRead: cacheRead, cacheWrite: cacheWrite)
            turns.append(TurnRecord(tool: .dsh, sessionID: sessionID, project: project,
                                    model: model, ts: ts,
                                    inputTokens: input, outputTokens: output,
                                    cacheRead: cacheRead, cacheWrite: cacheWrite,
                                    cost: cost ?? 0, provider: provider,
                                    eventID: "dsh-log:\(sessionID):\(seq)",
                                    costQuality: cost == nil ? "unknown" : "estimated"))
            if firstTs == 0 || time < firstTs { firstTs = time }
            if time > lastTs { lastTs = time }
            if firstModel == nil, let model, !model.isEmpty { firstModel = model }
        }

        stream { item in
            objectCount += 1
            let obj = item.obj
            guard let type = obj["type"] as? String else { return }
            switch type {
            case "request/header":
                if let d = obj["data"] as? [String: Any],
                   let header = d["header"] as? [String: Any],
                   let config = header["config"] as? [String: Any] {
                    headerProvider = config["provider"] as? String
                    headerModel = config["model"] as? String
                }
            case "assistant/chunk":
                guard let d = obj["data"] as? [String: Any],
                      let chunk = d["chunk"] as? [String: Any] else { return }
                let key = "\(d["turn"] as? Int ?? 0):\(d["step"] as? Int ?? 0)"
                switch chunk["type"] as? String {
                case "usage":
                    if let usage = chunk["usage"] as? [String: Any] {
                        pending[key] = PendingStep(usage: usage,
                                                   seq: (obj["seq"] as? NSNumber)?.int64Value ?? 0,
                                                   time: (obj["time"] as? NSNumber)?.int64Value ?? 0)
                    }
                case "finish":
                    let rs = chunk["replayState"] as? [String: Any]
                    let provider = rs?["provider"] as? String ?? headerProvider
                    let model = rs?["model"] as? String ?? headerModel
                    if let p = pending.removeValue(forKey: key) {
                        emit(usage: p.usage, seq: p.seq, time: p.time,
                             provider: provider, model: model)
                    }
                default:
                    break
                }
            case "assistant/message":
                guard let d = obj["data"] as? [String: Any],
                      let msg = d["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any] else { return }
                let key = "\(d["turn"] as? Int ?? 0):\(d["step"] as? Int ?? 0)"
                let provider = msg["provider"] as? String ?? headerProvider
                let model = msg["model"] as? String ?? headerModel
                if let p = pending.removeValue(forKey: key) {
                    // The message usage is the final sample: it replaces the
                    // early chunk sample instead of double-counting it.
                    emit(usage: usage, seq: (obj["seq"] as? NSNumber)?.int64Value ?? p.seq,
                         time: (obj["time"] as? NSNumber)?.int64Value ?? p.time,
                         provider: provider, model: model)
                } else {
                    emit(usage: usage, seq: (obj["seq"] as? NSNumber)?.int64Value ?? 0,
                         time: (obj["time"] as? NSNumber)?.int64Value ?? 0,
                         provider: provider, model: model)
                }
            default:
                break
            }
        }
        // Steps still in flight at the end of the batch (no finish chunk yet):
        // finalize with the latest request header so a scan never drops the
        // newest step; a later scan's finish chunk is deduped by event_id.
        for (_, p) in pending {
            emit(usage: p.usage, seq: p.seq, time: p.time,
                 provider: headerProvider, model: headerModel)
        }
        return (turns, firstTs, lastTs, firstModel, objectCount)
    }

    // MARK: - Cache mode

    /// Hermes-style delta over `session_projcache.json`: each session's
    /// cumulative `tokenUsage.totals` is diffed against the local
    /// `session_totals` baseline and the positive delta becomes one turn.
    static func scanProjCache(database: any ParserStateStore = Database.shared)
        -> (turns: [TurnRecord], sessions: [SessionInfo]) {
        guard !ToolKind.dsh.sourceIsRemote else { return ([], []) } // local-only source
        guard FileManager.default.fileExists(atPath: projCachePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: projCachePath)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tables = root["tables"] as? [String: Any],
              let sessions = tables["sessions"] as? [String: Any] else { return ([], []) }

        let prevTotals = database.sessionTotals()
        var turns: [TurnRecord] = []
        var sessionInfos: [SessionInfo] = []
        let now = Int64(Date().timeIntervalSince1970)

        for (sid, raw) in sessions {
            guard let entry = raw as? [String: Any],
                  let identity = entry["identity"] as? [String: Any],
                  let rows = entry["rows"] as? [String: Any],
                  let tu = rows["tokenUsage"] as? [String: Any],
                  let tuVal = tu["val"] as? [String: Any],
                  let totals = tuVal["totals"] as? [String: Any] else { continue }
            let input = (totals["uncachedInputTokens"] as? NSNumber)?.int64Value ?? 0
            let output = (totals["outputTokens"] as? NSNumber)?.int64Value ?? 0
            let cacheRead = (totals["cacheReadTokens"] as? NSNumber)?.int64Value ?? 0
            let cacheWrite = (totals["cacheWriteTokens"] as? NSNumber)?.int64Value ?? 0
            let seq = (tu["seq"] as? NSNumber)?.int64Value ?? 0
            let createdAt = sec((identity["createdAt"] as? NSNumber)?.int64Value ?? 0)
            let project = identity["cwd"] as? String
            var title: String?
            var lastPromptAt: Int64 = 0
            if let titleRow = rows["title"] as? [String: Any],
               let t = titleRow["val"] as? String, !t.isEmpty { title = t }
            if let meta = rows["sessionListMetadata"] as? [String: Any],
               let m = meta["val"] as? [String: Any] {
                lastPromptAt = sec((m["lastPromptAt"] as? NSNumber)?.int64Value ?? 0)
            }
            let ts = lastPromptAt > 0 ? lastPromptAt : (createdAt > 0 ? createdAt : now)

            let key = "dsh|\(sid)"
            let prev = prevTotals[key]
            var dIn = input, dOut = output, dCR = cacheRead, dCW = cacheWrite
            if let prev {
                dIn = max(input - prev.input, 0)
                dOut = max(output - prev.output, 0)
                dCR = max(cacheRead - prev.cacheRead, 0)
                dCW = max(cacheWrite - prev.cacheWrite, 0)
            }
            // Baseline is the HIGH-WATER MARK per counter: a source rollback
            // must not lower the origin, or the regrowth beyond the old peak
            // would be re-counted. Advances for every session in the cache
            // (even zero totals) so later usage diffs from a known origin.
            database.setSessionTotals(key, tool: "dsh",
                                     input: max(prev?.input ?? 0, input),
                                     output: max(prev?.output ?? 0, output),
                                     reasoning: 0,
                                     cacheRead: max(prev?.cacheRead ?? 0, cacheRead),
                                     cacheWrite: max(prev?.cacheWrite ?? 0, cacheWrite),
                                     cost: 0, updated: ts)
            if dIn + dOut + dCR + dCW > 0 {
                // No model in the cache: tokens are recorded without a price,
                // exactly like the Hermes source.
                turns.append(TurnRecord(tool: .dsh, sessionID: sid, project: project,
                                        model: nil, ts: ts,
                                        inputTokens: dIn, outputTokens: dOut,
                                        cacheRead: dCR, cacheWrite: dCW,
                                        cost: 0,
                                        eventID: "dsh-cache:\(sid):\(seq):\(input):\(output):\(cacheRead):\(cacheWrite)",
                                        costQuality: "unknown"))
            }
            sessionInfos.append(SessionInfo(tool: .dsh, sessionID: sid, title: title,
                                            project: project, model: nil,
                                            created: createdAt, updated: ts))
        }
        return (turns, sessionInfos)
    }

    // MARK: - Helpers

    /// ms → seconds when the value looks like epoch milliseconds.
    private static func sec(_ value: Int64) -> Int64 {
        value > 1_000_000_000_000 ? value / 1000 : value
    }
}
