import Foundation
import Security

/// Standard Keychain wrapper: system login keychain, SecItem API.
///
/// The app previously used a self-owned keychain FILE (legacy SecKeychain C
/// API with an embedded password) to avoid prompts. macOS 26 turned that
/// into a maintenance burden — unlock must run on the main thread, ACL calls
/// prompt on every launch, background reads silently fail. We're back to the
/// standard API: the login keychain, first-access authorization prompt
/// included. The old vault file's values are migrated once on launch.
enum KeychainStore {
    static let service = "ToastMonitor"

    static func set(_ value: String, account: String, allowPrompt: Bool = false) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        // Transactional: snapshot the old value, delete, add; restore on
        // failure so a locked/unavailable keychain never destroys the only
        // durable copy of a credential (callers keep plaintext recovery
        // copies only while the keychain write is unconfirmed).
        let old = get(account: account)
        delete(account: account) // avoid errSecDuplicateItem
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let ok = SecItemAdd(query as CFDictionary, nil) == errSecSuccess
        if !ok, let old {
            _ = setRaw(old, account: account)
        }
        return ok
    }

    private static func setRaw(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func get(account: String, allowPrompt: Bool = false) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String, allowPrompt: Bool = false) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
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
        for account in accounts {
            guard get(account: account) == nil else { continue } // already migrated
            guard let legacy = legacyVaultValue(account: account) else { continue }
            guard set(legacy, account: account) else {
                return // Keychain write failed; keep the vault for a retry
            }
        }
        // Every value is now in the login keychain (or was never in the
        // vault); the obsolete file can go.
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ToastMonitor", isDirectory: true)
        let path = dir.appendingPathComponent("toastmonitor.keychain").path
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Reads a value from the legacy vault file. Main thread only (the
    /// legacy unlock requires the main-thread UI session).
    private static func legacyVaultValue(account: String) -> String? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ToastMonitor", isDirectory: true)
        let path = dir.appendingPathComponent("toastmonitor.keychain").path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var kc: SecKeychain?
        guard SecKeychainOpen(path, &kc) == errSecSuccess, let kc else { return nil }
        let pw = "tm-local-vault-2026-08"
        guard SecKeychainUnlock(kc, UInt32(pw.utf8.count), pw, true) == errSecSuccess else { return nil }
        var len: UInt32 = 0
        var dataPtr: UnsafeMutableRawPointer?
        let status = SecKeychainFindGenericPassword(kc, UInt32(service.utf8.count), service,
                                                    UInt32(account.utf8.count), account,
                                                    &len, &dataPtr, nil)
        guard status == errSecSuccess, let dataPtr else { return nil }
        let data = Data(bytes: dataPtr, count: Int(len))
        SecKeychainItemFreeContent(nil, dataPtr)
        return String(data: data, encoding: .utf8)
    }
}
