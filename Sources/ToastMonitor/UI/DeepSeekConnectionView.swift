import SwiftUI
import WebKit

struct DeepSeekBillingSettingsView: View {
    @ObservedObject private var client: DeepSeekBillingClient
    @ObservedObject private var periods = UsagePeriodSettings.shared
    @State private var showConnection = false
    @State private var showDisconnect = false
    @AppStorage(DeepSeekBilling.exchangeRateKey) private var cnyPerUSD = DeepSeekBilling.defaultCNYPerUSD
    @State private var exchangeRateDraft = ""

    @MainActor init(client: DeepSeekBillingClient? = nil) {
        _client = ObservedObject(wrappedValue: client ?? .shared)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(client.state.kind == .platform ? "Platform account - experimental" : "Official API")
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(.secondary)
                Spacer()
                if client.state.loadingBalance || client.state.loadingSpend {
                    ProgressView().controlSize(.small)
                }
                Button { client.refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(client.state.kind == nil || client.state.expired)
                    .help("Refresh DeepSeek balance and account spend")
                    .accessibilityLabel("Refresh DeepSeek")
            }
            LabeledContent("Balance", value: client.balanceText)
                .font(TMType.monoRegular(TMType.body))
            LabeledContent("USD conversion") {
                HStack(spacing: 6) {
                    Text("1 USD =")
                    TextField("7.00", text: $exchangeRateDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .accessibilityLabel("CNY per USD")
                    Text("CNY")
                }
                .font(TMType.monoRegular(TMType.body))
                .help("Manual accounting exchange rate for Spent. Not a live market quote.")
            }
            if !exchangeRateDraft.isEmpty && (Double(exchangeRateDraft).map(DeepSeekBilling.validExchangeRate) != true) {
                Text("Enter a rate between 0.01 and 1000.")
                    .font(TMType.regular(TMType.caption)).foregroundStyle(TMDesign.danger)
            }
            if client.state.kind == .platform {
                LabeledContent("\(periods.configuration.label(for: client.selectedSlot)) account spend", value: client.spendText)
                    .font(TMType.monoRegular(TMType.body))
            }
            if let balance = client.state.balance {
                ForEach(balance.wallets, id: \.currency) { wallet in
                    Text("Paid \(DeepSeekBilling.Money(currency: wallet.currency, amount: wallet.paid).formatted)  |  Granted \(DeepSeekBilling.Money(currency: wallet.currency, amount: wallet.granted).formatted)")
                        .font(TMType.monoRegular(TMType.caption))
                        .foregroundStyle(.secondary)
                }
            }
            if let updated = client.state.balanceUpdated {
                Text("Balance updated \(Format.dateTime(Int64(updated.timeIntervalSince1970)))")
                    .font(TMType.regular(TMType.caption)).foregroundStyle(.secondary)
            }
            if let updated = client.state.spendUpdated, let window = client.window {
                Text("Account spend updated \(Format.dateTime(Int64(updated.timeIntervalSince1970))) - \(window.timeZoneLabel)")
                    .font(TMType.regular(TMType.caption)).foregroundStyle(.secondary)
            }
            if let error = client.connectionError ?? client.state.balanceError ?? client.state.spendError {
                Text(error).font(TMType.regular(TMType.caption)).foregroundStyle(TMDesign.danger)
            }
            HStack {
                Button(client.state.kind == nil ? "Connect DeepSeek..." : "Reconnect...") {
                    client.clearConnectionError()
                    showConnection = true
                }
                .disabled(client.connecting)
                if client.state.kind != nil || client.state.balanceError != nil {
                    Button("Disconnect", role: .destructive) { showDisconnect = true }
                        .disabled(client.connecting)
                }
            }
        }
        .onAppear {
            let rate = DeepSeekBilling.validExchangeRate(cnyPerUSD) ? cnyPerUSD : DeepSeekBilling.defaultCNYPerUSD
            exchangeRateDraft = String(rate)
        }
        .onChange(of: exchangeRateDraft) { text in
            if let rate = Double(text), DeepSeekBilling.validExchangeRate(rate) { cnyPerUSD = rate }
        }
        .sheet(isPresented: $showConnection) { DeepSeekConnectionView() }
        .confirmationDialog("Disconnect DeepSeek?", isPresented: $showDisconnect) {
            Button("Disconnect", role: .destructive) { client.disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The saved DeepSeek credential and displayed account data will be cleared.") }
    }
}

struct DeepSeekConnectionView: View {
    private enum Mode: String, CaseIterable {
        case browser = "Browser", signIn = "In-App", session = "Platform Session", apiKey = "API Key"
    }
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var client = DeepSeekBillingClient.shared
    @State private var mode: Mode = .browser
    @State private var browser: DeepSeekBrowserSession.Browser = .chrome
    @State private var importing = false
    @State private var importTask: Task<Void, Never>?
    @State private var secret = ""
    @State private var webError: String?
    @State private var webToken: String?
    @State private var reloadID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect DeepSeek").font(TMType.semibold(TMType.section))
            Picker("Connection", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(client.connecting || importing)
            if mode == .browser {
                Form {
                    Picker("Browser", selection: $browser) {
                        ForEach(DeepSeekBrowserSession.Browser.allCases) { browser in
                            Text(browser.rawValue).tag(browser)
                        }
                    }
                    .disabled(importing || client.connecting)
                    LabeledContent("Account", value: "DeepSeek Platform")
                    LabeledContent("Sign-in", value: "Google or email")
                    LabeledContent("Import scope", value: "Active DeepSeek tab only")
                    LabeledContent("Storage", value: "macOS Keychain")
                    HStack {
                        Button { openBrowser() } label: {
                            Label("Open DeepSeek in Browser", systemImage: "safari")
                        }
                        .disabled(importing || client.connecting)
                        Button("Connect from Browser") { importBrowserSession() }
                        .disabled(importing || client.connecting)
                    }
                }
                .formStyle(.grouped)
                Spacer()
            } else if mode == .signIn {
                DeepSeekLoginWebView(onToken: { token in
                    webToken = token
                    if !client.connecting { client.connect(token, kind: .platform) }
                }, onError: { webError = $0 }, onBrowserRequired: {
                    mode = .browser
                    openBrowser()
                })
                .id(reloadID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .border(Color.secondary.opacity(0.2))
                .disabled(client.connecting)
            } else {
                Form {
                    SecureField(mode == .apiKey ? "DeepSeek API key" : "Platform userToken", text: $secret)
                        .font(.system(size: TMType.body, design: .monospaced))
                    LabeledContent("Access", value: mode == .apiKey ? "Balance only" : "Account balance and billed usage")
                    LabeledContent("Storage", value: "macOS Keychain")
                }
                .formStyle(.grouped)
                Spacer()
            }
            if mode != .apiKey {
                Text("Experimental platform connection. Session expiry requires sign-in again.")
                    .font(TMType.regular(TMType.caption)).foregroundStyle(.secondary)
            }
            if let error = client.connectionError ?? webError {
                Text(error).font(TMType.regular(TMType.caption)).foregroundStyle(TMDesign.danger)
            }
            HStack {
                if mode == .signIn {
                    Button {
                        webError = nil; webToken = nil; client.clearConnectionError(); reloadID = UUID()
                    } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload DeepSeek sign-in")
                    .accessibilityLabel("Reload DeepSeek sign-in")
                    .disabled(client.connecting)
                    if let webToken, client.connectionError != nil {
                        Button("Retry Connection") { client.connect(webToken, kind: .platform) }
                            .disabled(client.connecting)
                    }
                }
                if client.connecting || importing {
                    ProgressView().controlSize(.small)
                    Text(importing ? "Reading DeepSeek session..." : "Verifying account...").font(TMType.regular(TMType.caption))
                }
                Spacer()
                Button("Cancel") { secret = ""; dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(client.connecting)
                if mode == .session || mode == .apiKey {
                    Button("Connect") {
                        client.connect(secret, kind: mode == .apiKey ? .apiKey : .platform)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(secret.isEmpty || client.connecting)
                }
            }
        }
        .padding(20)
        .frame(width: 700, height: 610)
        .interactiveDismissDisabled(client.connecting)
        .onAppear {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) == nil { browser = .safari }
        }
        .onChange(of: mode) { _ in secret = ""; webToken = nil; webError = nil; client.clearConnectionError() }
        .onChange(of: client.connecting) { connecting in
            if !connecting, client.connectionError == nil, client.state.kind != nil { secret = ""; dismiss() }
        }
        .onDisappear { secret = ""; webToken = nil; importTask?.cancel() }
    }

    private func openBrowser() {
        webError = nil
        client.clearConnectionError()
        let selected = browser
        Task {
            do { try await DeepSeekBrowserSession.open(selected) }
            catch { webError = (error as? DeepSeekBrowserSession.Failure ?? .failed).localizedDescription }
        }
    }

    private func importBrowserSession() {
        guard !importing, !client.connecting else { return }
        webError = nil
        client.clearConnectionError()
        importing = true
        let selected = browser
        importTask = Task {
            defer { importing = false }
            do {
                let credential = try await DeepSeekBrowserSession.read(selected)
                guard !Task.isCancelled else { return }
                client.connect(credential.secret, kind: .platform)
            } catch {
                guard !Task.isCancelled else { return }
                webError = (error as? DeepSeekBrowserSession.Failure ?? .failed).localizedDescription
            }
        }
    }
}

/// A fresh, nonpersistent web session. Only userToken from the exact Platform
/// origin is read; no browser profile, password field, or third-party cookie is inspected.
struct DeepSeekLoginWebView: NSViewRepresentable {
    let onToken: (String) -> Void
    let onError: (String) -> Void
    let onBrowserRequired: () -> Void

    enum NavigationRoute: Equatable { case allow, browser, block }

    static func route(_ url: URL?, newWindow: Bool) -> NavigationRoute {
        if newWindow, url?.absoluteString == "about:blank" { return .browser }
        guard let url, url.scheme == "https", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, let host = url.host else { return .block }
        if host == "accounts.google.com" { return .browser }
        guard host == "deepseek.com" || host.hasSuffix(".deepseek.com") else { return .block }
        return newWindow ? .browser : .allow
    }

    static func isPlatformOrigin(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https" && url.host == "platform.deepseek.com"
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onToken: onToken, onError: onError, onBrowserRequired: onBrowserRequired)
    }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.webView = view
        view.load(URLRequest(url: URL(string: DeepSeekBilling.platformOrigin)!))
        context.coordinator.start()
        return view
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.timer?.invalidate()
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        nsView.uiDelegate = nil
        coordinator.webView = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var webView: WKWebView?
        var timer: Timer?
        private var lastToken: String?
        private var reading = false
        private var routedToBrowser = false
        let onToken: (String) -> Void
        let onError: (String) -> Void
        let onBrowserRequired: () -> Void
        init(onToken: @escaping (String) -> Void, onError: @escaping (String) -> Void,
             onBrowserRequired: @escaping () -> Void) {
            self.onToken = onToken; self.onError = onError; self.onBrowserRequired = onBrowserRequired
        }
        func start() {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.readToken() }
        }
        private func readToken() {
            guard !reading, let webView, DeepSeekLoginWebView.isPlatformOrigin(webView.url) else { return }
            reading = true
            webView.evaluateJavaScript("location.origin === 'https://platform.deepseek.com' ? localStorage.getItem('userToken') : null") { [weak self] value, _ in
                guard let self else { return }
                self.reading = false
                guard DeepSeekLoginWebView.isPlatformOrigin(self.webView?.url), let raw = value as? String,
                      let candidate = try? DeepSeekBilling.Credential.make(raw, kind: .platform),
                      candidate.secret != self.lastToken else { return }
                self.lastToken = candidate.secret
                self.onToken(candidate.secret)
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.targetFrame?.isMainFrame != false else { decisionHandler(.allow); return }
            switch DeepSeekLoginWebView.route(navigationAction.request.url, newWindow: navigationAction.targetFrame == nil) {
            case .allow: decisionHandler(.allow)
            case .browser:
                decisionHandler(.cancel)
                useBrowser()
            case .block:
                onError("External navigation blocked. Use Browser sign-in.")
                decisionHandler(.cancel)
            }
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if DeepSeekLoginWebView.route(navigationAction.request.url, newWindow: true) == .browser { useBrowser() }
            return nil
        }
        private func useBrowser() {
            guard !routedToBrowser else { return }
            routedToBrowser = true
            // Start afresh on the Platform root in a real browser. Do not
            // forward an OAuth URL/state belonging to this ephemeral webview.
            DispatchQueue.main.async { [weak self] in self?.onBrowserRequired() }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { readToken() }
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse,
               response.statusCode >= 400 {
                onError("DeepSeek sign-in returned HTTP \(response.statusCode). Platform Session remains available.")
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { onError("DeepSeek sign-in page could not be loaded.") }
        }
    }
}
