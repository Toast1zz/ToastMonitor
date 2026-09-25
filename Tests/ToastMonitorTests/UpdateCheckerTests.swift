import CryptoKit
import XCTest
@testable import ToastMonitor

final class UpdateCheckerTests: XCTestCase {
    func testTeamIdentifierParsingIsStrict() {
        XCTAssertEqual(UpdateManager.parseTeamIdentifier("Executable=x\nTeamIdentifier=ABCDE12345\n"),
                       "ABCDE12345")
        XCTAssertNil(UpdateManager.parseTeamIdentifier("TeamIdentifier=not-a-team\n"))
        XCTAssertNil(UpdateManager.parseTeamIdentifier("Identifier=com.example\n"))
    }

    func testSemanticVersionParsing() {
        XCTAssertEqual(UpdateChecker.semanticVersion("1.0"), [1, 0])
        XCTAssertEqual(UpdateChecker.semanticVersion("1.2.3"), [1, 2, 3])
        XCTAssertNil(UpdateChecker.semanticVersion("1"))
        XCTAssertNil(UpdateChecker.semanticVersion("1.2.3.4"))
        XCTAssertNil(UpdateChecker.semanticVersion("v1.2"))
        XCTAssertNil(UpdateChecker.semanticVersion("1.x"))
        XCTAssertNil(UpdateChecker.semanticVersion(""))
        XCTAssertNil(UpdateChecker.semanticVersion("1.2-beta"))
    }

    func testIsNewer() {
        XCTAssertTrue(UpdateChecker.isNewer([1, 2], than: [1, 1]))
        XCTAssertFalse(UpdateChecker.isNewer([1, 2, 0], than: [1, 2]), "1.2.0 equals 1.2")
        XCTAssertTrue(UpdateChecker.isNewer([2, 0], than: [1, 9, 9]))
        XCTAssertFalse(UpdateChecker.isNewer([1, 1], than: [1, 1]))
        XCTAssertFalse(UpdateChecker.isNewer([1, 1], than: [1, 2]))
        XCTAssertFalse(UpdateChecker.isNewer([1, 2], than: [1, 2, 1]))
    }

    func testArchitectureDetection() {
        XCTAssertEqual(UpdateChecker.Architecture.from(machine: "arm64"), .arm64)
        XCTAssertEqual(UpdateChecker.Architecture.from(machine: "Apple Silicon"), .arm64)
        XCTAssertEqual(UpdateChecker.Architecture.from(machine: "x86_64"), .x86_64)
    }

    /// The release pipeline's manifest envelope must verify against the
    /// app's baked-in public key. This test builds an envelope the way
    /// sign-update-manifest.sh does — with a SELF-CONTAINED throwaway key
    /// pair, never the release private key — then confirms UpdateChecker's
    /// full parse path (base64 payload + Ed25519 signature + version
    /// comparison) accepts it and rejects a tampered payload. Running it
    /// requires no private key material, so it passes on any machine (CI,
    /// other developers).
    func testManifestSignatureRoundTrip() throws {
        // Independent key pair; the release key stays off-device.
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = Data(key.publicKey.rawRepresentation)
        XCTAssertEqual(publicKey.count, 32)

        let payload = #"{"version":"9.9.9","download_url":"https://example.com/tm.zip","sha256":"\#(String(repeating: "ab", count: 32))"}"#
        let b64 = Data(payload.utf8).base64EncodedString()
        let signature = try key.signature(for: Data(b64.utf8)).base64EncodedString()
        let envelope = UpdateChecker.Envelope(payload: b64, signature: signature)

        // Newer version: returns the update.
        let found = try UpdateChecker.parseEnvelope(envelope, publicKey: publicKey, current: [1, 2])
        XCTAssertEqual(found?.version, "9.9.9")
        XCTAssertEqual(found?.sha256, String(repeating: "ab", count: 32))

        // Same-or-older version: normal no-op, no signature error.
        XCTAssertNil(try UpdateChecker.parseEnvelope(envelope, publicKey: publicKey, current: [9, 9, 9]))

        // Tampered signature must fail.
        let forged = UpdateChecker.Envelope(payload: b64,
                                            signature: Data(base64Encoded: "AAAA")!.base64EncodedString())
        XCTAssertThrowsError(try UpdateChecker.parseEnvelope(forged, publicKey: publicKey, current: [1, 2])) { error in
            XCTAssertEqual(error as? UpdateChecker.CheckError, .invalidSignature)
        }

        // Non-base64 payload must fail as malformed, not crash.
        let broken = UpdateChecker.Envelope(payload: "not-base64!!", signature: signature)
        XCTAssertThrowsError(try UpdateChecker.parseEnvelope(broken, publicKey: publicKey, current: [1, 2])) { error in
            XCTAssertEqual(error as? UpdateChecker.CheckError, .malformedManifest)
        }
    }

    func testArchitectureSpecificManifestSelectsMatchingArtifact() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = Data(key.publicKey.rawRepresentation)
        let armHash = String(repeating: "a1", count: 32)
        let universalHash = String(repeating: "b2", count: 32)
        let payload = """
        {"version":"9.9.9","download_url":"https://example.com/universal.zip","sha256":"\(universalHash)","artifacts":{"arm64":{"download_url":"https://example.com/arm64.zip","sha256":"\(armHash)"},"x86_64":{"download_url":"https://example.com/universal.zip","sha256":"\(universalHash)"}}}
        """
        let b64 = Data(payload.utf8).base64EncodedString()
        let signature = try key.signature(for: Data(b64.utf8)).base64EncodedString()
        let envelope = UpdateChecker.Envelope(payload: b64, signature: signature)

        let arm = try UpdateChecker.parseEnvelope(envelope,
                                                  publicKey: publicKey,
                                                  current: [1, 2],
                                                  architecture: .arm64)
        XCTAssertEqual(arm?.downloadURL.absoluteString, "https://example.com/arm64.zip")
        XCTAssertEqual(arm?.sha256, armHash)

        let intel = try UpdateChecker.parseEnvelope(envelope,
                                                    publicKey: publicKey,
                                                    current: [1, 2],
                                                    architecture: .x86_64)
        XCTAssertEqual(intel?.downloadURL.absoluteString, "https://example.com/universal.zip")
        XCTAssertEqual(intel?.sha256, universalHash)

        // A legacy single-artifact manifest remains valid for newer clients,
        // regardless of the architecture selector.
        let legacyPayload = """
        {"version":"9.9.9","download_url":"https://example.com/universal.zip","sha256":"\(universalHash)"}
        """
        let legacyB64 = Data(legacyPayload.utf8).base64EncodedString()
        let legacySignature = try key.signature(for: Data(legacyB64.utf8)).base64EncodedString()
        let legacyEnvelope = UpdateChecker.Envelope(payload: legacyB64, signature: legacySignature)
        let legacy = try UpdateChecker.parseEnvelope(legacyEnvelope,
                                                     publicKey: publicKey,
                                                     current: [1, 2],
                                                     architecture: .x86_64)
        XCTAssertEqual(legacy?.downloadURL.absoluteString, "https://example.com/universal.zip")
        XCTAssertEqual(legacy?.sha256, universalHash)
    }

    /// Offline verification of the SHIPPED manifest against the baked-in
    /// public key: the payload/signature below are the exact values published
    /// in the repository's appcast.json (and the live GitHub Pages feed).
    /// No private key is needed, so this runs everywhere. When the release
    /// key rotates, update this fixture to the current appcast.json values.
    func testPublishedAppcastVerifiesAgainstBakedInKey() throws {
        let envelope = UpdateChecker.Envelope(
            payload: "eyJ2ZXJzaW9uIjoiMS4zLjEiLCJkb3dubG9hZF91cmwiOiJodHRwczovL2dpdGh1Yi5jb20vVG9hc3QxenovVG9hc3RNb25pdG9yL3JlbGVhc2VzL2Rvd25sb2FkL3YxLjMuMS9Ub2FzdE1vbml0b3ItMS4zLjEtdW5pdmVyc2FsLnppcCIsInNoYTI1NiI6IjI4MzM4ZTkxMjgyNjA1MGVhYzg2Y2MwODYyM2I2NThiM2YwYThkMTg4Y2VhMGUwZGFmMDE0NGEyMmIyMmMwNWEifQ==",
            signature: "JHdZq3UBlDjIPnCd1ayVts0MNztSKonpW9FEKAhvt+jn/3OA55GNdY3lxAKQCIhvHgrui59cNxcx+/dTCmEUBw==")
        // current [1, 0] < 1.3.1: parseEnvelope must pass signature + version
        // checks and return the update — a failure here means either the
        // baked-in key or the published manifest is broken.
        let found = try UpdateChecker.parseEnvelope(envelope, publicKey: UpdateManager.publicKey, current: [1, 0])
        XCTAssertEqual(found?.version, "1.3.1")
        XCTAssertEqual(found?.sha256, "28338e912826050eac86cc08623b658b3f0a8d188cea0e0daf0144a22b22c05a")
    }

    /// Failures surface user-friendly copy, never raw technical strings, and a
    /// reachable-but-404 feed reads as a connectivity problem.
    func testFriendlyMessages() {
        let network = UpdateManager.friendlyMessage(for: UpdateChecker.CheckError.network("boom"))
        XCTAssertTrue(network.contains("Unable to check"))
        XCTAssertFalse(network.contains("boom"))

        let invalidResponse = UpdateManager.friendlyMessage(for: UpdateChecker.CheckError.invalidResponse)
        XCTAssertTrue(invalidResponse.contains("Unable to check"))
        XCTAssertFalse(invalidResponse.contains("invalid"))

        XCTAssertTrue(UpdateManager.friendlyMessage(for: UpdateChecker.CheckError.invalidSignature).contains("invalid"))
        XCTAssertTrue(UpdateManager.friendlyMessage(for: UpdateChecker.CheckError.malformedManifest).contains("invalid"))
        XCTAssertFalse(UpdateManager.friendlyMessage(for: UpdateChecker.CheckError.malformedManifest).contains("Unable"))
    }

    @MainActor
    func testInstallerWaitsForParentExitThenReplacesAndAcknowledges() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        try fixture.createApp(fixture.target, version: "old")
        try fixture.createApp(fixture.candidate, version: "new")
        try fixture.createLauncher(success: true)
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        parent.arguments = ["1"]
        try parent.run()
        let installer = try fixture.start(parentPID: parent.processIdentifier)
        XCTAssertEqual(try fixture.version(fixture.target), "old", "installer must wait for parent exit")
        parent.waitUntilExit()
        installer.waitUntilExit()
        XCTAssertEqual(installer.terminationStatus, 0)
        XCTAssertEqual(try fixture.version(fixture.target), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.result.path))
    }

    @MainActor
    func testInstallerReportsMissingTargetWithoutDiscardingCandidateElsewhere() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        try fixture.createApp(fixture.candidate, version: "new")
        try fixture.createLauncher(success: true)
        let installer = try fixture.start(parentPID: 999_999_999)
        installer.waitUntilExit()
        XCTAssertNotEqual(installer.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
        XCTAssertTrue(try String(contentsOf: fixture.result).contains("original app is missing"))
    }

    @MainActor
    func testInstallerRestoresOldAppAndRecordsLaunchFailure() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        try fixture.createApp(fixture.target, version: "old")
        try fixture.createApp(fixture.candidate, version: "new")
        try fixture.createLauncher(success: false)
        let installer = try fixture.start(parentPID: 999_999_999)
        installer.waitUntilExit()
        XCTAssertNotEqual(installer.terminationStatus, 0)
        XCTAssertEqual(try fixture.version(fixture.target), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
        XCTAssertTrue(try String(contentsOf: fixture.result).contains("original app was restored"))
    }

    @MainActor
    func testInstallerPreservesExistingBackupRatherThanOverwritingRecovery() throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        try fixture.createApp(fixture.target, version: "old")
        try fixture.createApp(fixture.backup, version: "recovery")
        try fixture.createApp(fixture.candidate, version: "new")
        try fixture.createLauncher(success: true)
        let installer = try fixture.start(parentPID: 999_999_999)
        installer.waitUntilExit()
        XCTAssertNotEqual(installer.terminationStatus, 0)
        XCTAssertEqual(try fixture.version(fixture.target), "old")
        XCTAssertEqual(try fixture.version(fixture.backup), "recovery")
        XCTAssertTrue(try String(contentsOf: fixture.result).contains("prior update needs recovery"))
    }
    @MainActor
    func testLaunchFailureReportSurvivesNextStartup() throws {
        let failureURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ToastMonitor/\(UpdateManager.installFailureName)")
        let previous = try? Data(contentsOf: failureURL)
        defer {
            if let previous { try? previous.write(to: failureURL, options: .atomic) }
            else { try? FileManager.default.removeItem(at: failureURL) }
        }
        try FileManager.default.createDirectory(at: failureURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("Update failed while replacing the app.\n".utf8).write(to: failureURL)
        let updates = UpdateManager.shared
        updates.consumeInstallFailure()
        XCTAssertEqual(updates.lastError, "Update failed while replacing the app.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: failureURL.path))
    }

}

@MainActor
private final class InstallerFixture {
    let root: URL
    let staging: URL
    let candidate: URL
    let target: URL
    let backup: URL
    let ready: URL
    let pending: URL
    let result: URL
    let launcher: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tm-installer-tests-\(UUID().uuidString)")
        staging = root.appendingPathComponent("stage")
        candidate = staging.appendingPathComponent("ToastMonitor.app")
        target = root.appendingPathComponent("installed/ToastMonitor.app")
        backup = root.appendingPathComponent("installed/ToastMonitor.app.tm-backup")
        ready = root.appendingPathComponent("update-ready-\(UUID().uuidString)")
        pending = root.appendingPathComponent("update-pending-\(ready.lastPathComponent.dropFirst("update-ready-".count))")
        result = root.appendingPathComponent("failure.txt")
        launcher = root.appendingPathComponent("launcher.sh")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func createApp(_ url: URL, version: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try version.write(to: url.appendingPathComponent("version"), atomically: true, encoding: .utf8)
    }

    func version(_ url: URL) throws -> String {
        try String(contentsOf: url.appendingPathComponent("version"), encoding: .utf8)
    }

    func createLauncher(success: Bool) throws {
        let body = success
            ? "#!/bin/bash\nprintf 'ready\\n' > '\(ready.path)'\n"
            : "#!/bin/bash\nexit 1\n"
        try body.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
    }

    func start(parentPID: Int32) throws -> Process {
        let script = staging.appendingPathComponent("install.sh")
        try UpdateManager.installerScript.write(to: script, atomically: true, encoding: .utf8)
        try "9.9.9\n".write(to: pending, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, target.path, candidate.path, String(parentPID),
                             ready.path, result.path, launcher.path, "9.9.9"]
        try process.run()
        return process
    }
}

private extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            bytes.append(UInt8(hex[i..<j], radix: 16) ?? 0)
            i = j
        }
        self.init(bytes)
    }
}
