import Foundation

/// Central mapping of Command Code subscription plan IDs to their monthly
/// credit allowance in USD. Kept in its own type so a new plan only touches
/// this file. Unknown plan IDs are deliberately *not* guessed: callers must
/// surface them as unknown instead of silently applying a fallback.
enum CommandCodePlanCatalog {
    /// Known plan IDs and their monthly allowance (USD).
    static let monthlyAllowanceUSD: [String: Double] = [
        "individual-go": 10,
        "individual-pro": 30,
        "individual-max": 150,
        "individual-ultra": 300,
        // GOAT: docs advertise $70 of credits for $10/month. The internal
        // planId is taken from the live billing API and must match reality;
        // if the API returns something else it stays unknown until verified.
        "individual-goat": 70,
    ]

    static func allowance(forPlanID planID: String) -> Double? {
        monthlyAllowanceUSD[planID]
    }
}
