import XCTest
import SwiftUI
@testable import ToastMonitor

final class PopoverBreakdownTests: XCTestCase {
    private func agg(_ tool: String, _ model: String, _ input: Int64) -> Database.ModelAgg {
        Database.ModelAgg(tool: tool, model: model, input: input, output: 0, cacheRead: 0, cost: 0, count: 1)
    }

    func testSameModelAcrossToolsMergesAndSortsLargestFirst() {
        let entries = PopoverHomeView.modelShareEntries(aggs: [
            agg("claude", "claude-opus-4-5", 100),
            agg("opencode", "claude-opus-4-5", 50),
            agg("codex", "gpt-5", 300),
        ])
        XCTAssertEqual(entries.map(\.value), [300, 150])
        XCTAssertEqual(entries.count, 2)
    }

    func testLongTailFoldsIntoOther() {
        let aggs = (1...8).map { agg("claude", "model-\($0)", Int64($0 * 10)) }
        let entries = PopoverHomeView.modelShareEntries(aggs: aggs, limit: 5)
        XCTAssertEqual(entries.count, 6)
        XCTAssertEqual(entries.last?.name, "Other (3 models)")
        XCTAssertEqual(entries.last?.value, 10 + 20 + 30)
        XCTAssertEqual(entries.reduce(0) { $0 + $1.value }, aggs.reduce(0) { $0 + $1.input })
    }

    func testSingleLeftoverIsShownInsteadOfOther() {
        let aggs = (1...6).map { agg("claude", "model-\($0)", Int64($0 * 10)) }
        let entries = PopoverHomeView.modelShareEntries(aggs: aggs, limit: 5)
        XCTAssertEqual(entries.count, 6)
        XCTAssertFalse(entries.contains { $0.name.hasPrefix("Other") })
    }

    func testExtrasKeepTotalsMatchingTheHeadline() {
        let entries = PopoverHomeView.modelShareEntries(
            aggs: [agg("claude", "claude-sonnet-4-5", 40)],
            extras: [(name: "Cowork & web", value: 10, color: .gray)])
        XCTAssertEqual(entries.map(\.name).last, "Cowork & web")
        XCTAssertEqual(entries.reduce(0) { $0 + $1.value }, 50)
    }

    func testPercentText() {
        XCTAssertEqual(PopoverHomeView.percentText(1, total: 4), "25.0%")
        XCTAssertEqual(PopoverHomeView.percentText(1, total: 0), "0.0%")
    }

    func testModelColorsUseProviderBrandColorsAndStepSameMakerShades() {
        let colors = TMDesign.modelColors(for: [
            "Opus 5.5",
            "Sonnet 5.5",
            "Gemini 4 Neon",
            "GPT-6 Sol",
            "DeepSeek V4.1 Flash",
        ])
        XCTAssertEqual(colors["Opus 5.5"], TMDesign.providerColor(for: "Anthropic"))
        XCTAssertEqual(colors["Gemini 4 Neon"], TMDesign.providerColor(for: "Google"))
        XCTAssertEqual(colors["GPT-6 Sol"], TMDesign.providerColor(for: "OpenAI"))
        XCTAssertEqual(colors["DeepSeek V4.1 Flash"], TMDesign.providerColor(for: "DeepSeek"))
        XCTAssertNotEqual(colors["Sonnet 5.5"], colors["Opus 5.5"])
    }
}
