import CryptoKit
import Foundation

enum EventIdentity {
    static func digest(_ components: [String]) -> String {
        let payload = components.joined(separator: "\u{1f}")
        let hash = SHA256.hash(data: Data(payload.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    static func canonicalJSON(_ value: Any?) -> String {
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func claude(sessionID: String, object: [String: Any], usage: [String: Any],
                       model: String?, timestamp: Int64, offset: Int64) -> String {
        if let message = object["message"] as? [String: Any],
           let messageID = message["id"] as? String, !messageID.isEmpty {
            return "claude:\(sessionID):\(messageID)"
        }
        if let messageID = object["messageId"] as? String, !messageID.isEmpty {
            return "claude:\(sessionID):\(messageID)"
        }
        let message = object["message"] as? [String: Any]
        // The fallback digest is anchored on the stable byte offset, NOT the
        // timestamp: untimestamped rows resolve to Date().now, which changes
        // on every scan and would mint a new digest on each replay. The
        // offset is stable for a given file content, so replays dedupe.
        let stable = digest([
            sessionID,
            String(offset),
            model ?? "",
            canonicalJSON(usage),
            canonicalJSON(message?["content"]),
        ])
        return "claude:\(sessionID):fallback:\(stable)"
    }

    static func codex(sessionID: String, timestamp: Int64, model: String?,
                      usage: [String: Any], offset: Int64) -> String {
        // Two token_count events in the same second with identical
        // last_token_usage collide without the byte offset; including it
        // keeps every turn distinct (ON CONFLICT DO NOTHING would otherwise
        // silently drop one).
        "codex:\(sessionID):\(digest([sessionID, String(timestamp), model ?? "", canonicalJSON(usage), String(offset)]))"
    }

    static func omp(relativePath: String, sessionID: String, object: [String: Any],
                    usage: [String: Any]) -> String {
        if let messageID = object["id"] as? String, !messageID.isEmpty {
            return "omp:\(relativePath):\(messageID)"
        }
        return "omp:\(relativePath):fallback:\(digest([sessionID, canonicalJSON(usage), canonicalJSON(object["message"]), object["timestamp"] as? String ?? ""]))"
    }
}
