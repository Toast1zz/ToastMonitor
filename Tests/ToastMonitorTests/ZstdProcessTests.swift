import XCTest
@testable import ToastMonitor

final class ZstdProcessTests: XCTestCase {
    private func script(_ body: String) throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tm-zstd-\(UUID().uuidString).sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path.path
    }

    func testTimeoutCoversBlockedStdinAndEscalatesPastIgnoredTermination() throws {
        // Self-exit also bounds this regression test against the old implementation.
        let executable = try script("trap '' TERM\nexec /bin/sleep 6")
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertNil(Zstd.decompressUncached(Data(repeating: 0, count: 4 * 1024 * 1024), executable: executable, timeout: 1))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 4.5)
    }

    func testConcurrentPipesPreserveSuccessfulOutput() throws {
        let executable = try script("exec /bin/cat")
        let input = Data(repeating: 65, count: 1024 * 1024)
        XCTAssertEqual(Zstd.decompressUncached(input, executable: executable, timeout: 5), input)
    }
}
