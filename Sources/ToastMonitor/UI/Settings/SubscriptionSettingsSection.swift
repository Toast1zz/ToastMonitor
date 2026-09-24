import SwiftUI

/// 订阅管理: list + add/edit form (固定成本侧信息).
struct SubscriptionSettingsSection: View {
    @ObservedObject private var app = AppState.shared
    @State private var showForm = false
    @State private var editing: Database.Subscription?
    /// The row id captured at edit time; saving uses this instead of
    /// re-deriving it from `editing` so an edit can never fall back to id 0.
    @State private var editID: Int64 = 0
    @State private var name = ""
    @State private var plan = ""
    @State private var startDate = Date()
    @State private var hasEndDate = false
    @State private var endDate = Date()
    @State private var cycle = "monthly"
    @State private var price = ""
    @State private var priceError = false
    @State private var dateError = false
    @State private var databaseError: String?
    @State private var pendingDelete: Database.Subscription?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle("Subscriptions")
                Spacer()
                Button {
                    editing = nil
                    editID = 0
                    name = ""
                    plan = ""
                    startDate = Date()
                    hasEndDate = false
                    endDate = Date()
                    cycle = "monthly"
                    price = ""
                    showForm = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .font(TMType.regular(12))
                .disabled(showForm)
                Button {
                    editing = nil
                    editID = 0
                    name = "OpenCode Go"
                    plan = "go"
                    startDate = Date()
                    hasEndDate = false
                    endDate = Date()
                    cycle = "monthly"
                    price = "10"
                    showForm = true
                } label: {
                    Text("Go template")
                }
                .font(TMType.regular(12))
                .disabled(showForm)
                .help("Fill OpenCode Go $10/mo template")
            }

            if app.subscriptions.isEmpty {
                Text("No subscriptions")
                    .font(TMType.regular(TMType.micro))
                    .foregroundStyle(TMDesign.quiet)
            } else {
                ForEach(app.subscriptions) { sub in
                    HStack {
                        Image(systemName: planIcon(sub.plan))
                            .foregroundStyle(planColor(sub.plan))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sub.name)
                                .font(TMType.medium(12))
                            Text("From \(Format.day(sub.startDate)) · \(sub.cycle == "yearly" ? "Yearly" : "Monthly") · \(Format.money(sub.price))/period"
                                 + (sub.endDate > 0 ? " · to \(SubscriptionMath.dateStr(Date(timeIntervalSince1970: TimeInterval(sub.endDate))))" : ""))
                                .font(TMType.regular(TMType.micro))
                                .foregroundStyle(TMDesign.quiet)
                            if let info = SubscriptionMath.cycleInfo(start: sub.startDate, end: sub.endDate, cycle: sub.cycle) {
                                HStack(spacing: 6) {
                                    Text("Day \(info.dayOfCycle)/\(info.totalDays) · renews \(SubscriptionMath.dateStr(info.end)) · avg \(Format.money(sub.price / Double(info.totalDays)))/day")
                                        .font(TMType.regular(TMType.micro))
                                        .tmMonospacedDigit()
                                        .foregroundStyle(TMDesign.quiet)
                                    if let fc = SubscriptionMath.forecast(plan: sub.plan, cycleStart: info.start, cycleEnd: info.end) {
                                        let line = ForecastText.line(for: fc, plan: sub.plan)
                                        Text(line.text)
                                            .font(TMType.semibold(TMType.micro))
                                            .tmMonospacedDigit()
                                            .foregroundStyle(ForecastText.color(line.status))
                                    }
                                }
                            }
                        }
                        Spacer()
                        Button("Edit") {
                            editing = sub
                            editID = sub.id
                            name = sub.name
                            plan = sub.plan
                            startDate = Date(timeIntervalSince1970: TimeInterval(sub.startDate))
                            hasEndDate = sub.endDate > 0
                            endDate = sub.endDate > 0 ? Date(timeIntervalSince1970: TimeInterval(sub.endDate)) : Date()
                            cycle = sub.cycle
                            price = "\(sub.price)"
                            showForm = true
                        }
                        .font(TMType.regular(11))
                        Button {
                            pendingDelete = sub
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .font(TMType.regular(11))
                        .foregroundStyle(TMDesign.danger)
                        .help("Delete subscription")
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
                }
            }

            // Persistence feedback lives outside the form so a delete failure
            // (form closed) is still visible, not silently dropped.
            if let databaseError {
                Text(databaseError)
                    .font(TMType.regular(TMType.micro))
                    .foregroundStyle(TMDesign.danger)
            }

        }
        .tmPanelSurface()
        .onChange(of: showForm) { open in
            // Draft validation must not survive closing and later reopening
            // the form; especially dateError used to appear on a fresh edit.
            priceError = false
            dateError = false
            // A stale persistence error (e.g. failed delete) is cleared when
            // the form reopens so it cannot outlive the operation it reports.
            if open {
                databaseError = nil
            }
        }
        .alert("Delete subscription?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } })) {
                Button("Cancel", role: .cancel) { pendingDelete = nil }
                Button("Delete", role: .destructive) {
                    if let sub = pendingDelete {
                        DispatchQueue.global(qos: .userInitiated).async {
                            let ok = Database.shared.deleteSubscription(id: sub.id)
                            DispatchQueue.main.async {
                                if ok {
                                    // subscriptionsDidChange 通知驱动 AppState 刷新。
                                    databaseError = nil
                                } else {
                                    databaseError = "Failed to delete subscription (disk space or database permissions)"
                                }
                            }
                        }
                    }
                    pendingDelete = nil
                }
            } message: {
                Text(pendingDelete.map { "This deletes \"\($0.name)\" and its cycle/forecast records." } ?? "")
            }
        .sheet(isPresented: $showForm) {
            subscriptionForm
        }
    }

    private var subscriptionForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(editing == nil ? "Add Subscription" : "Edit Subscription")
                .font(.title2.weight(.semibold))

            Form {
                TextField("Name", text: $name, prompt: Text("Codex / Claude Pro"))
                Picker("Plan", selection: $plan) {
                    Text("None").tag("")
                    Text("OpenCode Go").tag("go")
                    Text("OpenRouter").tag("openrouter")
                    Text("Claude Pro").tag("claude")
                    Text("ChatGPT / Codex").tag("openai")
                }
                DatePicker("Start date", selection: $startDate, displayedComponents: .date)
                Toggle("Has end date", isOn: $hasEndDate)
                if hasEndDate {
                    DatePicker("End date", selection: $endDate, displayedComponents: .date)
                }
                Picker("Billing cycle", selection: $cycle) {
                    Text("Monthly").tag("monthly")
                    Text("Yearly").tag("yearly")
                }
                .pickerStyle(.menu)
                TextField("Price per period (USD)", text: $price)
            }
            .formStyle(.grouped)

            if priceError {
                Text("Enter a valid price (a number greater than or equal to zero).")
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(TMDesign.danger)
            }
            if dateError {
                Text("The end date cannot be before the start date.")
                    .font(TMType.regular(TMType.caption))
                    .foregroundStyle(TMDesign.danger)
            }

            HStack {
                Spacer()
                Button("Cancel") { showForm = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { saveSubscription() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func saveSubscription() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let p = Double(price.trimmingCharacters(in: .whitespaces)), p.isFinite, p >= 0 else {
            priceError = true
            return
        }
        priceError = false
        let startDay = Calendar.current.startOfDay(for: startDate)
        let endDay = Calendar.current.startOfDay(for: endDate)
        guard !hasEndDate || endDay >= startDay else {
            dateError = true
            return
        }
        dateError = false
        let sub = Database.Subscription(
            id: editID > 0 ? editID : (editing?.id ?? 0),
            name: name.trimmingCharacters(in: .whitespaces),
            plan: plan,
            startDate: Int64(startDate.timeIntervalSince1970),
            endDate: hasEndDate ? Int64(endDate.timeIntervalSince1970) : 0,
            cycle: cycle,
            price: p,
            currency: "USD")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Self.persist(sub)
            DispatchQueue.main.async {
                if ok {
                    showForm = false
                    databaseError = nil
                } else {
                    databaseError = "Failed to save subscription (disk space or database permissions)"
                }
            }
        }
    }

    /// Defensive persistence: if the edit context lost its id, match by
    /// (name, startDate) so saving an edit never inserts a duplicate row.
    private static func persist(_ sub: Database.Subscription) -> Bool {
        var s = sub
        if s.id <= 0 {
            let existing = Database.shared.subscriptions().first { row in
                row.name == s.name && row.startDate == s.startDate
            }
            if let existing {
                s = Database.Subscription(id: existing.id, name: s.name, plan: s.plan,
                                          startDate: s.startDate, endDate: s.endDate,
                                          cycle: s.cycle, price: s.price, currency: s.currency)
            }
            NSLog("[ToastMonitor] subscription save without id; matched existing id=%lld or inserting", s.id)
        }
        return Database.shared.upsertSubscription(s)
    }

    private func planIcon(_ p: String) -> String {
        switch p {
        case "go": return "g.circle.fill"
        case "openrouter": return ToolKind.openrouter.symbol
        case "claude": return ToolKind.claude.symbol
        case "openai", "chatgpt", "codex": return ToolKind.codex.symbol
        default: return "calendar"
        }
    }

    private func planColor(_ p: String) -> Color {
        switch p {
        case "go": return TMDesign.accent
        case "openrouter": return ToolKind.openrouter.color
        case "claude": return ToolKind.claude.color
        case "openai", "chatgpt", "codex": return ToolKind.codex.color
        default: return .gray
        }
    }
}
