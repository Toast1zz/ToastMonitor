import Foundation

/// Platform billing is an experimental, authenticated website API. It is not
/// inferred from wallet deltas or local session logs.
enum DeepSeekBilling {
    static let maxResponseBytes = 5_000_000
    static let platformOrigin = "https://platform.deepseek.com"
    static let exchangeRateKey = "deepseek_cny_per_usd"
    // User-adjustable accounting rate, not a live market quote.
    static let defaultCNYPerUSD = 7.0

    static func validExchangeRate(_ rate: Double) -> Bool {
        rate.isFinite && (0.01...1000).contains(rate)
    }

    enum Failure: Error, Equatable, LocalizedError {
        case invalidCredential, expired, network, http(Int), invalidResponse, keychain
        case business(Int), schema(String), invalidAmount
        var errorDescription: String? {
            switch self {
            case .invalidCredential: return "Invalid DeepSeek credential"
            case .expired: return "DeepSeek sign-in expired. Reconnect your account."
            case .network: return "DeepSeek connection failed"
            case .http(let code): return "DeepSeek returned HTTP \(code)"
            case .invalidResponse: return "DeepSeek billing response unavailable or unsupported"
            case .keychain: return "Keychain access failed. Credentials were not changed."
            case .business(let code): return "DeepSeek rejected the billing request (code \(code))."
            case .schema(let field): return "DeepSeek billing response format mismatch: \(field)."
            case .invalidAmount: return "DeepSeek returned an unsupported wallet or cost amount."
            }
        }
    }

    static func failure(_ error: Error) -> Failure {
        if let failure = error as? Failure { return failure }
        let path: [any CodingKey]
        switch error {
        case DecodingError.keyNotFound(let key, let context): path = context.codingPath + [key]
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context),
             DecodingError.dataCorrupted(let context): path = context.codingPath
        default: return .invalidResponse
        }
        // Only schema identifiers from our own DTOs may leave the decoder.
        let allowed: Set<String> = ["code", "data", "biz_code", "biz_data", "normal_wallets", "bonus_wallets",
                                    "balance", "currency", "series", "buckets", "time", "cost", "is_available",
                                    "balance_infos", "total_balance", "granted_balance", "topped_up_balance"]
        let fields = path.compactMap { key in allowed.contains(key.stringValue) ? key.stringValue : nil }
        return .schema(fields.isEmpty ? "JSON envelope" : fields.joined(separator: "."))
    }

    struct Credential: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case platform, apiKey }
        let kind: Kind
        let secret: String

        static func make(_ raw: String, kind: Kind) throws -> Credential {
            guard raw.utf8.count <= 16_384 else { throw Failure.invalidCredential }
            var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if kind == .platform, let data = token.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
                if let string = object as? String {
                    token = string
                } else if let dictionary = object as? [String: Any] {
                    token = ["value", "token", "access_token", "accessToken", "userToken"]
                        .compactMap { dictionary[$0] as? String }.first ?? ""
                } else { token = "" }
            }
            guard (20...16_384).contains(token.utf8.count),
                  token.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }),
                  !token.contains("\""), !token.contains("\\") else { throw Failure.invalidCredential }
            return Credential(kind: kind, secret: token)
        }
    }

    struct Money: Equatable, Sendable {
        let currency: String
        let amount: Decimal
        var formatted: String {
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
            return "\(currency) \(formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "-")"
        }
    }

    static func combinedSpend(localUSD: Double, coveredLocalUSD: Double = 0, spend: Spend?,
                              cnyPerUSD: Double = defaultCNYPerUSD) -> String {
        var amounts: [String: Decimal] = [:]
        let local = max(0, localUSD - (spend == nil ? 0 : coveredLocalUSD))
        amounts["USD"] = Decimal(local)
        let rate = Decimal(validExchangeRate(cnyPerUSD) ? cnyPerUSD : defaultCNYPerUSD)
        for money in spend?.amounts ?? [] {
            if money.currency == "CNY" {
                amounts["USD", default: 0] += money.amount / rate
            } else {
                amounts[money.currency, default: 0] += money.amount
            }
        }
        let reportedCurrencies = Set(spend?.amounts.map { $0.currency == "CNY" ? "USD" : $0.currency } ?? [])
        let currencies = amounts.keys.filter { amounts[$0] != 0 || reportedCurrencies.contains($0) }
        guard !currencies.isEmpty else { return "—" }
        return currencies.sorted { lhs, rhs in
            if lhs == "USD" { return rhs != "USD" }
            if rhs == "USD" { return false }
            return lhs < rhs
        }
        .map { code in
            let formatted = Money(currency: code, amount: amounts[code, default: 0]).formatted
            return code == "USD" ? "$" + formatted.dropFirst(4) : formatted
        }.joined(separator: " + ")
    }

    struct Wallet: Equatable, Sendable {
        let currency: String
        let paid: Decimal
        let granted: Decimal
        var total: Money { Money(currency: currency, amount: paid + granted) }
    }

    struct Balance: Equatable, Sendable {
        let wallets: [Wallet]
        let available: Bool
        var formatted: String {
            wallets.isEmpty ? "No balance" : wallets.map { $0.total.formatted }.joined(separator: " / ")
        }
    }

    /// DeepSeek's daily buckets use a fixed UTC offset, not a DST-aware zone.
    /// Convert the selected civil dates into that offset before querying.
    struct Window: Hashable, Sendable {
        let start: Int64
        let end: Int64
        let offset: Int

        static func make(slot: UsagePeriodSlot, configuration: UsagePeriodConfiguration,
                         now: Date, timeZone: TimeZone = .current) -> Window? {
            guard slot != .all else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            let offset = timeZone.secondsFromGMT(for: now)
            calendar.timeZone = TimeZone(secondsFromGMT: offset) ?? .gmt
            calendar.firstWeekday = configuration.weekStart == .monday ? 2 : 1
            let today = calendar.startOfDay(for: now)
            let start: Date
            switch slot {
            case .today: start = today
            case .week:
                let days = configuration.mode == .recent ? 6
                    : (calendar.component(.weekday, from: today) - calendar.firstWeekday + 7) % 7
                start = calendar.date(byAdding: .day, value: -days, to: today) ?? today
            case .month:
                start = configuration.mode == .recent
                    ? calendar.date(byAdding: .day, value: -29, to: today) ?? today
                    : calendar.dateInterval(of: .month, for: today)?.start ?? today
            case .all: return nil
            }
            let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
            return Window(start: Int64(start.timeIntervalSince1970),
                          end: Int64(end.timeIntervalSince1970), offset: offset)
        }

        var timeZoneLabel: String {
            String(format: "UTC%@%02d:%02d", offset < 0 ? "-" : "+", abs(offset) / 3600, abs(offset) % 3600 / 60)
        }
    }

    struct Spend: Equatable, Sendable {
        let window: Window
        let amounts: [Money]
        var formatted: String {
            amounts.isEmpty ? "No billed usage" : amounts.map(\.formatted).joined(separator: " / ")
        }
    }

    static func request(credential: Credential, window: Window? = nil) throws -> URLRequest {
        let url: URL
        if let window {
            guard credential.kind == .platform, window.end > window.start,
                  window.end - window.start <= 32 * 86_400, abs(window.offset) <= 18 * 3600 else {
                throw Failure.invalidResponse
            }
            var components = URLComponents(string: platformOrigin + "/api/v0/usage/by_api_key/cost")!
            components.queryItems = [URLQueryItem(name: "start", value: String(window.start)),
                                    URLQueryItem(name: "end", value: String(window.end)),
                                    URLQueryItem(name: "tz", value: String(window.offset))]
            url = components.url!
        } else {
            url = URL(string: credential.kind == .platform
                      ? platformOrigin + "/api/v0/users/get_user_summary"
                      : "https://api.deepseek.com/user/balance")!
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(credential.secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if credential.kind == .platform { request.setValue("web", forHTTPHeaderField: "x-client-platform") }
        return request
    }

    private struct Amount: Decodable {
        let value: Decimal
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                guard string.count <= 64,
                      string.range(of: #"^-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]{1,3})?$"#, options: .regularExpression) != nil,
                      let parsed = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) else {
                    throw Failure.invalidAmount
                }
                value = parsed
            } else { value = try container.decode(Decimal.self) }
            try Self.check(value)
        }
        static func check(_ value: Decimal) throws {
            guard !value.isNaN, value >= -1_000_000_000_000, value <= 1_000_000_000_000 else {
                throw Failure.invalidResponse
            }
        }
    }

    private struct Envelope<T: Decodable>: Decodable {
        let value: T
        enum Keys: String, CodingKey { case code, data, biz_code, biz_data }
        init(from decoder: Decoder) throws {
            let top = try decoder.container(keyedBy: Keys.self)
            try Self.check(try top.decode(Int.self, forKey: .code))
            let nested = try top.nestedContainer(keyedBy: Keys.self, forKey: .data)
            try Self.check(try nested.decode(Int.self, forKey: .biz_code))
            value = try nested.decode(T.self, forKey: .biz_data)
        }
        static func check(_ code: Int) throws {
            if code == 40002 || code == 40003 { throw Failure.expired }
            guard code == 0 else { throw Failure.business(code) }
        }
    }

    private static func currency(_ raw: String) throws -> String {
        guard raw.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil else {
            throw Failure.invalidResponse
        }
        return raw
    }

    static func parseBalance(_ data: Data, kind: Credential.Kind) throws -> Balance {
        guard data.count <= maxResponseBytes else { throw Failure.invalidResponse }
        struct PlatformWallet: Decodable { let balance: Amount; let currency: String }
        struct Summary: Decodable {
            let normal_wallets: [PlatformWallet]
            let bonus_wallets: [PlatformWallet]
        }
        struct APIWallet: Decodable {
            let currency: String
            let total_balance: Amount
            let granted_balance: Amount
            let topped_up_balance: Amount
        }
        struct PublicBalance: Decodable { let is_available: Bool; let balance_infos: [APIWallet] }
        if kind == .apiKey {
            let decoded = try JSONDecoder().decode(PublicBalance.self, from: data)
            var seen = Set<String>()
            let wallets = try decoded.balance_infos.map { wallet in
                let code = try currency(wallet.currency)
                guard seen.insert(code).inserted,
                      wallet.total_balance.value == wallet.granted_balance.value + wallet.topped_up_balance.value else {
                    throw Failure.invalidResponse
                }
                return Wallet(currency: code, paid: wallet.topped_up_balance.value, granted: wallet.granted_balance.value)
            }
            return Balance(wallets: wallets.sorted { $0.currency < $1.currency }, available: decoded.is_available)
        }
        let summary = try JSONDecoder().decode(Envelope<Summary>.self, from: data).value
        var paid: [String: Decimal] = [:], granted: [String: Decimal] = [:]
        for wallet in summary.normal_wallets { paid[try currency(wallet.currency), default: 0] += wallet.balance.value }
        for wallet in summary.bonus_wallets { granted[try currency(wallet.currency), default: 0] += wallet.balance.value }
        let wallets = try Set(paid.keys).union(granted.keys).sorted().map { code in
            let wallet = Wallet(currency: code, paid: paid[code, default: 0], granted: granted[code, default: 0])
            try Amount.check(wallet.total.amount)
            return wallet
        }
        return Balance(wallets: wallets, available: wallets.contains { $0.total.amount > 0 })
    }

    static func parseSpend(_ data: Data, window: Window) throws -> Spend {
        guard data.count <= maxResponseBytes else { throw Failure.invalidResponse }
        struct Bucket: Decodable { let time: Int64; let cost: Amount }
        struct Series: Decodable { let buckets: [Bucket] }
        struct CurrencyBlock: Decodable { let currency: String; let series: [Series] }
        struct Payload: Decodable {
            let data: [CurrencyBlock]
            let has_more: Bool?
            let next_cursor: String?
        }
        let payload = try JSONDecoder().decode(Envelope<Payload>.self, from: data).value
        guard payload.has_more != true, payload.next_cursor?.isEmpty != false else { throw Failure.invalidResponse }
        var amounts: [String: Decimal] = [:]
        for block in payload.data {
            let code = try currency(block.currency)
            // All series are included, even deleted/unnamed API keys. Never
            // include both a precomputed total and its constituent buckets.
            amounts[code, default: 0] += 0
            for series in block.series {
                for bucket in series.buckets where bucket.time >= window.start && bucket.time < window.end {
                    amounts[code, default: 0] += bucket.cost.value
                    try Amount.check(amounts[code]!)
                }
            }
        }
        return Spend(window: window, amounts: amounts.keys.sorted().map { Money(currency: $0, amount: amounts[$0]!) })
    }
}

/// Bounded reads and cancellation share the existing redirect-blocking delegate.
final class DeepSeekBillingTransport: @unchecked Sendable {
    private let blocker = NoRedirectDelegate()
    private let session: URLSession
    init(configuration: URLSessionConfiguration = .ephemeral) {
        let config = configuration
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        session = URLSession(configuration: config, delegate: blocker, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    private final class Cancellation: @unchecked Sendable {
        let lock = NSLock()
        var cancelled = false
        var task: URLSessionDataTask?
        func install(_ task: URLSessionDataTask) {
            lock.lock(); defer { lock.unlock() }
            self.task = task
            if cancelled { task.cancel() }
            task.resume()
        }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            task?.cancel()
        }
    }

    func fetch(_ request: URLRequest) async throws -> Data {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = blocker.boundedDataTask(in: session, request: request,
                                                   maxBytes: DeepSeekBilling.maxResponseBytes) { data, response, error in
                    guard error == nil, let http = response as? HTTPURLResponse, let data else {
                        continuation.resume(throwing: DeepSeekBilling.Failure.network)
                        return
                    }
                    if http.statusCode == 401 || http.statusCode == 403 {
                        continuation.resume(throwing: DeepSeekBilling.Failure.expired)
                    } else if http.statusCode != 200 {
                        continuation.resume(throwing: DeepSeekBilling.Failure.http(http.statusCode))
                    } else { continuation.resume(returning: data) }
                }
                cancellation.install(task)
            }
        } onCancel: { cancellation.cancel() }
    }
}
