import XCTest
@testable import ToastMonitor

final class FileScannerTests: XCTestCase {
    private var path: String!

    override func setUp() {
        super.setUp()
        path = NSTemporaryDirectory() + "tm-jsonl-\(UUID().uuidString).jsonl"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
        super.tearDown()
    }

    func testMalformedUTF8DoesNotShiftCursor() throws {
        let valid = Data("{\"type\":\"valid\"}\n".utf8)
        var bytes = Data([0xff, 0xfe, 0x0a])
        bytes.append(valid)
        try bytes.write(to: URL(fileURLWithPath: path))

        let result = FileScanner.readNewJSONLines(path: path, fromOffset: 0)
        XCTAssertEqual(result.objects.count, 1)
        XCTAssertEqual(result.objects.first?.obj["type"] as? String, "valid")
        XCTAssertEqual(result.newOffset, Int64(3 + valid.count))
    }

    func testPartialTrailingLineIsReplayable() throws {
        let prefix = Data("{\"type\":\"partial\"".utf8)
        try prefix.write(to: URL(fileURLWithPath: path))
        let first = FileScanner.readNewJSONLines(path: path, fromOffset: 0)
        XCTAssertTrue(first.objects.isEmpty)
        XCTAssertEqual(first.newOffset, 0)

        var completed = prefix
        completed.append(Data("}\n".utf8))
        try completed.write(to: URL(fileURLWithPath: path))
        let second = FileScanner.readNewJSONLines(path: path, fromOffset: first.newOffset)
        XCTAssertEqual(second.objects.count, 1)
        XCTAssertEqual(second.objects.first?.obj["type"] as? String, "partial")
        XCTAssertEqual(second.newOffset, Int64(prefix.count + 2))
    }

    func testIsLineBoundary() throws {
        // offset 0 is always a boundary, even when the file does not exist.
        XCTAssertTrue(FileScanner.isLineBoundary(path: path, offset: 0))
        XCTAssertFalse(FileScanner.isLineBoundary(path: path, offset: 1),
                       "a missing file has no byte before the offset")

        try Data("{\"a\":1}\n".utf8).write(to: URL(fileURLWithPath: path))
        // Bytes: { " a " : 1 } \n  (indices 0...7)
        XCTAssertTrue(FileScanner.isLineBoundary(path: path, offset: 8),
                      "cursor right after the trailing newline is a boundary")
        XCTAssertFalse(FileScanner.isLineBoundary(path: path, offset: 1),
                       "byte before offset 1 is '{', not a newline")
        XCTAssertFalse(FileScanner.isLineBoundary(path: path, offset: 5),
                       "byte before offset 5 is ':', not a newline")
        XCTAssertFalse(FileScanner.isLineBoundary(path: path, offset: 9),
                       "offset beyond EOF has no byte before it")
    }

    func testListFilesOnlyReturnsJSONLWithinDepthBoundary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tm-tree-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let accepted = root.appendingPathComponent("session/subagent")
        let tooDeep = accepted.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: tooDeep, withIntermediateDirectories: true)
        try Data().write(to: accepted.appendingPathComponent("usage.jsonl"))
        try Data().write(to: accepted.appendingPathComponent("debug.log"))
        try Data().write(to: root.appendingPathComponent("notes.md"))
        try Data().write(to: tooDeep.appendingPathComponent("too-deep.jsonl"))

        let files = FileScanner.listFiles(root.path, maxDepth: 3)
        XCTAssertEqual(files, [accepted.appendingPathComponent("usage.jsonl").path])
    }

}
