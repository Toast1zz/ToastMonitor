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

    /// HTTPS metadata endpoint shipped with the app. The signed manifest is
    /// hosted on GitHub Pages (deployed from docs/ on main) and refreshed by
    /// the release process. GitHub Pages serves short-lived cache headers, so
    /// a freshly published manifest is visible to clients within a minute —
    /// unlike raw.githubusercontent.com (long CDN cache) or /releases/latest
    /// (resolution lag), both of which showed stale data in practice.
    static let endpoint = URL(string: "https://toast1zz.github.io/ToastMonitor/appcast.json")!
    /// Ed25519 public key (raw, 32 bytes) of the release signing key.
    static let publicKey = Data(hex: "4381a84e55358fe6a10dbd58be54a10e7b16b7f7d9b2c290e42ea6c5125b1d70")

    /// Setting key: "1" checks for updates automatically at launch, "0" only
    /// on manual request. Defaults to on when unset.
    static let autoCheckSetting = "auto_check_updates"
    /// UserDefaults key remembering the highest version ever offered. A
    /// replayed/rolled-back feed can only serve versions the maintainer has
    /// signed, but a stale manifest (e.g. Pages rollback) must never offer a
    /// version lower than one the user already saw — that would be a silent
    /// downgrade offer.
    static let lastOfferedKey = "last_offered_update_version"

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
    /// Failures are silent: an unavailable feed must never disturb the user,
    /// only a verified newer version may surface. While the app keeps running
    /// (menu-bar apps run for days), a background check repeats at most once
    /// per 24 hours so a new release is noticed without a restart.
    func startAutoCheckIfEnabled() {
        guard !autoCheckStarted else { return }
        autoCheckStarted = true
        Task {
            await check(silentFailure: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
                guard Self.autoCheckEnabled else { continue }
                await check(silentFailure: true)
            }
        }
    }

    /// Manual or automatic check. `force` bypasses the auto setting for the
    /// manual button; `silentFailure` keeps errors from reaching the UI
    /// (auto-checks), while a manual check explains what happened.
    func check(force: Bool = false, silentFailure: Bool = false) async {
        guard !checking, !installing else { return }
        if !force, !Self.autoCheckEnabled { return }
        checking = true
        lastError = nil
        defer { checking = false }
        do {
            let found = try await UpdateChecker.check(
                endpoint: Self.endpoint,
                currentVersion: currentVersion,
                publicKey: Self.publicKey,
                timeout: 5)
            // A verified candidate below the highest version this user was
            // ever offered is a feed rollback, not a real update: suppress it
            // (the same version may be offered again — e.g. after the user
            // dismissed it — so only strictly-lower candidates are rejected).
            if let found {
                let defaults = UserDefaults.standard
                let candidateParts = UpdateChecker.semanticVersion(found.version)
                // A verified candidate below the highest version this user was
                // ever offered is a feed rollback, not a real update: suppress
                // it (the same version may be offered again — e.g. after the
                // user dismissed it — so only strictly-lower candidates are
                // rejected).
                if let lastOffered = defaults.string(forKey: Self.lastOfferedKey)
                    .flatMap(UpdateChecker.semanticVersion),
                    let candidateParts,
                    UpdateChecker.isNewer(lastOffered, than: candidateParts) {
                    available = nil
                    lastCheckAt = Date()
                    return
                }
                // Remember the highest version ever offered.
                if let candidateParts,
                   let lastOffered = defaults.string(forKey: Self.lastOfferedKey)
                    .flatMap(UpdateChecker.semanticVersion) {
                    if UpdateChecker.isNewer(candidateParts, than: lastOffered) {
                        defaults.set(found.version, forKey: Self.lastOfferedKey)
                    }
                } else {
                    defaults.set(found.version, forKey: Self.lastOfferedKey)
                }
            }
            available = found
            lastCheckAt = Date()
        } catch {
            lastError = silentFailure ? nil : Self.friendlyMessage(for: error)
            available = nil
        }
    }

    /// Maps low-level check failures to user-facing copy. A 404 or network
    /// trouble is "couldn't reach the feed", never a raw technical string.
    nonisolated static func friendlyMessage(for error: Error) -> String {
        guard let checkError = error as? UpdateChecker.CheckError else {
            return "Unable to check for updates. Try again later."
        }
        switch checkError {
        case .invalidResponse, .network:
            return "Unable to check for updates — check your connection and try again."
        case .invalidEndpoint, .invalidDownloadURL:
            return "Update service is misconfigured."
        case .malformedManifest, .invalidSignature:
            return "Update feed is invalid. Try again later."
        case .responseTooLarge, .artifactTooLarge:
            return "Update feed is too large."
        case .invalidVersion:
            return "Update version info is invalid."
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
            // ditto + codesign + the installer script each run to completion
            // synchronously; never block the main actor (menu bar freezes).
            try await Task.detached(priority: .userInitiated) {
                try await Self.stageAndReplace(archive: archive, version: update.version)
            }.value
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
        // Detached installer: waits for THIS process to exit (the app calls
        // NSApp.terminate right after this method returns), then swaps the
        // bundle atomically — move the old bundle aside, ditto the new one
        // into place, roll back on failure — and relaunches. The old bundle
        // is kept until the new instance has had time to launch, so a failed
        // swap can never leave the app unlaunchable.
        let script = """
        #!/bin/bash
        set -euo pipefail
        # Give the old process up to 20s to exit; replace only after it is
        # gone so the old and new instances never overlap (double collection,
        # DB contention). If it lingers (terminate blocked), proceed anyway —
        # swapping files under a running process is safe on macOS.
        for _ in $(seq 1 40); do
            if ! pgrep -x ToastMonitor >/dev/null 2>&1; then break; fi
            sleep 0.5
        done
        target='\(target.path)'
        candidate='\(candidate.path)'
        old="$target.tm-backup"
        rm -rf "$old"
        if [ -d "$target" ]; then mv "$target" "$old"; fi
        if ! ditto "$candidate" "$target"; then
            echo "ditto failed; rolling back previous bundle" >&2
            rm -rf "$target"
            mv "$old" "$target"
            exit 1
        fi
        open "$target"
        # Keep the backup until the new instance has launched, then clean up.
        (sleep 8; rm -rf "$old") &
        exit 0
        """
        let scriptURL = staging.appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/bin/bash")
        installer.arguments = [scriptURL.path]
        // Detached on purpose: waiting here would deadlock — the script waits
        // for this process to exit, which only happens after we return.
        try installer.run()
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
