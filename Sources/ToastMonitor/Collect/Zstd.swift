import Foundation

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
    static func decompress(_ data: Data) -> Data? {
        guard let executable = executablePath() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-d", "-c"]
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return nil
        }

        var outData = Data()
        let drainDone = DispatchGroup()
        drainDone.enter()
        DispatchQueue.global(qos: .utility).async {
            outData = stdout.fileHandleForReading.readDataToEndOfFile()
            drainDone.leave()
        }
        // write(contentsOf:) throws on EPIPE (zstd died early) instead of
        // taking the process down with SIGPIPE.
        try? stdin.fileHandleForWriting.write(contentsOf: data)
        try? stdin.fileHandleForWriting.close()

        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + 30)
        watchdog.setEventHandler { [weak process] in
            process?.terminate()
        }
        watchdog.resume()
        drainDone.wait()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return nil }
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
        let bytes = [UInt8](data)
        guard fromOffset >= 0, fromOffset < Int64(bytes.count) else { return nil }
        var i = Int(fromOffset)
        let end = bytes.count - 4
        while i <= end {
            if bytes[i] == magic[0], bytes[i + 1] == magic[1],
               bytes[i + 2] == magic[2], bytes[i + 3] == magic[3] {
                return Int64(i)
            }
            i += 1
        }
        return nil
    }
}
