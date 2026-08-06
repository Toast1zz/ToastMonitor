import Foundation
import Combine

/// Codex subscription quota via the official ChatGPT backend usage endpoint
/// (same approach as CodexBar / steipete): reads the OAuth token from
/// ~/.codex/auth.json (never persisted anywhere in ToastMonitor) and GETs
/// https://chatgpt.com/backend-api/wham/usage.
///
/// The token lives only in memory for the request; failures are explicit
/// states, never guessed numbers.
@MainActor
final class CodexQuotaClient: ObservableObject {
    static let shared = CodexQuotaClient()

    struct State {
        var planType: String?
        var primaryPct: Int?       // primary_window used_percent
        var windowSeconds: Int?    // limit_window_seconds (604800 = weekly)
        var resetAt: Int64?        // absolute reset time (unix seconds)
        var lastSync: Int64 = 0
        var error: String?
    }

    @Published private(set) var state = State()
    private var timer: Timer?
    private var inFlight = false

    private init() {}

    func start() {
        guard timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let authPath = home.appendingPathComponent(".codex/auth.json").path
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty else {
            state.error = "未找到 Codex 登录态（运行 codex 登录后自动恢复）"
            return
        }

        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else { return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ToastMonitor", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            Task { @MainActor in
                guard let self else { return }
                if let err {
                    self.state.error = err.localizedDescription
                    return
                }
                guard let http = resp as? HTTPURLResponse else {
                    self.state.error = "无 HTTP 响应"
                    return
                }
                guard http.statusCode == 200 else {
                    self.state.error = "usage API HTTP \(http.statusCode)"
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.state.error = "usage 响应解析失败"
                    return
                }
                if let pt = json["plan_type"] as? String {
                    self.state.planType = pt
                }
                if let rl = json["rate_limit"] as? [String: Any] {
                    if let pw = rl["primary_window"] as? [String: Any] {
                        self.state.primaryPct = pw["used_percent"] as? Int
                        self.state.windowSeconds = pw["limit_window_seconds"] as? Int
                        if let reset = pw["reset_at"] as? Int {
                            self.state.resetAt = Int64(reset)
                        }
                    }
                    // secondary_window is null on Plus plans (weekly-only).
                }
                self.state.lastSync = Int64(Date().timeIntervalSince1970)
                self.state.error = nil
            }
        }.resume()
    }
}
