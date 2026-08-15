import CryptoKit
import XCTest
@testable import ToastMonitor

final class UpdateCheckerTests: XCTestCase {

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

    /// The release pipeline's manifest envelope must verify against the app's
    /// baked-in public key: build an envelope the way sign-update-manifest.sh
    /// does, then confirm UpdateChecker's full parse path (base64 payload +
    /// Ed25519 signature + version comparison) accepts it and rejects a
    /// tampered payload.
    func testManifestSignatureRoundTrip() throws {
        let publicKey = UpdateManager.publicKey
        XCTAssertEqual(publicKey.count, 32)
        XCTAssertEqual(UpdateManager.endpoint.scheme, "https")

        // Reconstruct the private key (test-only; the real one is off-device).
        let hex = try String(contentsOfFile: NSHomeDirectory()
            + "/.config/toastmonitor/update-key.pem", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(hex: hex))
        XCTAssertEqual(key.publicKey.rawRepresentation, publicKey,
                       "baked-in public key must match the release signing key")

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
