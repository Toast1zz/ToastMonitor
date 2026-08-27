#!/usr/bin/env swift

import AppKit
import Foundation

struct Scenario {
    let name: String
    let arguments: [String]
    let settingsPage: Bool
}

let scenarios: [Scenario] = ["light", "dark"].flatMap { appearance in
    [
        Scenario(name: "dashboard-overview-\(appearance)",
                 arguments: ["--render-dashboard", "OUTPUT", "720", "1120", "overview"],
                 settingsPage: false),
        Scenario(name: "dashboard-analysis-\(appearance)",
                 arguments: ["--render-dashboard", "OUTPUT", "720", "1120", "analysis"],
                 settingsPage: false),
        Scenario(name: "dashboard-plans-\(appearance)",
                 arguments: ["--render-dashboard", "OUTPUT", "720", "1120", "plans"],
                 settingsPage: false),
        Scenario(name: "dashboard-sessions-\(appearance)",
                 arguments: ["--render-dashboard", "OUTPUT", "720", "1120", "sessions"],
                 settingsPage: false),
        Scenario(name: "dashboard-settings-\(appearance)",
                 arguments: ["--render-dashboard", "OUTPUT", "720", "1120", "settings"],
                 settingsPage: false),
        Scenario(name: "popover-home-\(appearance)",
                 arguments: ["--render-popover", "OUTPUT", "820"],
                 settingsPage: false),
        Scenario(name: "popover-settings-\(appearance)",
                 arguments: ["--render-popover", "OUTPUT", "520"],
                 settingsPage: true),
    ]
}

func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let environment { process.environment = environment }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "VisualRegression", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: output])
    }
    return output
}

func averageHash(path: String) throws -> String {
    guard let image = NSImage(contentsOfFile: path),
          let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep)
    else { throw NSError(domain: "VisualRegression", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "cannot decode \(path)"]) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16),
               from: .zero, operation: .copy, fraction: 1)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    var luminance: [Double] = []
    for y in 0..<16 {
        for x in 0..<16 {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            luminance.append(0.2126 * color.redComponent
                             + 0.7152 * color.greenComponent
                             + 0.0722 * color.blueComponent)
        }
    }
    guard luminance.count == 256,
          let minimum = luminance.min(), let maximum = luminance.max(),
          maximum - minimum > 0.04 else {
        throw NSError(domain: "VisualRegression", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "blank or near-blank render: \(path)"])
    }
    let average = luminance.reduce(0, +) / Double(luminance.count)
    return stride(from: 0, to: luminance.count, by: 4).map { start in
        var nibble = 0
        for offset in 0..<4 where luminance[start + offset] >= average {
            nibble |= 1 << (3 - offset)
        }
        return String(nibble, radix: 16)
    }.joined()
}

func hammingDistance(_ lhs: String, _ rhs: String) -> Int {
    guard lhs.count == rhs.count else { return Int.max }
    return zip(lhs, rhs).reduce(0) { total, pair in
        guard let l = Int(String(pair.0), radix: 16),
              let r = Int(String(pair.1), radix: 16) else { return Int.max }
        return total + (l ^ r).nonzeroBitCount
    }
}

let mode = CommandLine.arguments.dropFirst().first ?? "compare"
guard mode == "record" || mode == "compare" else {
    fputs("usage: visual-regression.swift [record|compare] [baseline.json]\n", stderr)
    exit(2)
}
let baselinePath = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : "Tests/VisualBaselines/hashes.json"
let fileManager = FileManager.default
let tempRoot = fileManager.temporaryDirectory
    .appendingPathComponent("toastmonitor-visual-\(UUID().uuidString)")
try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: tempRoot) }

let binPath = try run("/usr/bin/env", ["swift", "build", "--show-bin-path"])
    .trimmingCharacters(in: .whitespacesAndNewlines)
let executable = URL(fileURLWithPath: binPath).appendingPathComponent("ToastMonitor").path
var actual: [String: String] = [:]
for scenario in scenarios {
    let output = tempRoot.appendingPathComponent("\(scenario.name).png").path
    let database = tempRoot.appendingPathComponent("\(scenario.name).sqlite").path
    var environment = ProcessInfo.processInfo.environment
    environment["TM_DATABASE_PATH"] = database
    environment["TM_POPOVER_SETTINGS"] = scenario.settingsPage ? "1" : "0"
    environment["TZ"] = "UTC"
    environment["LANG"] = "en_US.UTF-8"
    if scenario.name.contains("dashboard-sessions") {
        let warmup = tempRoot.appendingPathComponent("\(scenario.name)-warmup.png").path
        _ = try run(executable,
                    scenario.arguments.map { $0 == "OUTPUT" ? warmup : $0 },
                    environment: environment)
        let sql = """
        INSERT INTO sessions(tool, session_id, title, project, model, created, updated)
        VALUES('codex', 'visual-session', 'Visual Regression Session', 'ToastMonitor',
               'gpt-5.6-sol', 2000000000, 2000000300);
        """
        _ = try run("/usr/bin/sqlite3", [database, sql])
    }
    _ = try run(executable,
                scenario.arguments.map { $0 == "OUTPUT" ? output : $0 },
                environment: environment)
    actual[scenario.name] = try averageHash(path: output)
}

if mode == "record" {
    let data = try JSONSerialization.data(withJSONObject: actual, options: [.prettyPrinted, .sortedKeys])
    try fileManager.createDirectory(at: URL(fileURLWithPath: baselinePath).deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
    try data.write(to: URL(fileURLWithPath: baselinePath), options: .atomic)
    print("recorded \(actual.count) visual baselines at \(baselinePath)")
    exit(0)
}

let expectedData = try Data(contentsOf: URL(fileURLWithPath: baselinePath))
guard let expected = try JSONSerialization.jsonObject(with: expectedData) as? [String: String] else {
    throw NSError(domain: "VisualRegression", code: 4,
                  userInfo: [NSLocalizedDescriptionKey: "invalid baseline file"])
}
var failures: [String] = []
for scenario in scenarios {
    guard let expectedHash = expected[scenario.name], let actualHash = actual[scenario.name] else {
        failures.append("\(scenario.name): missing hash")
        continue
    }
    let distance = hammingDistance(expectedHash, actualHash)
    if distance > 20 {
        failures.append("\(scenario.name): distance \(distance) > 20")
    } else {
        print("\(scenario.name): distance \(distance)")
    }
}
guard failures.isEmpty else {
    fputs("visual regression failed:\n  \(failures.joined(separator: "\n  "))\n", stderr)
    exit(1)
}
print("visual regression passed (\(scenarios.count) scenes)")
