import SwiftUI

/// Settings › Sources › Subscriptions: list + add/edit form (fixed costs).
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
        Section {
            ForEach(app.subscriptions) { sub in
                LabeledContent {
                    HStack {
                        Button {
                            pendingDelete = sub
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete \(sub.name)")
                        .accessibilityLabel("Delete \(sub.name)")
                        Button("Edit…") { beginEdit(sub) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: Self.planIcon(sub.plan))
                            .foregroundStyle(Self.planColor(sub.plan))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sub.name)
                            Text(summary(sub))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .tmMonospacedDigit()
                        }
                    }
                }
            }
            HStack {
                Button("Add Subscription…") { beginAdd() }
                Button("Add OpenCode Go…") {
                    beginAdd()
                    name = "OpenCode Go"
                    plan = "go"
                    price = "10"
                }
                Spacer()
            }
            .disabled(showForm)
            if let databaseError {
                Text(databaseError)
                    .foregroundStyle(TMDesign.danger)
            }
        } header: {
            Text("Subscriptions")
        }
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
                                // subscriptionsDidChange 通知驱动 AppState 刷新。
                                databaseError = ok ? nil
                                    : "Failed to delete subscription (disk space or database permissions)"
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

    private func summary(_ sub: Database.Subscription) -> String {
        var parts = ["\(Format.money(sub.price))/\(sub.cycle == "yearly" ? "yr" : "mo")",
                     "from \(Format.day(sub.startDate))"]
        if sub.endDate > 0 {
            parts.append("to \(SubscriptionMath.dateStr(Date(timeIntervalSince1970: TimeInterval(sub.endDate))))")
        }
        return parts.joined(separator: " · ")
    }

    private func beginAdd() {
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
    }

    private func beginEdit(_ sub: Database.Subscription) {
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

    static func planIcon(_ p: String) -> String {
        switch p {
        case "go": return "g.circle.fill"
        case "openrouter": return ToolKind.openrouter.symbol
        case "claude": return ToolKind.claude.symbol
        case "openai", "chatgpt", "codex": return ToolKind.codex.symbol
        default: return "calendar"
        }
    }

    static func planColor(_ p: String) -> Color {
        switch p {
        case "go": return TMDesign.accent
        case "openrouter": return ToolKind.openrouter.color
        case "claude": return ToolKind.claude.color
        case "openai", "chatgpt", "codex": return ToolKind.codex.color
        default: return .gray
        }
    }
}
