import AppKit
import CryptoKit
import Foundation

/// In-app update flow on top of `UpdateChecker`.
///
/// Wiring:
/// - Auto-check runs once at launch when the `auto_check_updates` setting is
///   enabled (default on). A manual "Check for Updates" button always works.
/// - The update endpoint and Ed25519 public key are baked in by the release
///   process; the private key stays off-device (signing scripts only).
/// - Install: download → SHA-256 verified → unzip → codesign/bundle-id
///   re-verified → replace the running bundle → relaunch. Nothing is ever
///   executed before all three verifications pass.
@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    /// HTTPS metadata endpoint shipped with the app; release artifacts are
    /// attached to GitHub Releases under this fixed name.
    static let endpoint = URL(string: "https://github.com/Toast1zz/ToastMonitor/releases/latest/download/appcast.json")!
    /// Ed25519 public key (raw, 32 bytes) of the release signing key.
    static let publicKey = Data(hex: "4381a84e55358fe6a10dbd58be54a10e7b16b7f7d9b2c290e42ea6c5125b1d70")

    /// Setting key: "1" checks for updates automatically at launch, "0" only
    /// on manual request. Defaults to on when unset.
    static let autoCheckSetting = "auto_check_updates"

    @Published private(set) var checking = false
    @Published private(set) var installing = false
    @Published private(set) var available: UpdateChecker.AvailableUpdate?
    @Published private(set) var lastError: String?
    /// Set whenever a check completes (even with no update), so the UI can
    /// distinguish "up to date" from "never checked".
    @Published private(set) var lastCheckAt: Date?

    private var autoCheckStarted = false

    private init() {}

    static var autoCheckEnabled: Bool {
        Database.shared.setting(autoCheckSetting) ?? "1" == "1"
    }

    /// The version this app reports for comparison (marketing version).
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// Called once at launch; no-op unless the auto-check setting is on.
    func startAutoCheckIfEnabled() {
        guard !autoCheckStarted, Self.autoCheckEnabled else { return }
        autoCheckStarted = true
        Task { await check() }
    }

    /// Manual or automatic check. `force` bypasses the auto setting for the
    /// manual button; auto checks are always non-forced.
    func check(force: Bool = false) async {
        guard !checking, !installing else { return }
        if !force, !Self.autoCheckEnabled { return }
        checking = true
        lastError = nil
        defer { checking = false }
        do {
            let found = try await UpdateChecker.check(
                endpoint: Self.endpoint,
                currentVersion: currentVersion,
                publicKey: Self.publicKey)
            available = found
            lastCheckAt = Date()
        } catch {
            lastError = (error as? UpdateChecker.CheckError)?.errorDescription
                ?? "Update check failed"
            available = nil
        }
    }

    /// Downloads, verifies, swaps in and relaunches the new build. The caller
    /// should only offer this after `available` is set (a verified update).
    func installAndRelaunch() async {
        guard let update = available, !installing else { return }
        installing = true
        lastError = nil
        defer { installing = false }
        do {
            let archive = try await UpdateChecker.downloadArtifact(
                at: update.downloadURL, sha256: update.sha256)
            try await Self.stageAndReplace(archive: archive, version: update.version)
            // Reached only if staging succeeded but relaunch is pending.
            NSApp.terminate(nil)
        } catch {
            lastError = (error as? UpdateChecker.CheckError)?.errorDescription
                ?? "Update install failed"
        }
    }

    // MARK: - Install machinery

    /// Unzips into a staging dir, re-verifies the bundle (codesign + bundle id
    /// + version), swaps it over the running bundle and relaunches via a
    /// detached shell so the replacement survives this process exiting.
    private static func stageAndReplace(archive: URL, version: String) async throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("tm-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // ditto unzips preserving symlinks/permissions; zip bombs are bounded
        // by the earlier SHA-256 artifact size check on the archive itself.
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, staging.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            throw UpdateChecker.CheckError.malformedManifest
        }

        let candidate = staging.appendingPathComponent("ToastMonitor.app")
        guard fm.fileExists(atPath: candidate.path) else {
            throw UpdateChecker.CheckError.malformedManifest
        }

        // Re-verify identity beyond the archive hash: signature, bundle id and
        // the manifest version must all match before anything is replaced.
        guard Self.verifyCodesign(candidate) else {
            throw UpdateChecker.CheckError.invalidSignature
        }
        let candidateBundleID = Bundle(path: candidate.path)?.bundleIdentifier
        let runningBundleID = Bundle.main.bundleIdentifier
        guard candidateBundleID == runningBundleID, let runningBundleID else {
            throw UpdateChecker.CheckError.invalidSignature
        }
        let candidateVersion = Bundle(path: candidate.path)?
            .infoDictionary?["CFBundleShortVersionString"] as? String
        guard candidateVersion == version else {
            throw UpdateChecker.CheckError.invalidVersion
        }

        let target = Bundle.main.bundleURL
        // Detached installer: waits for us to exit, swaps the bundle, relaunches.
        let script = """
        #!/bin/bash
        sleep 1
        rm -rf '\(target.path)'
        ditto '\(candidate.path)' '\(target.path)'
        open '\(target.path)'
        """
        let scriptURL = staging.appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/bin/bash")
        installer.arguments = [scriptURL.path]
        try installer.run()
        installer.waitUntilExit()
        guard installer.terminationStatus == 0 else {
            throw UpdateChecker.CheckError.network("Installer failed to start")
        }
    }

    private static func verifyCodesign(_ app: URL) -> Bool {
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--deep", "--strict", app.path]
        do {
            try verify.run()
            verify.waitUntilExit()
            return verify.terminationStatus == 0
        } catch {
            return false
        }
    }
}

private extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}
