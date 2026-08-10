import Foundation
import LocalAuthentication
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
enum KeychainStore {
    static let service = "ToastMonitor"

    private static func query(account: String, allowPrompt: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let context = LAContext()
        context.interactionNotAllowed = !allowPrompt
        query[kSecUseAuthenticationContext as String] = context
        // macOS 26 can still consult legacy ACL UI policy before it honors
        // LAContext. Keep the deprecated compatibility switch explicit so
        // background reads never open a password sheet.
        query[kSecUseAuthenticationUI as String] =
            allowPrompt ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
        return query
    }

    static func set(_ value: String, account: String, allowPrompt: Bool = false) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query = query(account: account, allowPrompt: allowPrompt)
        let update: [String: Any] = [kSecValueData as String: data]

        // Update in place whenever possible. Deleting and re-adding a generic
        // password recreates its ACL, which makes every newly signed local
        // build look like a different Keychain client and prompts again.
        let updated = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(add as CFDictionary, nil)
        if added == errSecSuccess { return true }
        // A concurrent writer may have created the item between the update
        // and add calls; preserve the same in-place semantics in that case.
        if added == errSecDuplicateItem {
            return SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess
        }
        return false
    }


    static func get(account: String, allowPrompt: Bool = false) -> String? {
        var query = query(account: account, allowPrompt: allowPrompt)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String, allowPrompt: Bool = false) {
        let query = query(account: account, allowPrompt: allowPrompt)
        SecItemDelete(query as CFDictionary)
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
