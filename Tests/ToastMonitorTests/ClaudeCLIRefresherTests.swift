import XCTest
@testable import ToastMonitor

final class ClaudeCLIRefresherTests: XCTestCase {

    private func makeExecutable(at path: String) {
        FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8))
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    func testLocateBinaryFindsHomeCandidate() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-refresher-home-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: "\(home)/.local/bin", withIntermediateDirectories: true)
        makeExecutable(at: "\(home)/.local/bin/claude")
        defer { try? FileManager.default.removeItem(atPath: home) }

        let found = ClaudeCLIRefresher.locateBinary(env: [:], home: home)
        XCTAssertEqual(found, "\(home)/.local/bin/claude")
    }

    func testLocateBinaryFindsViaPathWhenNoHomeCandidate() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-refresher-home-\(UUID().uuidString)").path
        let binDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-refresher-bin-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        makeExecutable(at: "\(binDir)/claude")
        defer {
            try? FileManager.default.removeItem(atPath: home)
            try? FileManager.default.removeItem(atPath: binDir)
        }

        let found = ClaudeCLIRefresher.locateBinary(env: ["PATH": "\(binDir):/usr/bin"], home: home, fixedCandidates: [])
        XCTAssertEqual(found, "\(binDir)/claude")
    }

    func testLocateBinaryReturnsNilWhenNothingFound() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-refresher-home-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }

        XCTAssertNil(ClaudeCLIRefresher.locateBinary(env: ["PATH": "/nonexistent-dir"], home: home, fixedCandidates: []))
    }

    func testLocateBinaryIgnoresNonExecutableFile() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-refresher-home-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: "\(home)/.local/bin", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: "\(home)/.local/bin/claude", contents: Data("not executable".utf8))
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: "\(home)/.local/bin/claude")
        defer { try? FileManager.default.removeItem(atPath: home) }

        XCTAssertNil(ClaudeCLIRefresher.locateBinary(env: [:], home: home, fixedCandidates: []))
    }
}
