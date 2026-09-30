#!/usr/bin/env swift

import AppKit
import Foundation

struct Scenario {
    let name: String
    let arguments: [String]
}

// The Data settings pane is left out: it lists this machine's real backups.
let scenarios: [Scenario] = ["light", "dark"].flatMap { appearance in
    [
        Scenario(name: "dashboard-overview-\(appearance)",
                 arguments: ["--render-dashboard", "OUTPUT", "720", "1120", "overview"]),
        Scenario(name: "dashboard-analysis-\(appearance)",
                 arguments: ["--render-dashboard", "OUTPUT", "720", "1120", "analysis"]),
        Scenario(name: "dashboard-plans-\(appearance)",
                 arguments: ["--render-dashboard", "OUTPUT", "720", "1120", "plans"]),
        Scenario(name: "dashboard-sessions-\(appearance)",
                 arguments: ["--render-dashboard", "OUTPUT", "720", "1120", "sessions"]),
        Scenario(name: "popover-home-\(appearance)",
                 arguments: ["--render-popover", "OUTPUT", "820"]),
        Scenario(name: "settings-general-\(appearance)",
                 arguments: ["--render-settings", "OUTPUT", "general"]),
        Scenario(name: "settings-sources-\(appearance)",
                 arguments: ["--render-settings", "OUTPUT", "sources"]),
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
    // Drain before waiting: a child that writes more than the pipe buffer
    // (a cold `swift build`'s warnings) blocks until read, so waiting first
    // deadlocked CI.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(data: data, encoding: .utf8) ?? ""
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

// Render with the native build system, as build-app.sh does. The default
// engine records the deployment target as the SDK, so AppKit would draw the
// pre-Liquid Glass compatibility controls users never see.
let buildCommand = ["swift", "build", "--build-system", "native"]
_ = try run("/usr/bin/env", buildCommand)
// The path is the last line; `run` merges stderr, where SwiftPM prints a
// deprecation warning for the native build system.
let binPath = try run("/usr/bin/env", buildCommand + ["--show-bin-path"])
    .split(separator: "\n").last.map(String.init)?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
let executable = URL(fileURLWithPath: binPath).appendingPathComponent("ToastMonitor").path
var actual: [String: String] = [:]
for scenario in scenarios {
    let output = tempRoot.appendingPathComponent("\(scenario.name).png").path
    let database = tempRoot.appendingPathComponent("\(scenario.name).sqlite").path
    let scenarioHome = tempRoot.appendingPathComponent("\(scenario.name)-home", isDirectory: true)
    try fileManager.createDirectory(at: scenarioHome, withIntermediateDirectories: true)
    var environment = ProcessInfo.processInfo.environment
    environment["TM_DATABASE_PATH"] = database
    environment["HOME"] = scenarioHome.path
    environment["CFFIXED_USER_HOME"] = scenarioHome.path
    environment["TZ"] = "UTC"
    environment["LANG"] = "en_US.UTF-8"
    for key in ["DSH_HOME", "HERMES_HOME", "OPENCODE_HOME"] {
        environment.removeValue(forKey: key)
    }
    if scenario.name.hasPrefix("popover-home-") {
        let referenceTime = "1790769600"
        environment["TM_VISUAL_REFERENCE_UNIX_TIME"] = referenceTime
    } else {
        environment.removeValue(forKey: "TM_VISUAL_REFERENCE_UNIX_TIME")
    }
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
    let renderOutput = try run(executable,
                               scenario.arguments.map { $0 == "OUTPUT" ? output : $0 },
                               environment: environment)
    if scenario.name.hasPrefix("popover-home-"),
       let fixtureLog = renderOutput.split(separator: "\n").first(where: {
           $0.contains("popover visual reference unix time:")
       }) {
        print(fixtureLog)
    }
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
var failedPopoverScenes: [String] = []
for scenario in scenarios {
    guard let expectedHash = expected[scenario.name], let actualHash = actual[scenario.name] else {
        failures.append("\(scenario.name): missing hash")
        if scenario.name.hasPrefix("popover-home-") {
            failedPopoverScenes.append(scenario.name)
        }
        continue
    }
    let distance = hammingDistance(expectedHash, actualHash)
    if distance > 20 {
        failures.append("\(scenario.name): distance \(distance) > 20 (expected \(expectedHash), actual \(actualHash))")
        if scenario.name.hasPrefix("popover-home-") {
            failedPopoverScenes.append(scenario.name)
        }
    } else {
        print("\(scenario.name): distance \(distance)")
    }
}
if !failures.isEmpty,
   !failedPopoverScenes.isEmpty,
   let artifactPath = ProcessInfo.processInfo.environment["TM_VISUAL_ARTIFACT_DIR"] {
    let artifactDirectory = URL(fileURLWithPath: artifactPath, isDirectory: true)
    do {
        try fileManager.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        for name in failedPopoverScenes {
            let source = tempRoot.appendingPathComponent("\(name).png")
            let destination = artifactDirectory.appendingPathComponent("\(name).png")
            try fileManager.copyItem(at: source, to: destination)
        }
        print("saved failing popover captures to \(artifactDirectory.path)")
    } catch {
        fputs("warning: could not save failing popover captures: \(error)\n", stderr)
    }
}
guard failures.isEmpty else {
    fputs("visual regression failed:\n  \(failures.joined(separator: "\n  "))\n", stderr)
    exit(1)
}
print("visual regression passed (\(scenarios.count) scenes)")
