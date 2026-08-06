import Foundation
import Darwin

/// Incremental JSONL utilities: tracks byte offsets so we only parse appended data.
enum FileScanner {

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
        return Int64(st.st_mtimespec.tv_sec)
    }

    static func listFiles(_ root: String, maxDepth: Int = 3) -> [String] {
        var out: [String] = []
        var stack: [(String, Int)] = [(root, 0)]
        let fm = FileManager.default
        while let (dir, depth) = stack.popLast() {
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
        return out
    }

    /// Reads newly appended lines from `path` given the last consumed offset.
    /// Returns parsed JSON objects with their absolute byte offsets (stable
    /// event identity, P0-3) and the new offset. Partial trailing lines are
    /// not consumed; shrunken files rescan from 0.
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

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parseISO(_ s: String) -> Int64? {
        if let d = isoFormatter.date(from: s) {
            return Int64(d.timeIntervalSince1970)
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) {
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
