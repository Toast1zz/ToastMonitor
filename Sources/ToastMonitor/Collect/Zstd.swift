import Foundation
import Darwin

/// Best-effort zstd decompression without third-party libraries.
///
/// macOS ships no zstd support (Compression.framework exposes LZ4/ZLIB/LZMA/
/// LZFSE/BROTLI only, and the system libarchive has no public SDK header), so
/// the DeepSeek Harness session logs (`session.jsonl.zstd`) are decompressed
/// through the `zstd` CLI when one can be found. Lookup is a `PATH` search
/// (covers shells and CI) plus the standard Homebrew/MacPorts install
/// locations as a fallback — menu-bar apps launched from Finder/launchd run
/// with the bare system PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), which never
/// contains `/opt/homebrew/bin`. When the CLI is absent every caller degrades
/// gracefully — the DSH collector falls back to the JSON projection cache and
/// simply never advances zstd cursors.
enum Zstd {

    // MARK: - CLI discovery (cached)

    private static let lock = NSLock()
    private static var checked = false
    private static var cachedExecutable: String?

    /// Locations independent of the caller's `PATH`, tried after a PATH hit.
    private static let fixedCandidates = [
        "/opt/homebrew/bin/zstd", // Apple Silicon Homebrew
        "/usr/local/bin/zstd",    // Intel Homebrew
        "/opt/local/bin/zstd",    // MacPorts
        "/usr/bin/zstd",          // system image (rare)
    ]

    /// Absolute path to a `zstd` executable, or nil.
    /// The lookup runs once per process; installs/uninstalls of the CLI are
    /// picked up after a restart (the mode decision is sticky anyway).
    static func executablePath() -> String? {
        lock.lock(); defer { lock.unlock() }
        if checked { return cachedExecutable }
        checked = true
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") where !dir.isEmpty {
            let candidate = (String(dir) as NSString).appendingPathComponent("zstd")
            if FileManager.default.isExecutableFile(atPath: candidate) {
                cachedExecutable = candidate
                return candidate
            }
        }
        for candidate in fixedCandidates where FileManager.default.isExecutableFile(atPath: candidate) {
            cachedExecutable = candidate
            return candidate
        }
        cachedExecutable = nil
        return nil
    }

    /// Decompresses a complete concatenation of zstandard frames.
    /// Returns nil when the CLI is unavailable or the stream is corrupt.
    /// Stdout is drained on a background thread while stdin is written, so a
    /// large session log (whose decompressed size exceeds the pipe buffer)
    /// cannot deadlock; a 30s watchdog terminates a wedged process so the
    /// collector queue is never blocked forever.
    ///
    /// Small results can be reused during a full-rescan metadata/fold pass.
    /// Incremental scans begin at the next unconsumed frame, so they do not
    /// depend on retaining already committed frame results.
    private static let cache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 16 * 1024 * 1024
        cache.countLimit = 8
        return cache
    }()

    static func decompress(_ data: Data) -> Data? {
        // Whole-input cache: key on a cheap content hash. NSCache is
        // thread-safe and evicts under memory pressure.
        let key = NSString(string: "\(data.count):\(data.hashValue)")
        if let hit = cache.object(forKey: key) {
            return hit as Data
        }
        guard let out = decompressUncached(data) else { return nil }
        if out.count <= 8 * 1024 * 1024 { // keep per-entry retention conservative
            cache.setObject(out as NSData, forKey: key, cost: out.count)
        }
        return out
    }

    static func decompressUncached(_ data: Data, executable: String? = nil, timeout: TimeInterval = 30) -> Data? {
        guard let executable = executable ?? executablePath() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-d", "-c"]
        let stdin = Pipe()
        let stdout = Pipe()
        // Killing a decoder can close its input during a blocked write. Keep
        // that failure local to this descriptor instead of raising SIGPIPE.
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { return nil }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        let timedOut = DispatchSemaphore(value: 0)
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + timeout)
        watchdog.setEventHandler { [weak process] in
            timedOut.signal()
            guard let process, process.isRunning else { return }
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak process] in
                if let process, process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
        watchdog.resume()
        defer { watchdog.cancel() }

        var outData = Data()
        let drainDone = DispatchGroup()
        drainDone.enter()
        DispatchQueue.global(qos: .utility).async {
            outData = stdout.fileHandleForReading.readDataToEndOfFile()
            drainDone.leave()
        }
        let writeDone = DispatchGroup()
        writeDone.enter()
        DispatchQueue.global(qos: .utility).async {
            // The deadline covers a decoder that never consumes this input.
            try? stdin.fileHandleForWriting.write(contentsOf: data)
            try? stdin.fileHandleForWriting.close()
            writeDone.leave()
        }
        drainDone.wait()
        process.waitUntilExit()
        writeDone.wait()
        guard timedOut.wait(timeout: .now()) == .timedOut,
              process.terminationStatus == 0 else { return nil }
        return outData
    }

    // MARK: - Frame boundaries

    /// Byte offset of the first zstandard frame magic at or after `fromOffset`.
    ///
    /// The harness writes session logs as independent concatenated frames
    /// (one per durable append batch), each starting with the little-endian
    /// magic `FD 2F B5 28` (bytes `28 B5 2F FD`), so a byte cursor advanced
    /// only past complete frames always rests on a frame boundary and new
    /// frames begin exactly there. Returns nil when no magic exists at/after
    /// the offset (e.g. the file is not zstd at all).
    static func nextFrameOffset(in data: Data, fromOffset: Int64) -> Int64? {
        let magic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
        guard fromOffset >= 0, fromOffset < Int64(data.count), data.count >= 4 else { return nil }
        var i = data.index(data.startIndex, offsetBy: Int(fromOffset))
        let end = data.index(data.endIndex, offsetBy: -4)
        while i <= end {
            if data[i] == magic[0],
               data[data.index(i, offsetBy: 1)] == magic[1],
               data[data.index(i, offsetBy: 2)] == magic[2],
               data[data.index(i, offsetBy: 3)] == magic[3] {
                return Int64(data.distance(from: data.startIndex, to: i))
            }
            data.formIndex(after: &i)
        }
        return nil
    }
}
