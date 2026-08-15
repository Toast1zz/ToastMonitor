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
    static func scanLogs(knownPaths: [String], database: Database = .shared,
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
            let (objs, newOffset) = readObjects(path: file, fromOffset: offset, decompress: decompress)

            if objs.isEmpty {
                // A scan that neither advanced the cursor nor started at 0
                // made no progress: count the stall so a permanently stuck
                // tail eventually forces a full rescan from the file start
                // (where the first magic is the real header frame).
                let noProgress = newOffset == offset && offset > 0
                let stallCount = noProgress ? min(FileScanner.contextStallCount(prev.context) + 1, 3) : 0
                let baseContext = FileScanner.contextWithFullRescan(prev.context,
                                                                    pending: st.size < prev.size || pendingRewrite)
                let context = FileScanner.contextWithStallCount(baseContext, count: stallCount)
                if newOffset == offset && st.size >= prev.size {
                    // Nothing consumable (corrupt tail, zero-length suffix):
                    // keep the cursor and retry on the next append.
                    database.setScanState(file, size: prev.size, mtime: st.mtime,
                                          identity: st.identity, context: context)
                } else {
                    database.setScanState(file, size: newOffset, mtime: st.mtime,
                                          identity: st.identity, context: context)
                }
                continue
            }

            // Session identity lives in the transcript HEADER, which
            // incremental scans never re-read; persist it in scan_state.
            let persisted = (try? JSONSerialization.jsonObject(with: Data((prev.context ?? "").utf8))) as? [String: Any]
            var sessionID = persisted?["sid"] as? String
            var project = persisted?["cwd"] as? String
            var headerCreated: Int64 = 0
            if offset == 0 {
                for item in objs {
                    guard let o = item.obj["type"] as? String, o == "session" else { continue }
                    if let sid = item.obj["id"] as? String, !sid.isEmpty { sessionID = sid }
                    project = item.obj["cwd"] as? String ?? project
                    headerCreated = sec((item.obj["createdAt"] as? NSNumber)?.int64Value ?? 0)
                    break
                }
            }
            guard let sid = sessionID, !sid.isEmpty else {
                // No session identity in the header (and none persisted):
                // content without identity can never be attributed to a
                // session, so advance past it instead of re-reading and
                // re-decompressing the same tail on every scan (O(n²)).
                // Keep prev context — there is no sid to persist.
                database.setScanState(file, size: newOffset, mtime: st.mtime,
                                      identity: st.identity,
                                      context: FileScanner.contextWithStallCount(prev.context, count: 0))
                continue
            }

            let parsed = parseLogEvents(objs, sessionID: sid, project: project)
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

    /// Reads new events from one transcript. `.zstd` files are sliced from the
    /// first complete frame at/after the cursor and decompressed; plain
    /// `.jsonl` files use the shared byte-offset line scan.
    private static func readObjects(path: String, fromOffset: Int64,
                                    decompress: (Data) -> Data?)
        -> (objects: [(offset: Int64, obj: [String: Any])], newOffset: Int64) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return ([], fromOffset) }
        defer { fh.closeFile() }
        guard let total = try? fh.seekToEnd() else { return ([], fromOffset) }
        var start: UInt64 = 0
        if fromOffset > 0 && Int64(total) >= fromOffset {
            start = UInt64(fromOffset)
        } else if fromOffset > 0 {
            start = 0 // file shrank; rescan from top
        }
        guard total > start else { return ([], Int64(total)) }
        fh.seek(toFileOffset: start)
        let data = fh.readDataToEndOfFile()

        guard path.hasSuffix(".zstd") else {
            let (objs, consumed) = parseJSONLLines(data, baseOffset: Int64(start))
            return (objs, Int64(start) + consumed)
        }

        // Independent frames are appended whole, so the cursor always rests on
        // a frame boundary and new data starts at the next magic.
        guard let frameStart = Zstd.nextFrameOffset(in: data, fromOffset: 0) else {
            // Not a zstd stream (or corrupt): do not consume anything.
            return ([], fromOffset > 0 ? fromOffset : Int64(total))
        }
        let slice = data.subdata(in: Int(frameStart)..<data.count)
        if let out = decompress(slice), !out.isEmpty {
            let parsed = parseJSONLLines(out, baseOffset: Int64(start) + frameStart)
            return (parsed.objects, Int64(total))
        }
        // Decompression failed (e.g. crash left a partial tail frame): keep
        // every frame before the first bad one, matching DSH's own recovery.
        return recoverFrames(data: data, baseOffset: Int64(start),
                             fromFrame: frameStart, decompress: decompress)
    }

    /// Walks independent frames one by one, stopping at the first frame that
    /// fails to decompress; the cursor advances only past good frames.
    private static func recoverFrames(data: Data, baseOffset: Int64, fromFrame: Int64,
                                      decompress: (Data) -> Data?)
        -> (objects: [(offset: Int64, obj: [String: Any])], newOffset: Int64) {
        var objects: [(offset: Int64, obj: [String: Any])] = []
        var cursor = fromFrame
        while true {
            guard let magic = Zstd.nextFrameOffset(in: data, fromOffset: cursor) else { break }
            let end = Zstd.nextFrameOffset(in: data, fromOffset: magic + 4) ?? Int64(data.count)
            guard end > magic else { break }
            let slice = data.subdata(in: Int(magic)..<Int(end))
            guard let out = decompress(slice), !out.isEmpty else { break }
            objects.append(contentsOf: parseJSONLLines(out, baseOffset: baseOffset + magic).objects)
            cursor = end
        }
        return (objects, baseOffset + cursor)
    }

    /// Line-scans JSONL bytes (decompressed or plain); a trailing partial line
    /// is not consumed. Returns parsed objects and the consumed byte count.
    private static func parseJSONLLines(_ data: Data, baseOffset: Int64)
        -> (objects: [(offset: Int64, obj: [String: Any])], consumed: Int64) {
        let bytes = [UInt8](data)
        var objects: [(offset: Int64, obj: [String: Any])] = []
        var consumed = 0
        while consumed < bytes.count {
            let lineStart = consumed
            let newline = bytes[consumed...].firstIndex(of: 0x0a)
            let lineEnd = newline ?? bytes.count
            let line = Data(bytes[lineStart..<lineEnd])
            let hasNewline = newline != nil
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                objects.append((offset: baseOffset + Int64(lineStart), obj: obj))
            } else if !hasNewline {
                break // partial line still being written — do not consume it
            }
            consumed = hasNewline ? lineEnd + 1 : lineEnd
        }
        return (objects, Int64(consumed))
    }

    /// Folds a batch of events into per-step turn records.
    /// Per-step `assistant/chunk {type:'usage'}` records are the primary
    /// signal; `assistant/message.usage` is the committed-step fallback and
    /// REPLACES the chunk sample for the same (turn, step) — never added to
    /// it — matching the harness's own token-meter fold.
    private static func parseLogEvents(_ objects: [(offset: Int64, obj: [String: Any])],
                                       sessionID: String, project: String?)
        -> (turns: [TurnRecord], firstTs: Int64, lastTs: Int64, model: String?) {
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

        for item in objects {
            let obj = item.obj
            guard let type = obj["type"] as? String else { continue }
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
                      let chunk = d["chunk"] as? [String: Any] else { continue }
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
                      let usage = msg["usage"] as? [String: Any] else { continue }
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
        return (turns, firstTs, lastTs, firstModel)
    }

    // MARK: - Cache mode

    /// Hermes-style delta over `session_projcache.json`: each session's
    /// cumulative `tokenUsage.totals` is diffed against the local
    /// `session_totals` baseline and the positive delta becomes one turn.
    static func scanProjCache(database: Database = .shared)
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
