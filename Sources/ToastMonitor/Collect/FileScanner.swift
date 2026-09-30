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

    private final class FileListCacheStore: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: FileListCache] = [:]
    }

    private static let listCache = FileListCacheStore()

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
        listCache.lock.lock()
        if let cached = listCache.values[cacheKey],
           cached.directoryMTimes[root] != nil,
           cached.directoryMTimes.allSatisfy({ dirMT($0.key) == $0.value }) {
            let files = cached.files
            listCache.lock.unlock()
            return files
        }
        listCache.lock.unlock()

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
        listCache.lock.lock()
        listCache.values[cacheKey] = FileListCache(files: out, directoryMTimes: directories)
        listCache.lock.unlock()
        return out
    }


    /// Streams parsed JSON objects from `path` with their absolute byte
    /// offsets (stable event identity, P0-3). Partial trailing lines are not
    /// consumed; shrunken files rescan from 0.
    ///
    /// Pass fromOffset = 0 when the file's mtime changed but its size stayed
    /// >= the cursor — an in-place rewrite is otherwise invisible.

    /// Only the current line is retained, so large initial scans do not
    /// duplicate the entire suffix. The callback runs synchronously.
    @discardableResult
    static func forEachNewJSONLine(path: String, fromOffset: Int64,
                                   _ body: ((offset: Int64, obj: [String: Any])) -> Void) -> Int64 {
        guard let fh = FileHandle(forReadingAtPath: path) else { return fromOffset }
        defer { fh.closeFile() }
        let total = (try? fh.seekToEnd()) ?? 0
        var start: UInt64 = 0
        if fromOffset > 0 && Int64(total) >= fromOffset {
            start = UInt64(fromOffset)
        }
        guard total > start else { return Int64(total) }
        do {
            try fh.seek(toOffset: start)
        } catch {
            return fromOffset
        }
        var pending = Data()
        pending.reserveCapacity(64 * 1024)
        var consumed: UInt64 = 0
        while true {
            let chunk: Data?
            do {
                chunk = try fh.read(upToCount: 64 * 1024)
            } catch {
                break
            }
            guard let chunk, !chunk.isEmpty else { break }
            pending.append(chunk)
            while let newline = pending[pending.startIndex..<pending.endIndex].firstIndex(of: 0x0a) {
                if let obj = try? JSONSerialization.jsonObject(
                    with: pending[pending.startIndex..<newline]) as? [String: Any] {
                    body((offset: Int64(start + consumed), obj: obj))
                }
                let count = pending.distance(from: pending.startIndex, to: newline) + 1
                pending.removeSubrange(pending.startIndex..<pending.index(after: newline))
                consumed += UInt64(count)
            }
        }
        if !pending.isEmpty {
            if let obj = try? JSONSerialization.jsonObject(with: pending) as? [String: Any] {
                body((offset: Int64(start + consumed), obj: obj))
                consumed += UInt64(pending.count)
            }
        }
        // A final complete line without a newline is consumable; malformed
        // unterminated data remains retryable.
        return Int64(start + consumed)
    }

    /// True when `offset` rests on a JSONL line boundary: offset == 0, or
    /// the byte just before it is a newline (0x0A). Incremental parsers
    /// require this of their append-only cursor so a truncate-then-regrow
    /// that was never observed as a shrink (same inode, new file larger than
    /// the old cursor) is detected: the cursor then sits mid-line, which a
    /// genuine append can never produce, and the file is rescanned from 0.
    static func isLineBoundary(path: String, offset: Int64) -> Bool {
        guard offset > 0 else { return true }
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { fh.closeFile() }
        do {
            try fh.seek(toOffset: UInt64(offset - 1))
        } catch {
            return false
        }
        let byte = fh.readData(ofLength: 1)
        return byte.count == 1 && byte[byte.startIndex] == 0x0A
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

    /// Consecutive scans that made no progress on a file (e.g. a zstd frame
    /// boundary parked at a false magic that can never decompress). After 3
    /// stalled scans the parser forces a full rescan from offset 0.
    static func contextStallCount(_ context: String?) -> Int {
        guard let context,
              let data = context.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return 0 }
        return (object["_stall_count"] as? NSNumber)?.intValue ?? 0
    }

    static func contextWithStallCount(_ context: String?, count: Int) -> String? {
        var object: [String: Any] = [:]
        if let context,
           let data = context.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = decoded
        }
        if count > 0 {
            object["_stall_count"] = count
        } else {
            object.removeValue(forKey: "_stall_count")
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private final class ISOFormatterCache: @unchecked Sendable {
        private let lock = NSLock()
        private let fractional: ISO8601DateFormatter
        private let noFraction: ISO8601DateFormatter

        init() {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            self.fractional = fractional
            let noFraction = ISO8601DateFormatter()
            noFraction.formatOptions = [.withInternetDateTime]
            self.noFraction = noFraction
        }

        func date(from string: String) -> Date? {
            lock.lock()
            defer { lock.unlock() }
            return fractional.date(from: string) ?? noFraction.date(from: string)
        }
    }

    private static let isoFormatters = ISOFormatterCache()

    static func parseISO(_ s: String) -> Int64? {
        guard let date = isoFormatters.date(from: s) else { return nil }
        return Int64(date.timeIntervalSince1970)
    }

    /// "…-Users-toast1-Documents-Tusi" -> "Tusi" (last path component, "-" = "/").
    static func lastComponentOfEncodedPath(_ s: String) -> String {
        let parts = s.split(separator: "-").map(String.init)
        guard let last = parts.last, !last.isEmpty else { return s }
        return last
    }
}
