import Foundation

struct DataRepairReceipt: Equatable, Sendable {
    let backupPath: String
    let removedTurns: Int
    let removedSessions: Int
    let removedTokens: Int64
}

enum DataMaintenance {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ToastMonitor/Backups", isDirectory: true)
    }

    static func preview() -> Database.LocalRebuildPreview {
        let tools = [ToolKind.claude, .codex].filter { !$0.sourceIsRemote }
        return Database.shared.previewLocalRebuild(tools: tools)
    }

    /// Creates a protected SQLite snapshot and keeps the newest seven managed
    /// backups. The returned path is safe to present to the user.
    static func createBackup(label: String = "manual") -> String? {
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
        let url = directory.appendingPathComponent("toastmonitor-\(String(safeLabel))-\(formatter.string(from: Date())).db")
        guard Database.shared.backup(to: url.path) else { return nil }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        pruneBackups(keeping: 7)
        return url.path
    }

    /// Exports a full SQLite snapshot to a user-selected destination.
    /// Credentials are not in this database; callers still must treat the
    /// resulting file as sensitive usage and project metadata.
    static func exportDatabase(to path: String) -> Bool {
        guard let destination = safeDestination(path) else { return false }
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
            guard Database.shared.backup(to: destination.path) else { return false }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return true
        } catch {
            return false
        }
    }

    static func repair() throws -> DataRepairReceipt {
        let specs: [(tool: ToolKind, roots: [String])] = [
            (.claude, [ClaudeCodeParser.root]),
            (.codex, [CodexParser.sessionsRoot, CodexParser.stateDBPath]),
        ].filter { !$0.tool.sourceIsRemote }
        guard !specs.isEmpty else { throw MaintenanceError.noLocalSources }
        let preview = Database.shared.previewLocalRebuild(tools: specs.map(\.tool))
        guard let backup = createBackup(label: "pre-rebuild") else {
            throw MaintenanceError.backupFailed
        }
        guard Database.shared.resetLocalUsage(specs) else {
            throw MaintenanceError.resetFailed(backup)
        }
        return DataRepairReceipt(backupPath: backup,
                                 removedTurns: preview.turns,
                                 removedSessions: preview.sessions,
                                 removedTokens: preview.tokens)
    }
    /// Clears usage/history while preserving settings and Keychain credentials.
    /// A managed pre-clear backup is mandatory and returned to the caller.
    static func clearAllData() throws -> String {
        guard let backup = createBackup(label: "pre-clear") else {
            throw MaintenanceError.backupFailed
        }
        guard Database.shared.clearAllData() else {
            throw MaintenanceError.clearFailed(backup)
        }
        return backup
    }

    /// Restores only a regular, non-empty managed backup. Database.restore
    /// performs the SQLite schema/integrity check before replacing live data.
    static func restore(backupPath path: String) -> Bool {
        guard isManagedBackup(path), isSafeDatabaseFile(path) else { return false }
        return Database.shared.restore(from: path)
    }

    /// Self-throttled weekly snapshot, independent of collector activity: an
    /// idle week (no new turns/sessions, but settings or subscriptions may
    /// still have changed) must still get backed up, so callers invoke this
    /// unconditionally on every scan tick — the throttle keeps the actual
    /// backup+prune work to once per 7 days. This is the only automatic
    /// backup in the app; `repair()`/`clearAllData()` each also create their
    /// own mandatory pre-operation backup, sharing the same rotation pool
    /// (newest 7 kept, any label).
    static func maybeCreateRoutineBackupIfDue() {
        let now = Int64(Date().timeIntervalSince1970)
        let key = "routine_backup_last"
        if let last = Int64(Database.shared.setting(key) ?? "0"), now - last < 7 * 86400 { return }
        // Stamped unconditionally after attempting — same pattern as
        // Database.optimizeIfDue/pruneSnapshotsIfDue — so a persistent
        // failure (disk full, directory unwritable) waits for next week's
        // tick instead of retrying the backup on every subsequent scan.
        _ = Database.shared.setSetting(key, "\(now)")
        _ = createBackup(label: "weekly")
    }

    static func availableBackups() -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension == "db" && isSQLiteFile($0) }.sorted {
            let a = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return a > b

        }
    }
    private static func safeDestination(_ path: String) -> URL? {
        guard !path.isEmpty, path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            return nil
        }
        let destination = URL(fileURLWithPath: path).standardizedFileURL
        guard destination.path != Database.shared.dbPath else { return nil }
        return destination
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

    static func pruneBackups(keeping count: Int) {
        for url in availableBackups().dropFirst(max(count, 0)) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func isManagedBackup(_ path: String) -> Bool {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        let root = directory.standardizedFileURL.path + "/"
        return candidate.hasPrefix(root)
    }

    enum MaintenanceError: LocalizedError, Equatable, Sendable {
        case noLocalSources
        case backupFailed
        case resetFailed(String)
        case clearFailed(String)

        var errorDescription: String? {
            switch self {
            case .noLocalSources: return "Claude and Codex are both using remote sources"
            case .backupFailed: return "Could not create the pre-maintenance backup"
            case .resetFailed(let backup): return "Rebuild failed; original data retained. Backup: \(backup)"
            case .clearFailed(let backup): return "Clear failed; original data retained. Backup: \(backup)"
            }
        }
    }
}
