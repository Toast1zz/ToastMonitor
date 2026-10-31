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

    func testLocateBinaryFindsOtherCLIByName() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-refresher-home-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: "\(home)/.local/bin", withIntermediateDirectories: true)
        makeExecutable(at: "\(home)/.local/bin/claude")
        makeExecutable(at: "\(home)/.local/bin/grok")
        defer { try? FileManager.default.removeItem(atPath: home) }

        let found = ClaudeCLIRefresher.locateBinary(named: "grok", env: [:], home: home, fixedCandidates: [])
        XCTAssertEqual(found, "\(home)/.local/bin/grok")
    }

    func testLocateBinaryFindsGrokFromItsOwnInstaller() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-refresher-home-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: "\(home)/.grok/bin", withIntermediateDirectories: true)
        makeExecutable(at: "\(home)/.grok/bin/grok")
        defer { try? FileManager.default.removeItem(atPath: home) }

        let found = ClaudeCLIRefresher.locateBinary(named: "grok", env: [:], home: home, fixedCandidates: [])
        XCTAssertEqual(found, "\(home)/.grok/bin/grok")
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

    func testQuarantineFlagParsing() {
        // Homebrew-installed, never approved (the real value that triggered the dialog).
        XCTAssertTrue(ClaudeCLIRefresher.quarantineBlocksLaunch("0181;6ada222b;;9604CC98-E333-49CA-AFAA-0FA61756BF20"))
        // Same file after the user approved opening it.
        XCTAssertFalse(ClaudeCLIRefresher.quarantineBlocksLaunch("01c1;6ada222b;;9604CC98-E333-49CA-AFAA-0FA61756BF20"))
        // Unreadable value: assume it would be blocked.
        XCTAssertTrue(ClaudeCLIRefresher.quarantineBlocksLaunch("garbage"))
    }

    func testQuarantineIsReadThroughSymlinks() throws {
        let dir = NSTemporaryDirectory() + "claude-qtn-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let real = "\(dir)/claude-real", link = "\(dir)/claude"
        FileManager.default.createFile(atPath: real, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)

        XCTAssertFalse(ClaudeCLIRefresher.isQuarantined(link))

        let value = Array("0181;6ada222b;;9604CC98-E333-49CA-AFAA-0FA61756BF20".utf8)
        XCTAssertEqual(setxattr(real, "com.apple.quarantine", value, value.count, 0, 0), 0)
        XCTAssertTrue(ClaudeCLIRefresher.isQuarantined(link))
        // An unsigned script is not notarized, so it stays blocked.
        XCTAssertTrue(ClaudeCLIRefresher.launchBlocked(link))
    }

    func testQuarantinedBinaryIsNeverLaunched() throws {
        let dir = NSTemporaryDirectory() + "claude-qtn-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // Launching this would leave a marker file; a quarantined copy must not run.
        let script = "\(dir)/claude", marker = "\(dir)/ran"
        FileManager.default.createFile(atPath: script, contents: Data("#!/bin/sh\ntouch \(marker)\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        let value = Array("0181;6ada222b;;9604CC98-E333-49CA-AFAA-0FA61756BF20".utf8)
        XCTAssertEqual(setxattr(script, "com.apple.quarantine", value, value.count, 0, 0), 0)

        XCTAssertEqual(ClaudeCLIRefresher.refresh(binary: script), .failed("blocked by Gatekeeper"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }
}
