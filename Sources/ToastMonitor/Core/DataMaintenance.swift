import Foundation
import Darwin
import Compression
import SQLite3

struct DataRepairReceipt: Equatable, Sendable {
    let backupPath: String
    let removedTurns: Int
    let removedSessions: Int
    let removedTokens: Int64
}

enum DataMaintenance {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("ToastMonitor/Backups", isDirectory: true)
    }

    /// Logs a rebuild can read back: only these sessions are ever removed.
    private static func localLogs() -> (claude: [String], codex: [String]) {
        let claude = ToolKind.claude.sourceIsRemote ? [] :
            (FileScanner.listFiles(ClaudeCodeParser.root, maxDepth: 4)
                + ClaudeCodeParser.listCoworkFiles()).filter { $0.hasSuffix(".jsonl") }
        let codex = ToolKind.codex.sourceIsRemote ? [] :
            FileScanner.listFiles(CodexParser.sessionsRoot, maxDepth: 4).filter { $0.hasSuffix(".jsonl") }
        return (claude, codex)
    }

    static func preview() -> Database.LocalRebuildPreview {
        let logs = localLogs()
        return Database.shared.previewLocalRebuild(claudePaths: logs.claude, codexPaths: logs.codex)
    }

    /// Creates a protected, LZFSE-compressed SQLite snapshot (about a fifth
    /// of the database size), then prunes by `retained(_:)`.
    static func createBackup(label: String = "manual", database: Database = .shared,
                             backupDirectory: URL? = nil, date: Date = Date()) -> String? {
        let directory = backupDirectory ?? Self.directory
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            return nil
        }
        guard label.utf8.count <= 64,
              !label.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            return nil
        }
        let safeLabel = label.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        // Hidden, so a crash mid-backup never leaves a listed leftover.
        let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString).db")
        defer { try? fm.removeItem(at: staging) }
        guard database.backup(to: staging.path, overwrite: false) else { return nil }
        for _ in 0..<8 {
            let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
            let url = directory.appendingPathComponent(
                "toastmonitor-\(String(safeLabel))-\(formatter.string(from: date))-\(suffix).db.\(compressedExtension)")
            if compress(staging, to: url) {
                pruneBackups(in: directory)
                return url.path
            }
            if !fm.fileExists(atPath: url.path) { return nil }
        }
        return nil
    }

    static let compressedExtension = "lzfse"

    private static let routineLock = NSLock()
    nonisolated(unsafe) private static var lastRoutineAttempt: [String: Int64] = [:]

    /// Writes `source` compressed to a private staging file first, verifies
    /// LZFSE header/footer markers, and atomically links into `destination`.
    @discardableResult
    static func compress(_ source: URL, to destination: URL) -> Bool {
        guard let data = NSData(contentsOf: source),
              let packed = try? data.compressed(using: .lzfse) else { return false }
        let packedData = packed as Data
        guard isValidLZFSEBytes(packedData) else { return false }
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".compress-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: packedData)
            try handle.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
        let linked = Darwin.link(temp.path, destination.path) == 0
        try? FileManager.default.removeItem(at: temp)
        return linked
    }

    private static let maxExpandedBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// Expands a compressed backup to a private file via bounded streaming LZFSE.
    static func expand(_ source: URL, to destination: URL) -> Bool {
        guard let input = FileHandle(forReadingAtPath: source.path) else { return false }
        defer { try? input.close() }
        let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { return false }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        memset(stream, 0, MemoryLayout<compression_stream>.size)
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZFSE) == COMPRESSION_STATUS_OK else {
            try? FileManager.default.removeItem(at: destination)
            return false
        }
        defer { compression_stream_destroy(stream) }

        let dstCapacity = 64 * 1024
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
        defer { dstBuffer.deallocate() }

        var totalWritten: Int64 = 0
        var inputEOF = false
        stream.pointee.src_size = 0

        while true {
            var readChunk: Data?
            if stream.pointee.src_size == 0 && !inputEOF {
                readChunk = try? autoreleasepool { try input.read(upToCount: 64 * 1024) }
                if let chunk = readChunk, !chunk.isEmpty {
                    // Processed below via withUnsafeBytes while readChunk stays alive for this iteration.
                } else {
                    inputEOF = true
                }
            }

            let stepStatus: compression_status
            if let chunk = readChunk, !chunk.isEmpty {
                stepStatus = chunk.withUnsafeBytes { rawBuf in
                    let base = rawBuf.bindMemory(to: UInt8.self).baseAddress!
                    stream.pointee.src_ptr = base
                    stream.pointee.src_size = chunk.count
                    var status: compression_status = COMPRESSION_STATUS_OK
                    repeat {
                        stream.pointee.dst_ptr = dstBuffer
                        stream.pointee.dst_size = dstCapacity
                        status = compression_stream_process(stream, 0)
                        let produced = dstCapacity - stream.pointee.dst_size
                        if produced > 0 {
                            totalWritten += Int64(produced)
                            if totalWritten > maxExpandedBytes { return COMPRESSION_STATUS_ERROR }
                            do {
                                try output.write(contentsOf: Data(bytesNoCopy: dstBuffer, count: produced, deallocator: .none))
                            } catch {
                                return COMPRESSION_STATUS_ERROR
                            }
                        }
                    } while status == COMPRESSION_STATUS_OK && (stream.pointee.src_size > 0 || producedAll(dstCapacity, remaining: stream.pointee.dst_size))
                    return status
                }
            } else {
                stream.pointee.src_ptr = UnsafePointer<UInt8>(bitPattern: 1)!
                stream.pointee.src_size = 0
                stream.pointee.dst_ptr = dstBuffer
                stream.pointee.dst_size = dstCapacity
                stepStatus = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = dstCapacity - stream.pointee.dst_size
                if produced > 0 {
                    totalWritten += Int64(produced)
                    if totalWritten > maxExpandedBytes {
                        try? FileManager.default.removeItem(at: destination)
                        return false
                    }
                    do {
                        try output.write(contentsOf: Data(bytesNoCopy: dstBuffer, count: produced, deallocator: .none))
                    } catch {
                        try? FileManager.default.removeItem(at: destination)
                        return false
                    }
                }
            }

            if stepStatus == COMPRESSION_STATUS_END {
                try? output.synchronize()
                return true
            }
            if stepStatus == COMPRESSION_STATUS_ERROR {
                try? FileManager.default.removeItem(at: destination)
                return false
            }
        }
    }

    private static func producedAll(_ capacity: Int, remaining: Int) -> Bool {
        remaining == 0
    }

    private static func isValidLZFSEBytes(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let header = data.prefix(4)
        let validHeaders = [Data("bvx1".utf8), Data("bvx2".utf8), Data("bvxn".utf8)]
        guard validHeaders.contains(header) else { return false }
        return data.suffix(4) == Data("bvx$".utf8)
    }

    /// Compresses backups written before compression existed, keeping their
    /// dates so retention still orders them correctly.
    static func compressLegacyBackups(in directory: URL = DataMaintenance.directory) {
        let fm = FileManager.default
        for url in availableBackups(in: directory) where url.pathExtension == "db" {
            let target = url.appendingPathExtension(compressedExtension)
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard compress(url, to: target) else { continue }
            if let date { try? fm.setAttributes([.modificationDate: date], ofItemAtPath: target.path) }
            try? fm.removeItem(at: url)
        }
    }

    /// Exports a compact snapshot with known legacy credential keys removed.
    /// Private managed backups retain recovery copies; exported usage and
    /// project metadata still require sensitive handling.
    static func exportDatabase(to path: String, database: Database = .shared) -> Bool {
        guard let destination = safeDestination(path, database: database) else { return false }
        let fm = FileManager.default
        do {
            let parent = destination.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            if fm.fileExists(atPath: destination.path) {
                guard (try destination.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true) else {
                    return false
                }
            }
            guard database.exportRedacted(to: destination.path) else { return false }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return true
        } catch {
            return false
        }
    }

    static func repair() throws -> DataRepairReceipt {
        guard !ToolKind.claude.sourceIsRemote || !ToolKind.codex.sourceIsRemote else {
            throw MaintenanceError.noLocalSources
        }
        let logs = localLogs()
        let preview = Database.shared.previewLocalRebuild(claudePaths: logs.claude, codexPaths: logs.codex)
        guard let backup = createBackup(label: "pre-rebuild") else {
            throw MaintenanceError.backupFailed
        }
        guard Database.shared.resetLocalUsage(claudePaths: logs.claude, codexPaths: logs.codex) else {
            throw MaintenanceError.resetFailed(backup)
        }
        return DataRepairReceipt(backupPath: backup,
                                 removedTurns: preview.turns,
                                 removedSessions: preview.sessions,
                                 removedTokens: preview.tokens)
    }
    /// Restores only a regular, non-empty managed backup. Database.restore
    /// performs the SQLite schema/integrity check before replacing live data.
    static func restore(backupPath path: String) -> Bool {
        restoreWithReceipt(backupPath: path) != nil
    }

    /// Replaces a store that cannot be opened. With no backup it starts empty.
    /// The broken file stays beside the new one.
    static func recover(from backup: URL?, database: Database = .shared) -> Bool {
        guard let backup else { return database.replaceUnusableStore(with: nil) }
        guard backup.pathExtension == compressedExtension else {
            guard isSQLiteFile(backup), passesIntegrityCheck(backup) else { return false }
            return database.replaceUnusableStore(with: backup.path)
        }
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory.appendingPathComponent("tm-expand-\(UUID().uuidString)")
        guard (try? fm.createDirectory(at: workspace, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])) != nil else { return false }
        defer { try? fm.removeItem(at: workspace) }
        let expanded = workspace.appendingPathComponent("backup.db")
        guard expand(backup, to: expanded), isSQLiteFile(expanded), passesIntegrityCheck(expanded) else { return false }
        return database.replaceUnusableStore(with: expanded.path)
    }

    private static func passesIntegrityCheck(_ url: URL) -> Bool {
        guard let db = SQLiteReadOnly.open(url.path) else { return false }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check;", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW && SQLiteText.column(stmt, 0) == "ok"
    }

    static func restoreWithReceipt(backupPath path: String, database: Database = .shared,
                                   backupDirectory: URL? = nil) -> String? {
        let directory = backupDirectory ?? Self.directory
        guard isManagedBackup(path, in: directory), isSafeDatabaseFile(path) else { return nil }
        let url = URL(fileURLWithPath: path)
        // A broken store cannot be snapshotted first, and needs no snapshot.
        if database.openProblem != nil {
            return recover(from: url, database: database) ? path : nil
        }
        guard url.pathExtension == compressedExtension else {
            return restore(path, database: database, directory: directory)
        }
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory.appendingPathComponent("tm-expand-\(UUID().uuidString)")
        guard (try? fm.createDirectory(at: workspace, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])) != nil else { return nil }
        defer { try? fm.removeItem(at: workspace) }
        let expanded = workspace.appendingPathComponent("backup.db")
        guard expand(url, to: expanded) else { return nil }
        return restore(expanded.path, database: database, directory: directory)
    }

    private static func restore(_ path: String, database: Database, directory: URL) -> String? {
        var snapshot: String?
        let restored = database.restore(from: path, beforeReplace: {
            snapshot = createBackup(label: "pre-restore", database: database, backupDirectory: directory)
            return snapshot
        })
        return restored ? snapshot : nil
    }

    /// Self-throttled weekly snapshot, independent of collector activity: an
    /// idle week (no new turns/sessions, but settings or subscriptions may
    /// still have changed) must still get backed up, so callers invoke this
    /// unconditionally on every scan tick — the throttle keeps the actual
    /// backup+prune work to once per 7 days. This is the only automatic
    /// backup in the app; `repair()` also creates its
    /// own mandatory pre-operation backup. See `retained(_:)` for rotation.
    static func maybeCreateRoutineBackupIfDue(database: Database = .shared,
                                            backupDirectory: URL? = nil) {
        guard database.isOpen, database.openProblem == nil else { return }
        let directory = backupDirectory ?? Self.directory
        if database.setting("backups_compressed") == nil,
           database.setSetting("backups_compressed", "1") {
            pruneBackups(in: directory)
            compressLegacyBackups(in: directory)
        }
        let now = Int64(Date().timeIntervalSince1970)
        let key = "routine_backup_last"
        let persisted = Int64(database.setting(key) ?? "0") ?? 0
        let dbKey = database.dbPath
        let shouldRun: Bool = routineLock.withLock {
            let last = max(persisted, lastRoutineAttempt[dbKey] ?? 0)
            guard last == 0 || now - last >= 7 * 86400 else { return false }
            lastRoutineAttempt[dbKey] = now
            return true
        }
        guard shouldRun else { return }
        // Only write a weekly backup if the store is writable and recorded the timestamp.
        guard database.setSetting(key, "\(now)") else { return }
        _ = createBackup(label: "weekly", database: database, backupDirectory: directory)
    }

    static func availableBackups(in directory: URL = DataMaintenance.directory) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return urls.filter(isBackupFile).sorted {
            let a = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return a > b

        }
    }
    private static func safeDestination(_ path: String, database: Database = .shared) -> URL? {
        guard !path.isEmpty, path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            return nil
        }
        let destination = URL(fileURLWithPath: path).standardizedFileURL
        guard isSafeExportDestination(destination, databasePath: database.dbPath) else { return nil }
        return destination
    }

    static func isSafeExportDestination(_ destination: URL, databasePath: String) -> Bool {
        let canonical = destination.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(destination.lastPathComponent).standardizedFileURL
        let live = URL(fileURLWithPath: databasePath).resolvingSymlinksInPath().standardizedFileURL
        let protected = Set(["", "-wal", "-shm", "-journal"].map { live.path + $0 })
        guard !protected.contains(canonical.path),
              !protected.contains(canonical.resolvingSymlinksInPath().path) else { return false }
        var sourceInfo = stat()
        var targetInfo = stat()
        if stat(live.path, &sourceInfo) == 0, stat(canonical.path, &targetInfo) == 0,
           sourceInfo.st_dev == targetInfo.st_dev, sourceInfo.st_ino == targetInfo.st_ino {
            return false
        }
        return true
    }

    private static func isSafeDatabaseFile(_ path: String) -> Bool {
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [
            .isRegularFileKey, .fileSizeKey
        ]), values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
            return false
        }
        return true
    }

    /// True when the file carries the SQLite magic header ("SQLite format 3\0").
    /// Corrupt/aborted backup leftovers (partial writes, 0-byte files, foreign
    /// files copied into the directory) must not show up in the backup list or
    /// be considered for rotation.
    static func isSQLiteFile(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return false }
        let magic = Data("SQLite format 3\u{0}".utf8)
        return data.count >= magic.count && data.prefix(magic.count) == magic
    }

    /// A compressed backup (LZFSE block magic "bvx1/2/n" + "bvx$" footer) or a legacy SQLite one.
    static func isBackupFile(_ url: URL) -> Bool {
        switch url.pathExtension {
        case "db": return isSQLiteFile(url)
        case compressedExtension:
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            guard let end = try? handle.seekToEnd(), end >= 8 else { return false }
            try? handle.seek(toOffset: 0)
            guard let header = try? handle.read(upToCount: 4),
                  [Data("bvx1".utf8), Data("bvx2".utf8), Data("bvxn".utf8)].contains(header) else {
                return false
            }
            try? handle.seek(toOffset: end - 4)
            return (try? handle.read(upToCount: 4)) == Data("bvx$".utf8)
        default: return false
        }
    }

    struct BackupInfo: Equatable {
        let url: URL
        let date: Date
        let isRoutine: Bool
        var label = ""
    }

    /// Weekly snapshots: the newest four, plus the newest of each of the
    /// three months before those. Operation snapshots: the newest three of
    /// each label, so restores cannot push out the pre-rebuild copy they may
    /// still need. A year of use stays around a dozen small files.
    static func retained(_ backups: [BackupInfo], calendar: Calendar = .current) -> Set<URL> {
        let newestFirst = backups.sorted { $0.date > $1.date }
        let routine = newestFirst.filter(\.isRoutine)
        var keep = Set(routine.prefix(4).map(\.url))
        var months = Set<DateComponents>()
        for backup in routine.dropFirst(4) {
            let month = calendar.dateComponents([.year, .month], from: backup.date)
            guard months.count < 3, months.insert(month).inserted else { continue }
            keep.insert(backup.url)
        }
        let operations = Dictionary(grouping: newestFirst.filter { !$0.isRoutine }, by: \.label)
        for snapshots in operations.values {
            keep.formUnion(snapshots.prefix(3).map(\.url))
        }
        return keep
    }

    static func pruneBackups(in directory: URL = DataMaintenance.directory) {
        let infos = availableBackups(in: directory).map { url in
            BackupInfo(url: url,
                       date: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                           .contentModificationDate ?? .distantPast,
                       isRoutine: ["weekly", "routine"].contains(managedBackupLabel(for: url)),
                       label: managedBackupLabel(for: url))
        }
        let keep = retained(infos)
        for info in infos where !keep.contains(info.url) {
            try? FileManager.default.removeItem(at: info.url)
        }
    }

    static func managedBackupLabel(for url: URL) -> String {
        let base = url.pathExtension == compressedExtension ? url.deletingPathExtension() : url
        let name = base.deletingPathExtension().lastPathComponent
        let pattern = "^toastmonitor-(.+)-[0-9]{8}-[0-9]{6}(?:-[a-f0-9]{8})?$"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range(at: 1), in: name) else { return name }
        return String(name[range])
    }

    private static func isManagedBackup(_ path: String, in directory: URL = DataMaintenance.directory) -> Bool {
        let candidate = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return candidate.hasPrefix(root)
    }

    enum MaintenanceError: LocalizedError, Equatable, Sendable {
        case noLocalSources
        case backupFailed
        case resetFailed(String)

        var errorDescription: String? {
            switch self {
            case .noLocalSources: return "Claude and Codex are both using remote sources"
            case .backupFailed: return "Could not create the pre-maintenance backup"
            case .resetFailed(let backup): return "Rebuild failed; original data retained. Backup: \(backup)"
            }
        }
    }
}
