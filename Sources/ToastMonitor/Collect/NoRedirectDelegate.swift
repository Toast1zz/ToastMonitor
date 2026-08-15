import Foundation

/// URLSession delegate that cancels every redirect and bounds response bodies.
/// Credential-bearing clients use it so a Bearer token / auth cookie can never
/// be forwarded to a redirect target (https→http downgrade or cross-host
/// redirect). It also rejects chunked/unknown-length bodies once their
/// accumulated bytes exceed the caller's cap; Content-Length alone is not a
/// sufficient memory boundary.
///
/// URLSession keeps a weak reference to its delegate, so each client must
/// retain the instance it creates.
final class NoRedirectDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class TaskState {
        let maxBytes: Int
        let completion: (Data?, URLResponse?, Error?) -> Void
        var response: URLResponse?
        var data = Data()
        var overflowed = false
        /// Set when willPerformHTTPRedirection rejected a redirect for this
        /// task; turns the generic NSURLErrorCancelled into a descriptive
        /// error at completion.
        var redirectBlocked = false

        init(maxBytes: Int, completion: @escaping (Data?, URLResponse?, Error?) -> Void) {
            self.maxBytes = max(1, maxBytes)
            self.completion = completion
        }
    }

    private let lock = NSLock()
    private var tasks: [Int: TaskState] = [:]

    /// Creates and registers a task before it can deliver any delegate
    /// callbacks. The returned task must be resumed by the caller.
    @discardableResult
    func boundedDataTask(in session: URLSession, request: URLRequest,
                         maxBytes: Int,
                         completion: @escaping (Data?, URLResponse?, Error?) -> Void)
        -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        lock.lock()
        tasks[task.taskIdentifier] = TaskState(maxBytes: maxBytes, completion: completion)
        lock.unlock()
        return task
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        tasks[task.taskIdentifier]?.redirectBlocked = true
        lock.unlock()
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let state = tasks[dataTask.taskIdentifier]
        if let state {
            state.response = response
            if response.expectedContentLength > Int64(state.maxBytes) {
                state.overflowed = true
            }
        }
        let overflowed = state?.overflowed ?? false
        lock.unlock()

        if overflowed {
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        lock.lock()
        guard let state = tasks[dataTask.taskIdentifier] else {
            lock.unlock()
            return
        }
        let remaining = state.maxBytes - state.data.count
        if data.count > remaining {
            state.overflowed = true
            lock.unlock()
            dataTask.cancel()
            return
        }
        state.data.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        lock.lock()
        guard let state = tasks.removeValue(forKey: task.taskIdentifier) else {
            lock.unlock()
            return
        }
        let response = state.response
        let data = state.overflowed ? nil : state.data
        let overflowed = state.overflowed
        let redirectBlocked = state.redirectBlocked
        let completion = state.completion
        let maxBytes = state.maxBytes
        lock.unlock()

        if overflowed {
            completion(nil, response, NSError(
                domain: "ToastMonitor.Network",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Response too large (over \(maxBytes) bytes)"]))
        } else if redirectBlocked,
                  let error = error as NSError?,
                  error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled {
            // Rejecting a redirect surfaces as a generic -999 cancellation.
            // Report what actually happened instead of "The operation
            // couldn't be completed." (a redirect was deliberately blocked so
            // a Bearer token / auth cookie is never forwarded).
            completion(nil, response, NSError(
                domain: "ToastMonitor.Network",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Redirect rejected (HTTP redirect cancelled)"]))
        } else {
            completion(data, response, error)
        }
    }
}
