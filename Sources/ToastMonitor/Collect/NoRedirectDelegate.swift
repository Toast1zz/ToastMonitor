import Foundation

/// URLSessionTaskDelegate that cancels every redirect. Credential-bearing
/// clients use it so a Bearer token / auth cookie can never be forwarded to
/// a redirect target (https→http downgrade or cross-host redirect).
/// URLSession keeps a weak reference to its delegate, so each client must
/// retain the instance it creates.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
