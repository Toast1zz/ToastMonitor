import Foundation

/// Serializes process-global `setenv` / `unsetenv` mutations across XCTest cases.
enum TestEnvironment {
    private static let semaphore = DispatchSemaphore(value: 1)

    @discardableResult
    static func beginScope(_ key: String, value: String?) -> String? {
        semaphore.wait()
        let previous = ProcessInfo.processInfo.environment[key]
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
        return previous
    }

    static func endScope(_ key: String, restoring previous: String?) {
        if let previous {
            setenv(key, previous, 1)
        } else {
            unsetenv(key)
        }
        semaphore.signal()
    }

    static func withVariable<T>(_ key: String, value: String?, body: () throws -> T) rethrows -> T {
        let previous = beginScope(key, value: value)
        defer { endScope(key, restoring: previous) }
        return try body()
    }
}
