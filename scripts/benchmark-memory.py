#!/usr/bin/env python3
"""Compare JSONL collector peak RSS with a Git revision, using synthetic data.

Usage: python3 scripts/benchmark-memory.py --baseline HEAD
Compiles the real FileScanner with -O and runs each version in fresh processes.
Does not launch the app, use credentials, or read the user's transcript files.
This measures collector scan memory, not the whole app's idle/UI footprint.
"""

import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile


SCANNER = "Sources/ToastMonitor/Collect/FileScanner.swift"
HARNESS = r'''
import Foundation
import Darwin

@main
enum JSONLMemoryBenchmark {
    static func main() throws {
        let path = CommandLine.arguments[1]
        var rows: [(id: String, model: String, tokens: Int64)] = []
        var cursor: Int64 = 0
        let started = Date()
        // Match a background collector work item: no run-loop pool drains
        // until the scan finishes. Retain extracted results like a parser.
        autoreleasepool {
            cursor = FileScanner.forEachNewJSONLine(path: path, fromOffset: 0) { item in
                guard let id = item.obj["uuid"] as? String,
                      let message = item.obj["message"] as? [String: Any],
                      let model = message["model"] as? String,
                      let usage = message["usage"] as? [String: Any] else { return }
                let input = (usage["input_tokens"] as? NSNumber)?.int64Value ?? 0
                rows.append((id, model, input))
            }
        }
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { exit(1) }
        let result: [String: Any] = [
            "rows": rows.count, "tokens": rows.reduce(Int64(0)) { $0 + $1.tokens },
            "cursor": cursor, "first_event": rows.first?.id ?? "",
            "last_event": rows.last?.id ?? "", "peak_rss_bytes": usage.ru_maxrss,
            "seconds": Date().timeIntervalSince(started)
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result,
                                                          options: [.sortedKeys]), as: UTF8.self))
    }
}
'''


def positive_int(value):
    result = int(value)
    if result < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, help="Git revision to compare against")
    parser.add_argument("--runs", type=positive_int, default=3)
    parser.add_argument("--lines", type=positive_int, default=12_000)
    parser.add_argument("--minimum-reduction", type=float, default=30)
    args = parser.parse_args()
    if not 0 <= args.minimum_reduction < 100:
        parser.error("--minimum-reduction must be between 0 (inclusive) and 100 (exclusive)")

    root = Path(__file__).resolve().parent.parent
    baseline = subprocess.check_output(
        ["git", "show", f"{args.baseline}:{SCANNER}"], cwd=root
    )
    with tempfile.TemporaryDirectory(prefix="toastmonitor-memory-") as temporary:
        work = Path(temporary)
        harness = work / "Benchmark.swift"
        harness.write_text(HARNESS)
        fixture = work / "transcript.jsonl"
        record = {
            "type": "assistant", "sessionId": "benchmark-session",
            "timestamp": "2026-10-01T12:00:00Z",
            "message": {
                "model": "claude-sonnet-4",
                "content": [{"type": "text", "text": "synthetic transcript " * 180}],
                "usage": {"input_tokens": 100, "output_tokens": 20, "cache_read_input_tokens": 50},
            },
        }
        with fixture.open("w") as stream:
            for index in range(args.lines):
                record["uuid"] = f"event-{index}"
                stream.write(json.dumps(record, separators=(",", ":")) + "\n")

        environment = os.environ.copy()
        environment["CLANG_MODULE_CACHE_PATH"] = str(work / "module-cache")
        binaries = {}
        for label, source in (("before", baseline), ("after", (root / SCANNER).read_bytes())):
            scanner = work / f"{label}.swift"
            scanner.write_bytes(source)
            binary = work / label
            subprocess.run(["xcrun", "swiftc", "-O", str(scanner), str(harness),
                            "-o", str(binary)], env=environment, check=True)
            binaries[label] = binary

        samples = {label: [] for label in binaries}
        expected = {
            "rows": args.lines, "tokens": args.lines * 100, "cursor": fixture.stat().st_size,
            "first_event": "event-0", "last_event": f"event-{args.lines - 1}",
        }
        for _ in range(args.runs):
            for label, binary in binaries.items():
                sample = json.loads(subprocess.check_output([str(binary), str(fixture)]))
                for key, value in expected.items():
                    if sample[key] != value:
                        raise RuntimeError(f"{label}: {key} was {sample[key]!r}, expected {value!r}")
                samples[label].append(sample)

        medians = {
            label: statistics.median(sample["peak_rss_bytes"] for sample in runs)
            for label, runs in samples.items()
        }
        reduction = (1 - medians["after"] / medians["before"]) * 100
        print(json.dumps({"baseline": args.baseline, "fixture_bytes": fixture.stat().st_size,
                          "samples": samples, "median_peak_rss_bytes": medians,
                          "reduction_percent": round(reduction, 2)}, indent=2))
        if reduction < args.minimum_reduction:
            raise SystemExit(f"Reduction {reduction:.1f}% is below {args.minimum_reduction:.1f}%")


if __name__ == "__main__":
    main()
