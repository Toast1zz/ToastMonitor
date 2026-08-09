import CryptoKit
import Foundation

/// Verifies signed update metadata without downloading or executing an update.
/// The caller supplies the HTTPS endpoint and the public key shipped by the
/// release process; this avoids inventing a mutable or unsigned default host.
enum UpdateChecker {
    struct AvailableUpdate: Equatable, Sendable {
        let version: String
        let downloadURL: URL
        let sha256: String
    }

    enum CheckError: LocalizedError, Equatable, Sendable {
        case invalidEndpoint
        case invalidResponse
        case responseTooLarge
        case malformedManifest
        case invalidSignature
        case invalidVersion
        case invalidDownloadURL
        case artifactTooLarge
        case network(String)

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint: return "更新地址必须是 HTTPS"
            case .invalidResponse: return "更新服务返回了无效响应"
            case .responseTooLarge: return "更新元数据过大"
            case .malformedManifest: return "更新元数据格式无效"
            case .invalidSignature: return "更新签名校验失败"
            case .invalidVersion: return "更新版本号无效"
            case .invalidDownloadURL: return "更新下载地址必须是 HTTPS"
            case .artifactTooLarge: return "更新文件超过大小限制"
            case .network(let message): return "更新检查失败：\(message)"
            }
        }
    }

    private struct Envelope: Decodable {
        let payload: String
        let signature: String
    }

    private struct Payload: Decodable {
        let version: String
        let downloadURL: URL
        let sha256: String

        enum CodingKeys: String, CodingKey {
            case version
            case downloadURL = "download_url"
            case sha256
        }
    }

    private static let metadataLimit = 256 * 1024
    private static let artifactLimit: Int64 = 512 * 1024 * 1024

    /// Returns a verified update only when its semantic version is newer than
    /// `currentVersion`. No file is downloaded, installed, or executed here.
    static func check(
        endpoint: URL,
        currentVersion: String,
        publicKey: Data,
        timeout: TimeInterval = 10
    ) async throws -> AvailableUpdate? {
        guard isHTTPS(endpoint), endpoint.user == nil else { throw CheckError.invalidEndpoint }
        guard let current = semanticVersion(currentVersion),
              publicKey.count == 32 else { throw CheckError.invalidVersion }
        let data: Data
        let response: URLResponse
        do {
            let result = try await fetch(endpoint, timeout: timeout, limit: metadataLimit)
            data = result.0
            response = result.1
        } catch let error as CheckError {
            throw error
        } catch {
            throw CheckError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let finalURL = http.url, isHTTPS(finalURL) else {
            throw CheckError.invalidResponse
        }
        let envelope: Envelope
        let payload: Payload
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard let payloadData = envelope.payload.data(using: .utf8) else {
                throw CheckError.malformedManifest
            }
            payload = try JSONDecoder().decode(Payload.self, from: payloadData)
        } catch let error as CheckError {
            throw error
        } catch {
            throw CheckError.malformedManifest
        }
        guard validText(envelope.payload, maxBytes: 128 * 1024),
              validText(payload.version, maxBytes: 64),
              let candidate = semanticVersion(payload.version) else {
            throw CheckError.invalidVersion
        }
        // A known current release is a normal no-op, not a signature error.
        guard isNewer(candidate, than: current) else { return nil }
        guard let signature = Data(base64Encoded: envelope.signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: Data(envelope.payload.utf8)) else {
            throw CheckError.invalidSignature
        }
        guard isHTTPS(payload.downloadURL), payload.downloadURL.user == nil,
              validText(payload.sha256, maxBytes: 64),
              payload.sha256.count == 64,
              payload.sha256.allSatisfy({ $0.isHexDigit }) else {
            throw CheckError.invalidDownloadURL
        }
        return AvailableUpdate(version: payload.version,
                               downloadURL: payload.downloadURL,
                               sha256: payload.sha256.lowercased())
    }

    /// Optionally verifies the signed manifest's artifact hash. This method
    /// streams through a temporary file and never opens or executes it.
    static func verifyArtifact(
        at url: URL,
        sha256 expected: String,
        timeout: TimeInterval = 30
    ) async throws -> Bool {
        guard isHTTPS(url), url.user == nil,
              expected.count == 64, expected.allSatisfy({ $0.isHexDigit }) else {
            throw CheckError.invalidDownloadURL
        }
        let boundedTimeout = min(max(timeout, 1), 60)
        var request = URLRequest(url: url)
        request.timeoutInterval = boundedTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let delegate = HTTPSRedirectDelegate(maxBytes: artifactLimit)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = boundedTimeout
        configuration.timeoutIntervalForResource = boundedTimeout
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(for: request)
        } catch {
            if delegate.exceededLimit { throw CheckError.artifactTooLarge }
            throw CheckError.network(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let finalURL = http.url, isHTTPS(finalURL) else {
            throw CheckError.invalidResponse
        }
        let values = try temporaryURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              Int64(size) <= artifactLimit else {
            throw CheckError.artifactTooLarge
        }
        let handle = try FileHandle(forReadingFrom: temporaryURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == expected.lowercased()
    }

    private static func fetch(_ url: URL, timeout: TimeInterval, limit: Int) async throws -> (Data, URLResponse) {
        let boundedTimeout = min(max(timeout, 1), 60)
        var request = URLRequest(url: url)
        request.timeoutInterval = boundedTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let delegate = HTTPSRedirectDelegate(maxBytes: Int64(limit))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = boundedTimeout
        configuration.timeoutIntervalForResource = boundedTimeout
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard data.count <= limit else {
            throw limit == metadataLimit ? CheckError.responseTooLarge : CheckError.artifactTooLarge
        }
        return (data, response)
    }

    private static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil
    }

    private static func validText(_ value: String, maxBytes: Int) -> Bool {
        value.utf8.count <= maxBytes && !value.unicodeScalars.contains {
            $0.value < 0x20 || $0.value == 0x7f
        }
    }

    private static func semanticVersion(_ value: String) -> [Int]? {
        guard validText(value, maxBytes: 64) else { return nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0.allSatisfy { $0.isNumber } }) else {
            return nil
        }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == parts.count ? numbers : nil
    }

    private static func isNewer(_ lhs: [Int], than rhs: [Int]) -> Bool {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }
    private final class LimitState: @unchecked Sendable {
        private let lock = NSLock()
        private var exceeded = false

        func markExceeded() {
            lock.lock()
            exceeded = true
            lock.unlock()
        }

        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return exceeded
        }
    }

    private final class HTTPSRedirectDelegate: NSObject, URLSessionTaskDelegate,
                                               URLSessionDownloadDelegate,
                                               URLSessionDataDelegate, @unchecked Sendable {
        private let maxBytes: Int64?
        private let limitState = LimitState()
        private let dataLock = NSLock()
        private var dataBytes: [Int: Int64] = [:]

        var exceededLimit: Bool {
            limitState.value
        }

        init(maxBytes: Int64? = nil) {
            self.maxBytes = maxBytes
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(.performDefaultHandling, nil)
        }

        private func handleResponse(_ response: URLResponse, taskID: Int,
                                    completionHandler: (URLSession.ResponseDisposition) -> Void) {
            if let maxBytes {
                if response.expectedContentLength > maxBytes {
                    limitState.markExceeded()
                    completionHandler(.cancel)
                    return
                }
                dataLock.lock()
                dataBytes[taskID] = 0
                dataLock.unlock()
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            handleResponse(response, taskID: task.taskIdentifier, completionHandler: completionHandler)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            handleResponse(response, taskID: dataTask.taskIdentifier, completionHandler: completionHandler)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive data: Data) {
            guard let maxBytes else { return }
            dataLock.lock()
            let current = dataBytes[dataTask.taskIdentifier] ?? 0
            let exceeds = data.count > Int(max(0, maxBytes - current))
            if !exceeds {
                dataBytes[dataTask.taskIdentifier] = current + Int64(data.count)
            }
            dataLock.unlock()
            if exceeds {
                limitState.markExceeded()
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: Error?) {
            dataLock.lock()
            dataBytes.removeValue(forKey: task.taskIdentifier)
            dataLock.unlock()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            guard let url = request.url, UpdateChecker.isHTTPS(url), url.user == nil else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            guard let maxBytes,
                  totalBytesWritten > maxBytes
                    || totalBytesExpectedToWrite > maxBytes else { return }
            limitState.markExceeded()
            downloadTask.cancel()
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            // The async download API owns the temporary location and returns it
            // to verifyArtifact; no move is needed here.
        }
    }
}
