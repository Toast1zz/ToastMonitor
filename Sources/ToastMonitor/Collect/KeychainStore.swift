import Foundation
import Security

/// Standard Keychain wrapper: system login keychain, SecItem API.
///
/// The app previously used a self-owned keychain FILE (legacy SecKeychain C
/// API with an embedded password) to avoid prompts. macOS 26 turned that
/// into a maintenance burden — unlock must run on the main thread, ACL calls
/// prompt on every launch, background reads silently fail. We're back to the
/// standard API: reads are non-interactive by default, while explicit
/// provisioning calls may opt into the one-time authorization prompt. The
/// old vault file's values are migrated once on launch.
///
/// "Non-interactive" here means `withoutUserInteraction`, not the SecItem
/// query flags: see that helper for why the flags alone are not enough on a
/// file-based login keychain.
enum KeychainStore {
    static let service = "ToastMonitor"

    // Most recent SecItem result, thread-safe, so clients can tell "not
    // configured" (errSecItemNotFound) apart from "there but unreadable
    // without asking the user" (see authorizationFailures) and surface an
    // actionable message.
    private static let statusLock = NSLock()
    private static var _lastSecStatus: OSStatus = errSecSuccess
    static private(set) var lastSecStatus: OSStatus {
        get { statusLock.lock(); defer { statusLock.unlock() }; return _lastSecStatus }
        set { statusLock.lock(); defer { statusLock.unlock() }; _lastSecStatus = newValue }
    }
    /// True when the last call failed because it was not allowed to ask the
    /// user, rather than because the item is missing. With user interaction
    /// suppressed, a locked keychain reports errSecInteractionNotAllowed and
    /// an ACL that no longer trusts this build reports errSecAuthFailed;
    /// both mean "configured, but unreadable right now".
    static var lastWasInteractionNotAllowed: Bool {
        Self.authorizationFailures.contains(lastSecStatus)
    }

    /// Statuses that mean the item exists but this process was not allowed
    /// to decrypt it without asking the user.
    static let authorizationFailures: Set<OSStatus> = [
        errSecInteractionNotAllowed, errSecInteractionRequired,
        errSecAuthFailed, errSecUserCanceled,
    ]

    private static func recordStatus(_ status: OSStatus) {
        statusLock.lock()
        _lastSecStatus = status
        statusLock.unlock()
    }

    // MARK: - Suppressing the authorization sheet

    /// Serializes SecItem work so the process-wide switch in
    /// `withoutUserInteraction` cannot leak into a concurrent call that
    /// legitimately wants to prompt (the `--provision-*` CLI paths).
    /// Recursive: a non-interactive read reached from inside another one
    /// should nest, not deadlock.
    private static let interactionLock = NSRecursiveLock()

    /// Runs `body` with the process-wide legacy-Keychain UI switch off.
    ///
    /// `kSecUseAuthenticationUI` and `LAContext.interactionNotAllowed` are
    /// only honoured by the data-protection keychain. Items in the
    /// file-based login keychain — ToastMonitor's own, and Claude Code's —
    /// go down the old ACL path, where both are ignored: a query flagged
    /// "non-interactive" still blocks the calling thread behind a
    /// SecurityAgent sheet asking for the login keychain password. Verified
    /// on macOS 27: the same query returns errSecAuthFailed in 11ms with
    /// this switch off, and hangs on a password sheet with it on.
    ///
    /// `SecKeychainSetUserInteractionAllowed` is deprecated and process-wide
    /// — hence the lock and the restore — but it is the only thing that
    /// actually covers that path.
    static func withoutUserInteraction<T>(_ body: () -> T) -> T {
        interactionLock.lock()
        var previous: DarwinBoolean = true
        let readPrevious = SecKeychainGetUserInteractionAllowed(&previous)
        SecKeychainSetUserInteractionAllowed(false)
        defer {
            // Restoring to `true` on a failed read is the safe direction:
            // it can only ever re-enable a prompt the user asked for.
            SecKeychainSetUserInteractionAllowed(readPrevious == errSecSuccess ? previous.boolValue : true)
            interactionLock.unlock()
        }
        return body()
    }

    private static func query(account: String, allowPrompt: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if !allowPrompt {
            // Kept for the data-protection keychain (and for any item that
            // migrates there later), where this flag is the documented way
            // to decline interaction. It does nothing for the login-keychain
            // items we actually store today — withoutUserInteraction is what
            // keeps those silent. Deliberately no LAContext: attaching one
            // re-enters the old ACL decryption path.
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        return query
    }

    static func set(_ value: String, account: String, allowPrompt: Bool = false) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        guard allowPrompt else {
            return withoutUserInteraction { setLocked(data, account: account, allowPrompt: false) }
        }
        return setLocked(data, account: account, allowPrompt: true)
    }

    private static func setLocked(_ data: Data, account: String, allowPrompt: Bool) -> Bool {
        let query = query(account: account, allowPrompt: allowPrompt)
        let update: [String: Any] = [kSecValueData as String: data]

        // Update in place whenever possible. Deleting and re-adding a generic
        // password recreates its ACL, which makes every newly signed local
        // build look like a different Keychain client and prompts again.
        let updated = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        recordStatus(updated)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(add as CFDictionary, nil)
        recordStatus(added)
        if added == errSecSuccess { return true }
        // A concurrent writer may have created the item between the update
        // and add calls; preserve the same in-place semantics in that case.
        if added == errSecDuplicateItem {
            let retry = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            recordStatus(retry)
            return retry == errSecSuccess
        }
        return false
    }

    static func get(account: String, allowPrompt: Bool = false) -> String? {
        var query = query(account: account, allowPrompt: allowPrompt)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let read = { () -> (OSStatus, AnyObject?) in
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result)
        }
        let (status, result) = allowPrompt ? read() : withoutUserInteraction(read)
        recordStatus(status)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String, allowPrompt: Bool = false) {
        let query = query(account: account, allowPrompt: allowPrompt)
        let remove = { SecItemDelete(query as CFDictionary) }
        let status = allowPrompt ? remove() : withoutUserInteraction(remove)
        recordStatus(status)
    }

    // MARK: - Legacy vault migration (one-time)

    /// Older builds stored secrets in a self-owned keychain file
    /// (toastmonitor.keychain with an embedded password). Move those values
    /// into the login keychain on first launch of this build; once every
    /// value is migrated the legacy file is securely removed — it is
    /// protected only by a compile-time password constant, so leaving it
    /// behind would keep credentials readable by any local process.
    static func migrateLegacyVaultIfNeeded() {
        let accounts = ["or-keys", "go-workspace-id", "go-auth-cookie"]
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ToastMonitor", isDirectory: true)
        let path = dir.appendingPathComponent("toastmonitor.keychain").path
        guard FileManager.default.fileExists(atPath: path) else { return }

        var safeToRemove = true
        for account in accounts {
            guard get(account: account) == nil else { continue }
            switch legacyVaultValue(account: account) {
            case .value(let legacy):
                guard set(legacy, account: account) else {
                    return // Keychain write failed; keep the vault for a retry
                }
            case .missing:
                continue
            case .unavailable:
                safeToRemove = false
            }
        }
        // Never delete a legacy vault whose contents could not be inspected.
        // A locked keychain file is a recovery source, not proof of no data.
        if safeToRemove {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private enum LegacyValue {
        case value(String)
        case missing
        case unavailable
    }

    /// Reads a value from the legacy vault file. Main thread only (the
    /// legacy unlock requires the main-thread UI session).
    private static func legacyVaultValue(account: String) -> LegacyValue {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ToastMonitor", isDirectory: true)
        let path = dir.appendingPathComponent("toastmonitor.keychain").path
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        var kc: SecKeychain?
        guard SecKeychainOpen(path, &kc) == errSecSuccess, let kc else { return .unavailable }
        let pw = "tm-local-vault-2026-08"
        guard SecKeychainUnlock(kc, UInt32(pw.utf8.count), pw, true) == errSecSuccess else {
            return .unavailable
        }
        var len: UInt32 = 0
        var dataPtr: UnsafeMutableRawPointer?
        let status = SecKeychainFindGenericPassword(kc, UInt32(service.utf8.count), service,
                                                    UInt32(account.utf8.count), account,
                                                    &len, &dataPtr, nil)
        guard status != errSecItemNotFound else { return .missing }
        guard status == errSecSuccess, let dataPtr else { return .unavailable }
        let data = Data(bytes: dataPtr, count: Int(len))
        SecKeychainItemFreeContent(nil, dataPtr)
        guard let value = String(data: data, encoding: .utf8) else { return .unavailable }
        return .value(value)
    }
}
