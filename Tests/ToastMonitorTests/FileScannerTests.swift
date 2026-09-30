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

        var objects: [(offset: Int64, obj: [String: Any])] = []
        let newOffset = FileScanner.forEachNewJSONLine(path: path, fromOffset: 0) { objects.append($0) }
        XCTAssertEqual(objects.count, 1)
        XCTAssertEqual(objects.first?.obj["type"] as? String, "valid")
        XCTAssertEqual(newOffset, Int64(3 + valid.count))
    }

    func testPartialTrailingLineIsReplayable() throws {
        let prefix = Data("{\"type\":\"partial\"".utf8)
        try prefix.write(to: URL(fileURLWithPath: path))
        var firstObjects: [(offset: Int64, obj: [String: Any])] = []
        let firstOffset = FileScanner.forEachNewJSONLine(path: path, fromOffset: 0) { firstObjects.append($0) }
        XCTAssertTrue(firstObjects.isEmpty)
        XCTAssertEqual(firstOffset, 0)
        var completed = prefix
        completed.append(Data("}\n".utf8))
        try completed.write(to: URL(fileURLWithPath: path))
        var secondObjects: [(offset: Int64, obj: [String: Any])] = []
        let secondOffset = FileScanner.forEachNewJSONLine(path: path, fromOffset: firstOffset) { secondObjects.append($0) }
        XCTAssertEqual(secondObjects.count, 1)
        XCTAssertEqual(secondObjects.first?.obj["type"] as? String, "partial")
        XCTAssertEqual(secondOffset, Int64(prefix.count + 2))
    }

    func testLongLineAndNewlineAcrossChunkBoundaryPreserveOffsetsAndTail() throws {
        let prefix = "{\"type\":\"large\",\"padding\":\""
        let suffix = "\"}"
        let paddingCount = 64 * 1024 - prefix.utf8.count - suffix.utf8.count
        let firstLine = prefix + String(repeating: "x", count: paddingCount) + suffix
        XCTAssertEqual(firstLine.utf8.count, 64 * 1024)
        let secondLine = "{\"type\":\"next\"}"
        let partial = "{\"type\":\"tail\""
        var bytes = Data((firstLine + "\n" + secondLine + "\n" + partial).utf8)
        try bytes.write(to: URL(fileURLWithPath: path))

        var objects: [(offset: Int64, obj: [String: Any])] = []
        let partialOffset = FileScanner.forEachNewJSONLine(path: path, fromOffset: 0) {
            objects.append($0)
        }
        XCTAssertEqual(objects.count, 2)
        XCTAssertEqual(objects[0].offset, 0)
        XCTAssertEqual(objects[0].obj["padding"] as? String, String(repeating: "x", count: paddingCount))
        XCTAssertEqual(objects[1].offset, Int64(firstLine.utf8.count + 1))
        XCTAssertEqual(objects[1].obj["type"] as? String, "next")
        XCTAssertEqual(partialOffset, Int64(firstLine.utf8.count + 1 + secondLine.utf8.count + 1))

        bytes.append(Data("}\n".utf8))
        try bytes.write(to: URL(fileURLWithPath: path))
        var tailObjects: [(offset: Int64, obj: [String: Any])] = []
        let finalOffset = FileScanner.forEachNewJSONLine(path: path, fromOffset: partialOffset) {
            tailObjects.append($0)
        }
        XCTAssertEqual(tailObjects.count, 1)
        XCTAssertEqual(tailObjects[0].offset, partialOffset)
        XCTAssertEqual(tailObjects[0].obj["type"] as? String, "tail")
        XCTAssertEqual(finalOffset, Int64(bytes.count))
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
