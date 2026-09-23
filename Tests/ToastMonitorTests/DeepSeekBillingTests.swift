import XCTest
import SwiftUI
@testable import ToastMonitor

final class DeepSeekBillingTests: XCTestCase {
    func testMoneySymbolFormattingForPopover() {
        XCTAssertEqual(DeepSeekBilling.Money(currency: "CNY", amount: 7.67).symbolFormatted, "¥7.67")
        XCTAssertEqual(DeepSeekBilling.Money(currency: "USD", amount: 0).symbolFormatted, "$0.00")
        XCTAssertEqual(DeepSeekBilling.Money(currency: "EUR", amount: 1).symbolFormatted, "EUR 1.00")
    }

    func testTwoDecimalDisplayKeepsUnderlyingPrecision() {
        let money = DeepSeekBilling.Money(currency: "CNY", amount: Decimal(string: "10.5268714")!)
        XCTAssertEqual(money.formatted, "CNY 10.53")
        XCTAssertEqual(money.amount, Decimal(string: "10.5268714"))
    }

    func testCombinedSpendConvertsCurrenciesAndReplacesCoveredLocalCosts() {
        let spend = DeepSeekBilling.Spend(window: window(), amounts: [.init(currency: "CNY", amount: Decimal(string: "6.05889956")!)])
        XCTAssertEqual(DeepSeekBilling.combinedSpend(localUSD: 1.92, coveredLocalUSD: 0.5, spend: spend), "$2.29")
        XCTAssertEqual(DeepSeekBilling.combinedSpend(localUSD: 1.92, coveredLocalUSD: 0.5, spend: nil), "$1.92")
        let usd = DeepSeekBilling.Spend(window: window(), amounts: [.init(currency: "USD", amount: 2)])
        XCTAssertEqual(DeepSeekBilling.combinedSpend(localUSD: 1.5, spend: usd), "$3.50")
        XCTAssertEqual(DeepSeekBilling.combinedSpend(localUSD: 0, spend: spend), "$0.87")
        XCTAssertEqual(DeepSeekBilling.combinedSpend(localUSD: 1.42, spend: spend, cnyPerUSD: 7.2), "$2.26")
    }

    func testExchangeRateValidationAndConversionRoundOnlyFinalTotal() {
        let spend = DeepSeekBilling.Spend(window: window(), amounts: [.init(currency: "CNY", amount: Decimal(string: "6.30")!), .init(currency: "USD", amount: Decimal(string: "0.004")!)])
        XCTAssertEqual(DeepSeekBilling.combinedSpend(localUSD: 1.424, spend: spend, cnyPerUSD: 7), "$2.33")
        for invalid in [0.0, -7, Double.nan, Double.infinity, 1001] {
            XCTAssertFalse(DeepSeekBilling.validExchangeRate(invalid))
            XCTAssertEqual(DeepSeekBilling.combinedSpend(localUSD: 1.424, spend: spend, cnyPerUSD: invalid), "$2.33")
        }
    }

    func testWalletScientificNotationPreservesDecimalAmounts() throws {
        for (raw, expected) in [("0E-8", "0"), ("1.23456789E+1", "12.3456789"),
                                ("2.5e-8", "0.000000025"), ("-1E-2", "-0.01")] {
            let data = try payload(["normal_wallets": [["currency": "USD", "balance": raw]], "bonus_wallets": []])
            let result = try DeepSeekBilling.parseBalance(data, kind: .platform)
            XCTAssertEqual(result.wallets.first?.paid, Decimal(string: expected), raw)
        }
    }

    func testScientificNotationCostPreservesDecimalAmounts() throws {
        let range = window()
        let data = try payload(["data": [["currency": "USD", "series": [["buckets": [
            ["time": range.start, "cost": "0E-8"],
            ["time": range.start, "cost": "1.2345e-4"]
        ]]]]]])
        let result = try DeepSeekBilling.parseSpend(data, window: range)
        XCTAssertEqual(result.amounts.first?.amount, Decimal(string: "0.00012345"))
    }

    func testScientificNotationRejectsOverflowAndMalformedAmounts() throws {
        for raw in ["1e999", "1e13", "NaN", "Infinity", "1e", "1e+-2", "1.0 trailing"] {
            let data = try payload(["normal_wallets": [["currency": "USD", "balance": raw]], "bonus_wallets": []])
            XCTAssertThrowsError(try DeepSeekBilling.parseBalance(data, kind: .platform), raw)
        }
    }

    func testDiagnosticReportsSchemaWithoutResponseValues() throws {
        let data = Data(#"{"code":0,"data":{"biz_code":0,"biz_data":{"normal_wallets":"private-value","bonus_wallets":[]}}}"#.utf8)
        XCTAssertThrowsError(try DeepSeekBilling.parseBalance(data, kind: .platform)) { error in
            let message = DeepSeekBilling.failure(error).localizedDescription
            XCTAssertTrue(message.contains("data.biz_data.normal_wallets"))
            XCTAssertFalse(message.contains("private-value"))
        }
    }

    func testDiagnosticPreservesBusinessCodeWithoutServerMessage() throws {
        let data = Data(#"{"code":0,"data":{"biz_code":1234,"biz_msg":"private-value"}}"#.utf8)
        XCTAssertThrowsError(try DeepSeekBilling.parseBalance(data, kind: .platform)) { error in
            XCTAssertEqual(DeepSeekBilling.failure(error), .business(1234))
            XCTAssertFalse(DeepSeekBilling.failure(error).localizedDescription.contains("private-value"))
        }
    }

    private let now = ISO8601DateFormatter().date(from: "2026-09-14T10:30:00Z")!
    private let zone = TimeZone(secondsFromGMT: 3 * 3600)!

    private func payload(_ business: Any, code: Int = 0, businessCode: Int = 0) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["code": code, "data": ["biz_code": businessCode, "biz_data": business]])
    }

    private func window(_ slot: UsagePeriodSlot = .week, mode: UsagePeriodMode = .recent,
                        weekStart: UsageWeekStart = .monday) -> DeepSeekBilling.Window {
        DeepSeekBilling.Window.make(slot: slot, configuration: .init(mode: mode, weekStart: weekStart),
                                   now: now, timeZone: zone)!
    }

    func testPublicBalanceUsesDeclaredCurrenciesAndDecimalPrecision() throws {
        let data = Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.000001","granted_balance":"10.000001","topped_up_balance":"100"},{"currency":"USD","total_balance":"2.5","granted_balance":"0","topped_up_balance":"2.5"}]}"#.utf8)
        let result = try DeepSeekBilling.parseBalance(data, kind: .apiKey)
        XCTAssertEqual(result.wallets.count, 2)
        XCTAssertEqual(result.wallets[0].total.amount, Decimal(string: "110.000001"))
        XCTAssertTrue(result.formatted.contains("CNY 110.00"))
        XCTAssertTrue(result.formatted.contains("USD 2.50"))
    }

    func testPlatformWalletsAggregatePaidAndGrantedWithinEachCurrency() throws {
        let data = try payload(["normal_wallets": [["currency": "CNY", "balance": "10.1"],
                                                  ["currency": "CNY", "balance": "0.2"],
                                                  ["currency": "USD", "balance": 3]],
                                "bonus_wallets": [["currency": "CNY", "balance": "2.3"]]])
        let balance = try DeepSeekBilling.parseBalance(data, kind: .platform)
        XCTAssertEqual(balance.wallets[0].total.amount, Decimal(string: "12.6"))
        XCTAssertEqual(balance.wallets[1].total.amount, 3)
        XCTAssertTrue(balance.available)
    }

    func testZeroBalanceIsAValidSnapshot() throws {
        let data = try payload(["normal_wallets": [["currency": "CNY", "balance": "0"]], "bonus_wallets": []])
        let balance = try DeepSeekBilling.parseBalance(data, kind: .platform)
        XCTAssertFalse(balance.available)
        XCTAssertEqual(balance.formatted, "CNY 0.00")
    }

    func testMalformedBalanceIsNotReportedAsZero() throws {
        for amount: Any in ["NaN", "Infinity", "1x", "", NSNull(), true, "9999999999999999999"] {
            let data = try payload(["normal_wallets": [["currency": "CNY", "balance": amount]], "bonus_wallets": []])
            XCTAssertThrowsError(try DeepSeekBilling.parseBalance(data, kind: .platform), "Rejected \(amount)")
        }
        XCTAssertThrowsError(try DeepSeekBilling.parseBalance(try payload([:]), kind: .platform))
    }

    func testUnknownOrMissingEnvelopeNeverLooksSuccessful() throws {
        for data in [Data("{}".utf8), Data("not-json".utf8), try payload([:], code: 99), try payload([:], businessCode: 12)] {
            XCTAssertThrowsError(try DeepSeekBilling.parseSpend(data, window: window()))
        }
    }

    func testAuthenticationErrorsRecognizedBeforeDecodingBusinessData() throws {
        for code in [40002, 40003] {
            for data in [try payload(NSNull(), code: code), try payload(NSNull(), businessCode: code)] {
                XCTAssertThrowsError(try DeepSeekBilling.parseBalance(data, kind: .platform)) {
                    XCTAssertEqual($0 as? DeepSeekBilling.Failure, .expired)
                }
                XCTAssertThrowsError(try DeepSeekBilling.parseSpend(data, window: window())) {
                    XCTAssertEqual($0 as? DeepSeekBilling.Failure, .expired)
                }
            }
        }
    }

    func testBilledCostSumsEveryKeyAndModelButNotSummaryTotals() throws {
        let range = window()
        let data = try payload(["data": [["currency": "CNY", "total": "999", "series": [
            ["api_key": "desktop", "model": "deepseek-chat", "buckets": [["time": range.start, "cost": "0.1"]]],
            ["api_key": ["tracking_id": "other-device"], "model": "deepseek-chat", "buckets": [["time": range.start, "cost": "0.2"]]],
            ["api_key": NSNull(), "model": "reasoner", "buckets": [["time": range.start + 86400, "cost": "0.3"]]]
        ]]]])
        let cost = try DeepSeekBilling.parseSpend(data, window: range)
        XCTAssertEqual(cost.amounts, [.init(currency: "CNY", amount: Decimal(string: "0.6")!)])
    }

    func testCostWindowIsHalfOpenAndNeverConvertsCurrencies() throws {
        let range = window()
        let data = try payload(["data": [
            ["currency": "CNY", "series": [["buckets": [
                ["time": range.start - 1, "cost": "100"], ["time": range.start, "cost": "2"],
                ["time": range.end - 1, "cost": "3"], ["time": range.end, "cost": "200"]]]]],
            ["currency": "USD", "series": [["buckets": [["time": range.start, "cost": "4"]]]]]
        ]])
        XCTAssertEqual(try DeepSeekBilling.parseSpend(data, window: range).amounts,
                       [.init(currency: "CNY", amount: 5), .init(currency: "USD", amount: 4)])
    }

    func testMissingCostAndPaginationAreNotSilentlyTreatedAsZero() throws {
        for business: Any in [[:], ["data": [["currency": "CNY"]]],
                              ["data": [], "has_more": true], ["data": [], "next_cursor": "next"],
                              ["data": [["currency": "CNY", "series": [["buckets": [["time": window().start, "cost": NSNull()]]]]]]]] {
            XCTAssertThrowsError(try DeepSeekBilling.parseSpend(try payload(business), window: window()))
        }
        let empty = try DeepSeekBilling.parseSpend(try payload(["data": []]), window: window())
        XCTAssertTrue(empty.amounts.isEmpty)
        XCTAssertEqual(empty.formatted, "No billed usage")
    }

    func testRecentAndCalendarWindowsMatchControls() {
        XCTAssertEqual(window(.today).end - window(.today).start, 86_400)
        XCTAssertEqual(window(.week).end - window(.week).start, 7 * 86_400)
        XCTAssertEqual(window(.month).end - window(.month).start, 30 * 86_400)
        XCTAssertEqual(window(.week, mode: .calendar).start, window(.today).start) // Monday
        XCTAssertEqual(window(.week, mode: .calendar, weekStart: .sunday).start, window(.today).start - 86_400)
        XCTAssertEqual(window(.month, mode: .calendar).end - window(.month, mode: .calendar).start, 14 * 86_400)
        XCTAssertEqual(window().timeZoneLabel, "UTC+03:00")
        XCTAssertNil(DeepSeekBilling.Window.make(slot: .all, configuration: .init(), now: now, timeZone: zone))
    }

    func testDSTCrossingUsesExplicitFixedOffsetWithoutDroppingADay() {
        let date = ISO8601DateFormatter().date(from: "2026-03-10T12:00:00Z")!
        let range = DeepSeekBilling.Window.make(slot: .week, configuration: .init(), now: date,
                                               timeZone: TimeZone(identifier: "America/New_York")!)!
        XCTAssertEqual(range.offset, -4 * 3600)
        XCTAssertEqual(range.end - range.start, 7 * 86_400)
        XCTAssertEqual(range.timeZoneLabel, "UTC-04:00")
    }

    func testBillingRequestNeverFiltersToLocalOrSingleAPIKey() throws {
        let credential = try DeepSeekBilling.Credential.make(String(repeating: "x", count: 32), kind: .platform)
        let request = try DeepSeekBilling.request(credential: credential, window: window())
        XCTAssertEqual(request.url?.host, "platform.deepseek.com")
        XCTAssertEqual(request.url?.path, "/api/v0/usage/by_api_key/cost")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(credential.secret)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-client-platform"), "web")
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(Set(items.map(\.name)), Set(["start", "end", "tz"]))
        XCTAssertFalse(request.url!.absoluteString.contains(credential.secret))
    }

    func testAPIKeyCannotBeSentToPlatformBilling() throws {
        let key = try DeepSeekBilling.Credential.make(String(repeating: "k", count: 32), kind: .apiKey)
        XCTAssertThrowsError(try DeepSeekBilling.request(credential: key, window: window()))
        let request = try DeepSeekBilling.request(credential: key)
        XCTAssertEqual(request.url?.host, "api.deepseek.com")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-client-platform"))
    }

    func testCredentialValidationAndLocalStorageRepresentations() throws {
        let token = String(repeating: "a", count: 32)
        for raw in [token, "\"\(token)\"", "{\"value\":\"\(token)\"}", "{\"userToken\":\"\(token)\"}"] {
            XCTAssertEqual(try DeepSeekBilling.Credential.make(raw, kind: .platform).secret, token)
        }
        for raw in ["short", token + "\r\nInjected: header", "{\"value\":false}", String(repeating: "x", count: 17_000)] {
            XCTAssertThrowsError(try DeepSeekBilling.Credential.make(raw, kind: .platform))
        }
    }

    @MainActor func testLoginTokenOnlyReadFromExactHTTPSOrigin() {
        XCTAssertTrue(DeepSeekLoginWebView.isPlatformOrigin(URL(string: "https://platform.deepseek.com/usage")))
        for url in ["http://platform.deepseek.com", "https://platform.deepseek.com.evil.example", "https://evil.example",
                    "https://platform.deepseek.com:8443", "https://user:pass@platform.deepseek.com"] {
            XCTAssertFalse(DeepSeekLoginWebView.isPlatformOrigin(URL(string: url)))
        }
    }
}

private actor DeepSeekMockServer {
    var failure: DeepSeekBilling.Failure?
    var spendFailure: DeepSeekBilling.Failure?
    var spendDelay: UInt64 = 0
    var requests: [URLRequest] = []
    var multipleCurrencies = false
    func fail(_ error: DeepSeekBilling.Failure?) { failure = error }
    func failSpend(_ error: DeepSeekBilling.Failure?) { spendFailure = error }
    func delaySpend(_ value: UInt64) { spendDelay = value }
    func count() -> Int { requests.count }
    func enableMultipleCurrencies() { multipleCurrencies = true }
    func fetch(_ request: URLRequest) async throws -> Data {
        requests.append(request)
        if let failure { throw failure }
        if request.url!.path.hasSuffix("/cost") {
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let query = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) })
            let start = Int64(query["start"]!)!, end = Int64(query["end"]!)!
            let days = (end - start) / 86400
            if let spendFailure { throw spendFailure }
            // Intentionally ignores cancellation to simulate a late server response.
            if spendDelay > 0 { try? await Task.sleep(nanoseconds: spendDelay) }
            let extra = multipleCurrencies
                ? ",{\"currency\":\"USD\",\"series\":[{\"buckets\":[{\"time\":\(start),\"cost\":\"1.23456789\"}]}]}" : ""
            return Data("{\"code\":0,\"data\":{\"biz_code\":0,\"biz_data\":{\"data\":[{\"currency\":\"CNY\",\"series\":[{\"buckets\":[{\"time\":\(start),\"cost\":\"\(days)\"}]}]}\(extra)]}}}".utf8)
        }
        if request.url!.host == "api.deepseek.com" {
            return Data(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"20","granted_balance":"0","topped_up_balance":"20"}]}"#.utf8)
        }
        let amount = request.value(forHTTPHeaderField: "Authorization")!.contains("second") ? "200" : "100"
        let extra = multipleCurrencies ? ",{\"currency\":\"USD\",\"balance\":\"12.345678\"}" : ""
        return Data("{\"code\":0,\"data\":{\"biz_code\":0,\"biz_data\":{\"normal_wallets\":[{\"currency\":\"CNY\",\"balance\":\"\(amount)\"}\(extra)],\"bonus_wallets\":[]}}}".utf8)
    }
}

@MainActor
final class DeepSeekBillingClientTests: XCTestCase {
    private func makeClient(_ server: DeepSeekMockServer, saves: @escaping (DeepSeekBilling.Credential?) async -> Bool = { _ in true }) -> DeepSeekBillingClient {
        DeepSeekBillingClient(fetch: { try await server.fetch($0) }, readCredential: { nil }, saveCredential: saves)
    }
    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for DeepSeek test state")
    }
    private func connect(_ client: DeepSeekBillingClient, kind: DeepSeekBilling.Credential.Kind = .platform) async throws {
        client.connect(String(repeating: "first", count: 8), kind: kind)
        try await waitUntil { !client.connecting && !client.state.loadingBalance }
        XCTAssertNil(client.connectionError)
    }

    func testUnconfiguredDoesNotMakeNetworkRequests() async {
        let server = DeepSeekMockServer(), client = makeClient(server)
        client.refresh(force: true)
        XCTAssertNil(client.state.kind)
        let count = await server.count()
        XCTAssertEqual(count, 0)
    }

    func testAccountSpendFollowsSelectedPeriodAndBalanceStaysConstant() async throws {
        let server = DeepSeekMockServer(), client = makeClient(server)
        try await connect(client)
        XCTAssertEqual(client.spendText, "CNY 1.00")
        client.select(.week, configuration: .init())
        XCTAssertNil(client.state.spend)
        try await waitUntil { !client.state.loadingSpend }
        XCTAssertEqual(client.spendText, "CNY 7.00")
        client.select(.month, configuration: .init())
        try await waitUntil { !client.state.loadingSpend }
        XCTAssertEqual(client.spendText, "CNY 30.00")
        XCTAssertEqual(client.balanceText, "CNY 100.00")
    }

    func testAPIKeyIsBalanceOnlyAndNeverCombinedWithOldPlatformSpend() async throws {
        let server = DeepSeekMockServer(), client = makeClient(server)
        try await connect(client)
        XCTAssertNotNil(client.state.spend)
        try await connect(client, kind: .apiKey)
        XCTAssertEqual(client.balanceText, "USD 20.00")
        XCTAssertEqual(client.spendText, "Platform sign-in required")
        XCTAssertNil(client.state.spend)
    }

    func testAllTimeDoesNotMasqueradeAsThirtyDays() async throws {
        let server = DeepSeekMockServer(), client = makeClient(server)
        try await connect(client)
        client.select(.all, configuration: .init())
        XCTAssertNil(client.state.spend)
        XCTAssertEqual(client.spendText, "Full history unavailable")
        try await waitUntil { !client.state.loadingBalance }
        XCTAssertEqual(client.balanceText, "CNY 100.00")
    }

    func testLatePeriodResponseCannotOverwriteNewSelection() async throws {
        let server = DeepSeekMockServer(), client = makeClient(server)
        try await connect(client)
        await server.delaySpend(200_000_000)
        client.select(.week, configuration: .init())
        try await Task.sleep(nanoseconds: 20_000_000)
        client.select(.month, configuration: .init())
        try await waitUntil { !client.state.loadingSpend }
        XCTAssertEqual(client.state.spend?.window, client.window)
        XCTAssertEqual(client.spendText, "CNY 30.00")
    }

    func testFailedRefreshKeepsLastKnownBalanceAndSpendAndBacksOff() async throws {
        let server = DeepSeekMockServer(), client = makeClient(server)
        try await connect(client)
        await server.fail(.network)
        client.refresh(force: true)
        try await waitUntil { !client.state.loadingBalance }
        XCTAssertEqual(client.balanceText, "CNY 100.00")
        XCTAssertEqual(client.spendText, "CNY 1.00")
        XCTAssertTrue(client.stale(client.state.spendUpdated, error: client.state.spendError))
        let before = await server.count()
        client.refresh(force: true)
        client.select(.week, configuration: .init())
        try await Task.sleep(nanoseconds: 30_000_000)
        let after = await server.count()
        XCTAssertEqual(after, before)
        XCTAssertNil(client.state.spend)
        XCTAssertNotEqual(client.spendText, "CNY 1.00")
    }

    func testSpendFailureDoesNotHideSuccessfulBalance() async throws {
        let server = DeepSeekMockServer(), client = makeClient(server)
        await server.failSpend(.invalidResponse)
        try await connect(client)
        XCTAssertEqual(client.balanceText, "CNY 100.00")
        XCTAssertEqual(client.spendText, "Unavailable")
        XCTAssertNil(client.state.spend)
    }

    func testExpiredSessionStopsPollingUntilReconnect() async throws {
        let server = DeepSeekMockServer(), client = makeClient(server)
        try await connect(client)
        await server.fail(.expired)
        client.refresh(force: true)
        try await waitUntil { !client.state.loadingBalance }
        XCTAssertTrue(client.state.expired)
        XCTAssertEqual(client.spendText, "Sign-in expired")
        let before = await server.count()
        client.refresh(force: true, now: Date().addingTimeInterval(3600))
        let after = await server.count()
        XCTAssertEqual(before, after)
        await server.fail(nil)
        try await connect(client)
        XCTAssertFalse(client.state.expired)
        XCTAssertEqual(client.spendText, "CNY 1.00")
    }

    func testFailedCredentialSaveKeepsExistingAccount() async throws {
        let server = DeepSeekMockServer()
        var allowSave = true
        let client = makeClient(server, saves: { _ in allowSave })
        try await connect(client)
        allowSave = false
        client.connect(String(repeating: "second", count: 8), kind: .platform)
        try await waitUntil { !client.connecting }
        XCTAssertNotNil(client.connectionError)
        XCTAssertEqual(client.balanceText, "CNY 100.00")
        client.disconnect()
        try await waitUntil { !client.connecting }
        XCTAssertEqual(client.balanceText, "CNY 100.00")
    }

    func testDisconnectClearsDisplayAndIgnoresLateNetworkResult() async throws {
        let server = DeepSeekMockServer(), client = makeClient(server)
        try await connect(client)
        await server.delaySpend(150_000_000)
        client.select(.week, configuration: .init())
        client.disconnect()
        try await waitUntil { !client.connecting }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(client.state.kind)
        XCTAssertNil(client.state.balance)
        XCTAssertNil(client.state.spend)
        XCTAssertEqual(client.balanceText, "Not connected")
    }

    func testReplacingAccountWhileSpendIsPendingCannotReuseOldResult() async throws {
        let server = DeepSeekMockServer(), client = makeClient(server)
        try await connect(client)
        await server.delaySpend(150_000_000)
        client.select(.week, configuration: .init())
        client.connect(String(repeating: "second", count: 8), kind: .platform)
        try await waitUntil { !client.connecting && !client.state.loadingSpend }
        XCTAssertEqual(client.balanceText, "CNY 200.00")
        XCTAssertEqual(client.spendText, "CNY 7.00")
    }

    func testRejectedNewSessionIsNeverSaved() async throws {
        let server = DeepSeekMockServer()
        var writes = 0
        let client = makeClient(server, saves: { _ in writes += 1; return true })
        await server.fail(.expired)
        client.connect(String(repeating: "invalid", count: 6), kind: .platform)
        try await waitUntil { !client.connecting }
        XCTAssertEqual(writes, 0)
        XCTAssertNil(client.state.kind)
        XCTAssertNotNil(client.connectionError)
    }

    func testPeriodChangeDuringInitialKeychainLoadDoesNotLoseCredential() async throws {
        let server = DeepSeekMockServer()
        let saved = try DeepSeekBilling.Credential.make(String(repeating: "first", count: 8), kind: .platform)
        let client = DeepSeekBillingClient(fetch: { try await server.fetch($0) }, readCredential: {
            try? await Task.sleep(nanoseconds: 80_000_000)
            return saved
        }, saveCredential: { _ in true })
        let restore = Task { await client.restoreSavedCredential() }
        try await Task.sleep(nanoseconds: 10_000_000)
        client.select(.month, configuration: .init())
        await restore.value
        try await waitUntil { !client.state.loadingSpend }
        XCTAssertEqual(client.balanceText, "CNY 100.00")
        XCTAssertEqual(client.spendText, "CNY 30.00")
    }

    func testLateKeychainReadCannotRestoreAccountAfterDisconnect() async throws {
        let server = DeepSeekMockServer()
        let saved = try DeepSeekBilling.Credential.make(String(repeating: "first", count: 8), kind: .platform)
        let client = DeepSeekBillingClient(fetch: { try await server.fetch($0) }, readCredential: {
            try? await Task.sleep(nanoseconds: 80_000_000)
            return saved
        }, saveCredential: { _ in true })
        let restore = Task { await client.restoreSavedCredential() }
        try await Task.sleep(nanoseconds: 10_000_000)
        client.disconnect()
        try await waitUntil { !client.connecting }
        await restore.value
        XCTAssertNil(client.state.kind)
        XCTAssertEqual(client.balanceText, "Not connected")
    }

    /// Opt-in rendered QA uses only the injected server and never starts
    /// collectors, reads credentials, or changes the installed application.
    func testRenderedBillingViews() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TM_DEEPSEEK_UI_OUTPUT"] else {
            throw XCTSkip("Set TM_DEEPSEEK_UI_OUTPUT for rendered UI verification")
        }
        let server = DeepSeekMockServer(), client = makeClient(server)
        try await connect(client)
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let home = NSHostingView(rootView: PopoverHomeView(deepseek: client)
            .background(Color(nsColor: .windowBackgroundColor)))
        home.frame = NSRect(x: 0, y: 0, width: 400, height: 880)
        home.appearance = NSAppearance(named: .aqua)
        home.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        for (slot, name) in [(UsagePeriodSlot.today, "today"), (.week, "week"), (.month, "month"), (.all, "all")] {
            NotificationCenter.default.post(name: PopoverHomeView.testPeriodNotification, object: name)
            client.select(slot, configuration: .init())
            try await waitUntil { !client.state.loadingBalance && !client.state.loadingSpend }
            try await Task.sleep(nanoseconds: 250_000_000)
            try capture(home, at: folder.appendingPathComponent("deepseek-\(name)-light.png"))
        }
        home.appearance = NSAppearance(named: .darkAqua)
        client.select(.month, configuration: .init())
        NotificationCenter.default.post(name: PopoverHomeView.testPeriodNotification, object: "month")
        try await waitUntil { !client.state.loadingSpend }
        try await Task.sleep(nanoseconds: 250_000_000)
        try capture(home, at: folder.appendingPathComponent("deepseek-month-dark.png"))
        await server.enableMultipleCurrencies()
        client.refresh(force: true)
        try await waitUntil { !client.state.loadingSpend }
        home.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(nanoseconds: 250_000_000)
        try capture(home, at: folder.appendingPathComponent("deepseek-multicurrency-light.png"))
        home.frame.size.height = 560
        try await Task.sleep(nanoseconds: 200_000_000)
        try capture(home, at: folder.appendingPathComponent("deepseek-short-window-light.png"))
        let settings = NSHostingView(rootView: DeepSeekBillingSettingsView(client: client)
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)))
        settings.appearance = NSAppearance(named: .aqua)
        settings.frame = NSRect(x: 0, y: 0, width: 620, height: 320)
        try await Task.sleep(nanoseconds: 200_000_000)
        try capture(settings, at: folder.appendingPathComponent("deepseek-settings-light.png"))
    }

    private func capture(_ view: NSView, at url: URL) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 1000)
        try data.write(to: url, options: .atomic)
    }
}

final class DeepSeekBillingTransportTests: XCTestCase {
    private func transport() -> DeepSeekBillingTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeepSeekTransportURLProtocol.self]
        return DeepSeekBillingTransport(configuration: config)
    }

    func testTransportAcceptsOnlySuccessfulHTTPAndSanitizesErrorMessages() async throws {
        let client = transport()
        let good = try await client.fetch(URLRequest(url: URL(string: "https://platform.deepseek.com/200")!))
        XCTAssertEqual(good, Data("{}".utf8))
        for status in [301, 401, 403, 429, 500] {
            do {
                _ = try await client.fetch(URLRequest(url: URL(string: "https://platform.deepseek.com/\(status)")!))
                XCTFail("HTTP \(status) must fail")
            } catch {
                XCTAssertEqual(error as? DeepSeekBilling.Failure,
                               status == 401 || status == 403 ? .expired : .http(status))
                XCTAssertFalse(error.localizedDescription.contains("private-response"))
            }
        }
    }

    func testTransportRejectsOversizedChunkedResponse() async {
        do {
            _ = try await transport().fetch(URLRequest(url: URL(string: "https://platform.deepseek.com/oversized")!))
            XCTFail("Oversized body must fail")
        } catch { XCTAssertEqual(error as? DeepSeekBilling.Failure, .network) }
    }

    func testTransportCancellationCompletesWithoutWaitingForTimeout() async throws {
        let client = transport()
        let task = Task { try await client.fetch(URLRequest(url: URL(string: "https://platform.deepseek.com/cancel")!)) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let started = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request must fail") } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }
}

private final class DeepSeekTransportURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.lastPathComponent
        if path == "cancel" { return }
        let status = Int(path) ?? 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path == "oversized" {
            client?.urlProtocol(self, didLoad: Data(repeating: 0x61, count: DeepSeekBilling.maxResponseBytes + 1))
        } else {
            client?.urlProtocol(self, didLoad: Data((status == 200 ? "{}" : "private-response").utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
