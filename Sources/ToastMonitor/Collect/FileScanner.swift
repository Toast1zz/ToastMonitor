import Foundation
import Darwin

/// Incremental JSONL utilities: tracks byte offsets so we only parse appended data.
enum FileScanner {

    private struct FileListCache {
        let files: [String]
        /// Every visited directory is part of the cache key. A changed
        /// directory mtime invalidates the whole traversal, including nested
        /// additions that do not change the root directory's mtime.
        let directoryMTimes: [String: Int64]
    }

    private static let listCacheLock = NSLock()
    private static var listCache: [String: FileListCache] = [:]

    /// Stat info for a file.
    struct Stat {
        let size: Int64
        let mtime: Int64
        /// Stable file identity for rotation/replacement detection.
        let identity: Int64
    }

    static func fileStat(_ path: String) -> Stat? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        let mtime = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        return Stat(size: st.st_size, mtime: mtime, identity: Int64(st.st_ino))
    }

    /// Directory mtime (changes when entries are added/removed).
    static func dirMT(_ path: String) -> Int64? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
    }

    /// Lists JSONL files while reusing a traversal until any visited
    /// directory changes. The cache is keyed by root and depth and validates
    /// every directory mtime, so a new nested file can never remain hidden.
    static func listFiles(_ root: String, maxDepth: Int = 3) -> [String] {
        let cacheKey = "\(root)\u{1F} \(maxDepth)"
        listCacheLock.lock()
        if let cached = listCache[cacheKey],
           cached.directoryMTimes[root] != nil,
           cached.directoryMTimes.allSatisfy({ dirMT($0.key) == $0.value }) {
            let files = cached.files
            listCacheLock.unlock()
            return files
        }
        listCacheLock.unlock()

        var out: [String] = []
        var directories: [String: Int64] = [:]
        var stack: [(String, Int)] = [(root, 0)]
        let fm = FileManager.default
        while let (dir, depth) = stack.popLast() {
            if let mt = dirMT(dir) { directories[dir] = mt }
            guard depth < maxDepth else { continue }
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for e in entries {
                if e.hasPrefix(".") { continue }
                let full = (dir as NSString).appendingPathComponent(e)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    stack.append((full, depth + 1))
                } else if (e as NSString).pathExtension == "jsonl" {
                    out.append(full)
                }
            }
        }
        listCacheLock.lock()
        listCache[cacheKey] = FileListCache(files: out, directoryMTimes: directories)
        listCacheLock.unlock()
        return out
    }


    /// Reads newly appended lines from `path` given the last consumed offset.
    /// Returns parsed JSON objects with their absolute byte offsets (stable
    /// event identity, P0-3) and the new offset. Partial trailing lines are
    /// not consumed; shrunken files rescan from 0.
    ///
    /// NOTE for callers: pass fromOffset = 0 when the file's mtime changed
    /// but its size stayed >= the cursor — an in-place rewrite (edit without
    /// growth) is otherwise invisible and its events are lost. Event ids
    /// derived from uuid/offset make the replay dedupe-safe.
    static func readNewJSONLines(path: String, fromOffset: Int64) -> (objects: [(offset: Int64, obj: [String: Any])], newOffset: Int64) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return ([], fromOffset) }
        defer { fh.closeFile() }
        let total = (try? fh.seekToEnd()) ?? 0
        var start: UInt64 = 0
        if fromOffset > 0 && Int64(total) >= fromOffset {
            start = UInt64(fromOffset)
        } else if fromOffset > 0 {
            start = 0 // file shrank; rescan from top
        }
        guard total > start else { return ([], Int64(total)) }
        fh.seek(toFileOffset: start)
        let data = fh.readDataToEndOfFile()
        // Parse raw bytes instead of first decoding the entire suffix as a
        // String. Replacement characters change byte counts, which can move
        // the persisted cursor past (or before) the next JSON record.
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
                objects.append((offset: Int64(start) + Int64(lineStart), obj: obj))
            } else if !hasNewline {
                // Partial line still being written — do not consume it.
                break
            }
            // Valid JSON, a blank line, and malformed complete lines all
            // advance by their exact original byte length.
            consumed = hasNewline ? lineEnd + 1 : lineEnd
        }
        return (objects, Int64(start) + Int64(consumed))
    }

    /// A truncate followed by a regrow can leave the inode unchanged and the
    /// new file larger than the last cursor. Persisting this marker in the
    /// parser context forces the next scan to reread the header from offset 0.
    static func contextNeedsFullRescan(_ context: String?) -> Bool {
        guard let context,
              let data = context.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (object["_full_rescan"] as? Bool) == true
    }

    static func contextWithFullRescan(_ context: String?, pending: Bool) -> String? {
        var object: [String: Any] = [:]
        if let context,
           let data = context.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = decoded
        }
        if pending {
            object["_full_rescan"] = true
        } else {
            object.removeValue(forKey: "_full_rescan")
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseISO(_ s: String) -> Int64? {
        if let d = isoFormatter.date(from: s) {
            return Int64(d.timeIntervalSince1970)
        }
        if let d = isoFormatterNoFraction.date(from: s) {
            return Int64(d.timeIntervalSince1970)
        }
        return nil
    }

    /// "…-Users-toast1-Documents-Tusi" -> "Tusi" (last path component, "-" = "/").
    static func lastComponentOfEncodedPath(_ s: String) -> String {
        let parts = s.split(separator: "-").map(String.init)
        guard let last = parts.last, !last.isEmpty else { return s }
        return last
    }
}
