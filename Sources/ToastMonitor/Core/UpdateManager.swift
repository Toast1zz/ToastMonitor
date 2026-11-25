import AppKit
import CryptoKit
import Foundation
import Security

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
    /// Trusted signing Team IDs for in-place updates (supports certificate rotation,
    /// e.g., transitioning from personal Apple Development to Developer ID).
    nonisolated static let trustedTeamIDs: Set<String> = ["N6EN6RZKF2"]

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
    static let installFailureName = "update-install-failure.txt"

    func consumeInstallFailure(reportURL: URL? = nil, executableURL: URL? = Bundle.main.executableURL) {
        let url = reportURL ?? Self.installFailureURL
        guard let message = try? String(contentsOf: url, encoding: .utf8) else { return }
        // A report older than this build is about an update that has since
        // been replaced by hand, so it no longer applies.
        if Self.reportIsStale(url, executable: executableURL) {
            try? FileManager.default.removeItem(at: url)
            return
        }
        lastError = message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clearErrorForTesting() {
        lastError = nil
    }

    nonisolated static func reportIsStale(_ report: URL, executable: URL?) -> Bool {
        func modified(_ url: URL?) -> Date? {
            (try? url?.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        guard let written = modified(report), let built = modified(executable) else { return false }
        return written < built
    }

    private static var installFailureURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ToastMonitor", isDirectory: true)
            .appendingPathComponent(installFailureName)
    }
    /// The replacement acknowledges startup only with its verified version.
    static func acknowledgeLaunch(arguments: [String]) {
        guard let flag = arguments.firstIndex(of: "--tm-update-ready"),
              arguments.indices.contains(flag + 2) else { return }
        let name = arguments[flag + 1]
        let expectedVersion = arguments[flag + 2]
        guard UUID(uuidString: name) != nil,
              UpdateChecker.semanticVersion(expectedVersion) != nil,
              Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String == expectedVersion,
              Bundle.main.bundleURL.pathExtension == "app",
              let pending = try? String(contentsOf: installFailureURL.deletingLastPathComponent()
                .appendingPathComponent("update-pending-\(name)"), encoding: .utf8),
              pending.trimmingCharacters(in: .whitespacesAndNewlines) == expectedVersion else { return }
        let url = installFailureURL.deletingLastPathComponent()
            .appendingPathComponent("update-ready-\(name)")
        try? Data("ready\n".utf8).write(to: url, options: .atomic)
    }

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

    /// Invoked after the user toggles automatic updates ON and the setting has
    /// been persisted, ensuring an immediate check even when the 24h loop was
    /// already started at launch while auto-check was disabled.
    func enableAutoCheckAndCheckNow() {
        if !autoCheckStarted {
            startAutoCheckIfEnabled()
        } else {
            Task { await check(silentFailure: true) }
        }
    }

    /// Manual or automatic check. `force` bypasses the auto setting for the
    /// manual button; `silentFailure` keeps errors from reaching the UI
    /// (auto-checks), while a manual check explains what happened.
    func check(force: Bool = false, silentFailure: Bool = false) async {
        guard !checking, !installing else { return }
        if !force, !Self.autoCheckEnabled { return }
        checking = true
        // Asking again answers the old install report.
        if !silentFailure {
            lastError = nil
            try? FileManager.default.removeItem(at: Self.installFailureURL)
        }
        defer { checking = false }
        do {
            let found = try await UpdateChecker.check(
                endpoint: Self.endpoint,
                currentVersion: currentVersion,
                publicKey: Self.publicKey,
                timeout: 5)
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
            if !silentFailure {
                lastError = Self.friendlyMessage(for: error)
            }
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
            lastError = (error as? LocalizedError)?.errorDescription
                ?? "Update install failed"
        }
    }

    // MARK: - Install machinery

    /// Verify the candidate before handing ownership of its staging directory
    /// to a detached installer. Only that installer cleans the staging files.
    private static func stageAndReplace(archive: URL, version: String) async throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("tm-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        var handedOff = false
        defer {
            try? fm.removeItem(at: archive)
            if !handedOff { try? fm.removeItem(at: staging) }
        }

        // ditto unzips preserving symlinks/permissions; zip bombs are bounded
        // by the earlier SHA-256 artifact size check on the archive itself.
        let unzipStatus = try Self.runProcessSync(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", archive.path, staging.path],
            timeout: 60)
        guard unzipStatus == 0 else {
            throw UpdateChecker.CheckError.malformedManifest
        }

        let candidate = staging.appendingPathComponent("ToastMonitor.app")
        let candidateValues = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard fm.fileExists(atPath: candidate.path),
              candidateValues?.isSymbolicLink != true,
              candidateValues?.isDirectory == true else {
            throw UpdateChecker.CheckError.malformedManifest
        }

        // Re-verify identity beyond the archive hash: signature, bundle id and
        // the manifest version must all match before anything is replaced.
        let runningBundleID = Bundle.main.bundleIdentifier
        var allowedTeams = Self.trustedTeamIDs
        if let runningTeam = Self.teamIdentifier(Bundle.main.bundleURL) {
            allowedTeams.insert(runningTeam)
        }
        guard let runningBundleID,
              Self.verifyCodesign(candidate, allowedTeamIDs: allowedTeams, expectedBundleID: runningBundleID) else {
            throw UpdateChecker.CheckError.invalidSignature
        }
        let candidateBundleID = Bundle(path: candidate.path)?.bundleIdentifier
        guard candidateBundleID == runningBundleID else {
            throw UpdateChecker.CheckError.invalidSignature
        }
        let candidateVersion = Bundle(path: candidate.path)?
            .infoDictionary?["CFBundleShortVersionString"] as? String
        guard candidateVersion == version else {
            throw UpdateChecker.CheckError.invalidVersion
        }
        Self.clearQuarantine(candidate)

        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path),
              fm.isWritableFile(atPath: target.path) else {
            throw InstallerError.readOnlyLocation
        }
        let result = installFailureURL
        try fm.createDirectory(at: result.deletingLastPathComponent(),
                               withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700],
                             ofItemAtPath: result.deletingLastPathComponent().path)
        let token = UUID().uuidString
        let ready = result.deletingLastPathComponent()
            .appendingPathComponent("update-ready-\(token)")
        let pending = result.deletingLastPathComponent()
            .appendingPathComponent("update-pending-\(token)")
        try "\(version)\n".write(to: pending, atomically: true, encoding: .utf8)
        let scriptURL = staging.appendingPathComponent("install.sh")
        try Self.installerScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/bin/bash")
        installer.arguments = [scriptURL.path, target.path, candidate.path,
                               String(ProcessInfo.processInfo.processIdentifier),
                               ready.path, result.path, "/usr/bin/open", version]
        do { try installer.run() } catch {
            try? fm.removeItem(at: pending)
            throw error
        }
        handedOff = true
    }

    private enum InstallerError: LocalizedError {
        case readOnlyLocation
        var errorDescription: String? {
            "ToastMonitor cannot update in this read-only location. Move the app to a writable folder and retry."
        }
    }

    /// Positional paths are argv, not interpolated shell literals. Tests use
    /// an isolated launcher with temp bundles; production uses /usr/bin/open.
    static let installerScript = """
    #!/bin/bash
    set -euo pipefail
    export PATH="/usr/bin:/bin"
    target="$1"
    candidate="$2"
    old_pid="$3"
    ready="$4"
    result="$5"
    launcher="$6"
    staging="$(dirname "$candidate")"
    old="$target.tm-backup"
    incoming="$target.tm-incoming"
    expected_version="$7"
    pending="${ready/update-ready-/update-pending-}"
    report() {
        local temp="$result.tmp.$$"
        if printf '%s\\n' "$1" > "$temp" && mv -f "$temp" "$result"; then :
        else echo "ToastMonitor update error: $1 (unable to write $result)" >&2; fi
        if [ -d "$target" ]; then "$launcher" "$target" >/dev/null 2>&1 || true; fi
    }
    cleanup() { rm -rf "$staging"; rm -f "$pending" "$ready"; }
    trap cleanup EXIT
    for _ in $(seq 1 40); do
        if ! kill -0 "$old_pid" >/dev/null 2>&1; then break; fi
        sleep 0.5
    done
    if kill -0 "$old_pid" >/dev/null 2>&1; then
        report 'Update failed: the running ToastMonitor did not quit. Please try again.'
        exit 1
    fi
    if [ ! -d "$target" ] || [ -e "$old" ] || [ -e "$incoming" ]; then
        report 'Update failed: original app is missing or a prior update needs recovery.'
        exit 1
    fi
    if [ ! -w "$(dirname "$target")" ] || [ ! -w "$target" ]; then
        report 'Update failed: app location is read-only. Move ToastMonitor to a writable folder.'
        exit 1
    fi
    if ! /usr/bin/ditto "$candidate" "$incoming"; then
        rm -rf "$incoming"
        report 'Update failed while copying the new app; the original app was not changed.'
        exit 1
    fi
    if ! mv "$target" "$old"; then
        rm -rf "$incoming"
        report 'Update failed while backing up the original app.'
        exit 1
    fi
    if ! mv "$incoming" "$target"; then
        if ! mv "$old" "$target"; then
            report 'Update failed and rollback failed; the original app is at the .tm-backup path.'
        else
            report 'Update failed while replacing the app; the original app was restored.'
        fi
        exit 1
    fi
    token="${ready##*/update-ready-}"
    if ! "$launcher" -n "$target" --args --tm-update-ready "$token" "$expected_version"; then
        if mv "$target" "$incoming" && mv "$old" "$target"; then
            rm -rf "$incoming"
            report 'Update failed to launch; the original app was restored.'
        else
            report 'Update failed to launch and rollback failed; recover the original app from .tm-backup.'
        fi
        exit 1
    fi
    polls="${TM_UPDATE_READY_POLLS:-120}"
    for _ in $(seq 1 "$polls"); do
        if [ -f "$ready" ]; then
            rm -f "$ready" "$result"
            rm -rf "$old"
            exit 0
        fi
        sleep 0.5
    done
    # The replacement failed to confirm launch in time; terminate any stuck
    # candidate instance at target and roll back so .tm-backup never strands updates.
    target_exec="$target/Contents/MacOS/ToastMonitor"
    while read -r pid comm; do
        if [ "$comm" = "$target_exec" ]; then
            kill "$pid" >/dev/null 2>&1 || true
        fi
    done < <(ps -axo pid=,comm= || true)
    sleep 0.5
    while read -r pid comm; do
        if [ "$comm" = "$target_exec" ]; then
            kill -9 "$pid" >/dev/null 2>&1 || true
        fi
    done < <(ps -axo pid=,comm= || true)
    rm -rf "$incoming"
    if mv "$target" "$incoming" && mv "$old" "$target"; then
        rm -rf "$incoming"
        report 'Update launch was not confirmed; the original app was restored.'
    else
        report 'Update launch was not confirmed and rollback failed; recover the original app from .tm-backup.'
    fi
    exit 1
    """

    nonisolated private static func runProcessSync(executable: URL, arguments: [String], timeout: TimeInterval) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 2) == .timedOut,
               process.isRunning, process.processIdentifier > 0 {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw UpdateChecker.CheckError.malformedManifest
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    nonisolated private static func clearQuarantine(_ url: URL) {
        _ = try? runProcessSync(
            executable: URL(fileURLWithPath: "/usr/bin/xattr"),
            arguments: ["-dr", "com.apple.quarantine", url.path],
            timeout: 10)
    }

    nonisolated static func verifyCodesign(_ app: URL, allowedTeamIDs: Set<String>, expectedBundleID: String) -> Bool {
        guard let actualTeam = teamIdentifier(app),
              allowedTeamIDs.contains(actualTeam) else {
            return false
        }
        return verifyCodesign(app, expectedTeamID: actualTeam, expectedBundleID: expectedBundleID)
    }

    nonisolated static func verifyCodesign(_ app: URL, expectedTeamID: String, expectedBundleID: String) -> Bool {
        guard expectedTeamID.count == 10,
              expectedTeamID.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }),
              !expectedBundleID.isEmpty,
              expectedBundleID.allSatisfy({ $0.isASCII && !$0.isWhitespace && $0 != "\"" && $0 != "\\" }) else {
            return false
        }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return false
        }
        let requirementString = "anchor apple generic and identifier \"\(expectedBundleID)\" and certificate leaf[subject.OU] = \"\(expectedTeamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementString as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            return false
        }
        let flags = SecCSFlags(rawValue:
            kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
        )
        return SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess
    }

    nonisolated static func teamIdentifier(_ app: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }
        var infoRef: CFDictionary?
        let status = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &infoRef
        )
        guard status == errSecSuccess,
              let info = infoRef as? [String: Any],
              let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String,
              teamID.count == 10,
              teamID.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else {
            return nil
        }
        return teamID
    }

    nonisolated static func parseTeamIdentifier(_ output: String) -> String? {
        let prefix = "TeamIdentifier="
        guard let line = output.split(whereSeparator: \.isNewline)
            .first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let teamID = line.dropFirst(prefix.count)
        guard teamID.count == 10,
              teamID.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) })
        else { return nil }
        return String(teamID)
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
